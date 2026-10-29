// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// The UDP half of a mosh session: the local ports, of which the newest sends
/// and **all** of them are read.
///
/// Everything the protocol decides is in ``MoshTransport``, which owns no socket
/// and no thread so that a test can drive it with a clock it controls. This is
/// the other half, and it is the piece of the port that could not be translated
/// from Android: theirs is a `java.nio` `Selector` over `DatagramChannel`s, and
/// here it is `Network.framework`, where a new local port is a new connection
/// and the reads arrive as callbacks rather than being asked for.
///
/// ### Why there is more than one port
///
/// Roaming — the whole feature — is the server's doing: it adopts whatever
/// address it hears an authenticated packet from. The client's half is smaller
/// but not nothing. It changes its own local port when nothing has made it
/// there and back for ten seconds, when a send fails outright (which is what an
/// interface going away looks like from here), and when the system says the path
/// has changed, which is about ten seconds earlier than noticing.
///
/// A retired port stays **readable** for a minute afterwards, and that is not
/// tidiness: the server does not know about the new port until a packet from it
/// arrives, so what it is sending at that moment is still addressed to the old
/// one, and throwing those away would lose a frame for nothing. Nine ports is
/// the ceiling, as in mosh, so a session hopping faster than the grace period
/// cannot accumulate them.
actor MoshSocket {

    /// Where the server is: the port it printed, and the address SSH used, which
    /// is all the handover gives us and all the stock client uses either.
    struct Peer: Equatable {
        let host: String
        let port: UInt16
    }

    /// How long a retired port stays readable.
    static let retiredGrace: TimeInterval = 60

    /// As in mosh: the one in use plus eight on their way out.
    static let maximumPorts = 9

    private let peer: Peer
    private let grace: TimeInterval
    private let queue = DispatchQueue(label: "com.sshborg.mosh.socket")

    /// Newest last. Only the newest sends; all of them are read.
    private var ports: [LocalPort] = []

    private final class LocalPort {
        let connection: NWConnection
        /// When we stopped sending from it; `nil` while it is the one in use.
        var retiredAt: Date?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// Everything that arrives on any of our ports, in the order the system
    /// hands it over.
    ///
    /// One stream rather than one per port, because to the protocol a datagram
    /// is a datagram: which of our ports it came back to is an artefact of when
    /// we hopped, and the sequence number is what decides whether it is news.
    /// `nonisolated` on purpose: the framework delivers on its own queue and
    /// the consumer is the loop, so neither end of this is the actor's. An
    /// `AsyncStream.Continuation` is `Sendable`, which is what makes that safe —
    /// and the stream itself is unbounded, as Android's channel is, because a
    /// datagram dropped for want of buffer is a frame the server has to send
    /// again.
    nonisolated let arrivals: AsyncStream<Data>
    nonisolated private let deliver: AsyncStream<Data>.Continuation

    private(set) var hops = 0
    private(set) var refusedSends = 0
    private(set) var closed = false

    /// Set when the stack refused a datagram as too long, and cleared by
    /// whoever acts on it. The loop drops the MTU.
    private var messageTooLarge = false

    /// Set when a send was refused outright or the system reported the path
    /// changed, and cleared by whoever acts on it. The loop hops.
    private var hopWanted = false

    private var monitor: NWPathMonitor?

    init(peer: Peer, retiredGrace: TimeInterval = MoshSocket.retiredGrace) {
        self.peer = peer
        self.grace = retiredGrace

        var continuation: AsyncStream<Data>.Continuation!
        self.arrivals = AsyncStream { continuation = $0 }
        self.deliver = continuation
    }

    /// Opens the first port and starts watching the path.
    ///
    /// Separate from `init` because both are side effects on the world, and an
    /// actor's initialiser cannot await the isolation it is setting up.
    func start() {
        guard ports.isEmpty, !closed else { return }
        open()
        watchThePath()
    }

    /// Sends from the newest port.
    ///
    /// Not awaited. `NWConnection` takes the datagram and reports later whether
    /// the stack accepted it, and the protocol's own timing is what decides when
    /// to send next — waiting here would put the local stack's latency inside
    /// every keystroke's. A refusal is counted and asks for a hop instead, which
    /// is what an interface that has gone away deserves.
    func send(_ datagram: Data) {
        guard !closed, let port = ports.last else { return }

        port.connection.send(
            content: datagram,
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { await self?.sendFailed(error) }
            }
        )
    }

    /// Sends from a new local port from now on, keeping the old one readable.
    func hop() {
        guard !closed else { return }
        ports.last?.retiredAt = Date()
        open()
        hops += 1
        prune()
    }

    /// True once, when something has asked for a new local port: a send the
    /// stack refused, or the system saying the path changed.
    func takeHopRequest() -> Bool {
        defer { hopWanted = false }
        return hopWanted
    }

    /// True once, when the stack has refused a datagram for being too long.
    ///
    /// Reported rather than acted on here, because what to do about it is the
    /// protocol's: the datagram is gone, and the state it carried goes out again
    /// — smaller — on the next tick.
    func takeMessageTooLarge() -> Bool {
        defer { messageTooLarge = false }
        return messageTooLarge
    }

    /// Retires what is past its grace, and keeps the number of ports under the
    /// ceiling whatever the clock says.
    func prune() {
        guard ports.count > 1 else { return }

        let now = Date()
        var survivors: [LocalPort] = []
        for (index, port) in ports.enumerated() {
            let isNewest = index == ports.count - 1
            let expired = port.retiredAt.map { now.timeIntervalSince($0) > grace } ?? false
            let overTheCeiling = ports.count - index > Self.maximumPorts
            if isNewest || !(expired || overTheCeiling) {
                survivors.append(port)
            } else {
                port.connection.cancel()
            }
        }
        ports = survivors
    }

    func close() {
        guard !closed else { return }
        closed = true
        monitor?.cancel()
        monitor = nil
        for port in ports { port.connection.cancel() }
        ports.removeAll()
        deliver.finish()
    }

    /// How many of our ports are open: the one we send from, plus the retired
    /// ones still being read.
    var openPorts: Int { ports.count }

    /// Which family the socket got, because the two have different headers to
    /// pay for out of mosh's 1280-byte budget — and because a firewall rule
    /// written for one does nothing for the other.
    var isIPv4: Bool? {
        guard let path = ports.last?.connection.currentPath else { return nil }
        guard let endpoint = path.remoteEndpoint else { return nil }
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4: return true
            case .ipv6: return false
            default: return nil
            }
        }
        return nil
    }

    /// What to show somebody who has to go and look: the port and the family,
    /// which is the half that gets forgotten. The address itself is deliberately
    /// not here — this goes in a dialog with a copy button, and somebody's
    /// server is not something to make easy to paste into an issue.
    var peerDescription: String {
        let family = isIPv4.map { $0 ? "IPv4" : "IPv6" } ?? "an unknown address family"
        return "UDP port \(peer.port) over \(family)"
    }

    // MARK: - The parts that touch the framework

    private func open() {
        let connection = NWConnection(
            host: NWEndpoint.Host(peer.host),
            port: NWEndpoint.Port(integerLiteral: peer.port),
            using: .udp
        )
        let port = LocalPort(connection: connection)
        ports.append(port)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                Task { await self?.sendFailed(error) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// One read at a time, each asking for the next: a datagram is a message, so
    /// there is no stream to reassemble and no partial read to carry over.
    nonisolated private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, _ in
            if let content, !content.isEmpty {
                self?.deliver.yield(content)
            }
            // A cancelled connection must not be asked again; anything else is
            // one datagram's bad luck and the next read is still worth posting.
            if case .cancelled = connection.state { return }
            self?.receive(on: connection)
        }
    }

    /// `EMSGSIZE` is the one thing that proves the path's budget wrong, and the
    /// caller drops the MTU for it rather than moving: the path is fine, our
    /// guess about what it would carry was not. Everything else here means the
    /// interface we were using is not usable, which is what an interface going
    /// away looks like from here and is cured by a new local port rather than by
    /// ending the session.
    private func sendFailed(_ error: Error) {
        guard !closed else { return }
        refusedSends += 1
        if let network = error as? NWError, case .posix(.EMSGSIZE) = network {
            messageTooLarge = true
        } else {
            hopWanted = true
        }
    }

    private func watchThePath() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { await self?.pathChanged() }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    /// The system saying the networks have moved under us, which is about ten
    /// seconds earlier than the protocol noticing that nothing is coming back.
    ///
    /// The first update arrives as soon as the monitor starts and says nothing
    /// has changed, so it is not acted on: a session would otherwise hop out of
    /// its own first port before it had used it.
    private func pathChanged() {
        guard !closed, !ports.isEmpty else { return }
        guard seenFirstPath else {
            seenFirstPath = true
            return
        }
        hopWanted = true
    }

    private var seenFirstPath = false
}
