// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// Serves the app's ``SSHAgent`` over the channels a server opens back to us.
///
/// The sequence: the shell channel asks for agent forwarding, the server sets
/// `SSH_AUTH_SOCK` in the remote environment, and every time something there
/// talks to that socket the server opens an `auth-agent@openssh.com` channel to
/// the client. libssh2 accepts it and calls ``accept(_:)`` from inside its
/// packet loop; from then on it is an ordinary channel carrying agent messages.
///
/// Two constraints shape the design:
///
/// 1. ``accept(_:)`` runs *inside* a libssh2 call, so it must not do channel
///    I/O — that would be reentering the library on the same session. It only
///    records the channel; a pump picks it up afterwards.
/// 2. The pump runs on the session's queue, which is what makes touching the
///    session safe at all, and reschedules itself rather than blocking. It backs
///    off while idle: an agent is quiet except for the moment a `git push` or a
///    second `ssh` hop runs on the far end.
final class AgentForwarder: @unchecked Sendable {

    /// Counters for diagnosing a forwarded agent that is not working.
    ///
    /// A failure on the far end looks the same whatever the cause — `ssh-add`
    /// just hangs — so these say which stage was reached: whether the server
    /// ever opened a channel, whether anything arrived on it, and whether we
    /// answered. Read from any thread, written only on ``queue``.
    struct Diagnostics: Equatable {
        var acceptedChannels = 0
        var requestsHandled = 0
        var channelsClosed = 0
        /// How many times the pump ran. Zero here with a non-zero
        /// ``acceptedChannels`` means the channel was taken and then never
        /// serviced — a different fault from servicing it and reading nothing.
        var pumpPasses = 0
        /// What the last read returned: -37 is EAGAIN, 0 is "nothing yet".
        var lastRead = Int.min
    }

    var diagnostics: Diagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return counters
    }

    private var counters = Diagnostics()
    private let diagnosticsLock = NSLock()

    private func count(_ change: (inout Diagnostics) -> Void) {
        diagnosticsLock.lock()
        change(&counters)
        diagnosticsLock.unlock()
    }

    private let agent: SSHAgent
    private let queue: DispatchQueue

    /// Accepted channels, each with the framing state of its byte stream.
    private var connections: [Connection] = []
    private var isPumping = false
    private var isStopped = false
    private var idleDelay: TimeInterval = Pump.minimumDelay

    private final class Connection {
        let channel: OpaquePointer
        var framing = SSHAgentFraming()
        /// Bytes libssh2 would not take yet, retried on the next pass.
        var pendingWrite = Data()

        init(channel: OpaquePointer) {
            self.channel = channel
        }
    }

    private enum Pump {
        static let minimumDelay: TimeInterval = 0.02
        static let maximumDelay: TimeInterval = 0.25
        static let backoffFactor: Double = 1.6
        static let readBufferSize = 16 * 1024
    }

    init(agent: SSHAgent, queue: DispatchQueue) {
        self.agent = agent
        self.queue = queue
    }

    /// Installs the callback that receives auth-agent channels.
    ///
    /// Must be called on the session queue, before the shell requests
    /// forwarding. `context` is the session's shared abstract-pointer context.
    func install(on session: OpaquePointer, context: SSHSessionContext) {
        context.agentForwarder = self

        libssh2_session_callback_set2(
            session,
            LIBSSH2_CALLBACK_AUTHAGENT,
            unsafeBitCast(authAgentOpened, to: (@convention(c) () -> Void).self)
        )
    }

    /// Called from libssh2's packet loop. Records the channel and returns at
    /// once — see the note on reentrancy above.
    fileprivate func accept(_ channel: OpaquePointer) {
        guard !isStopped else {
            libssh2_channel_free(channel)
            return
        }

        count { $0.acceptedChannels += 1 }
        connections.append(Connection(channel: channel))
        idleDelay = Pump.minimumDelay
        startPumpIfNeeded()
    }

    // MARK: - Pump

    private func startPumpIfNeeded() {
        guard !isPumping, !isStopped, !connections.isEmpty else { return }
        isPumping = true
        queue.async { [weak self] in self?.pump() }
    }

    private func pump() {
        guard !isStopped else {
            isPumping = false
            return
        }

        count { $0.pumpPasses += 1 }

        var didWork = false
        var survivors: [Connection] = []

        for connection in connections {
            switch service(connection) {
            case .working:
                didWork = true
                survivors.append(connection)
            case .idle:
                survivors.append(connection)
            case .closed:
                didWork = true
                count { $0.channelsClosed += 1 }
                libssh2_channel_close(connection.channel)
                libssh2_channel_free(connection.channel)
            }
        }
        connections = survivors

        guard !connections.isEmpty else {
            isPumping = false
            return
        }

        idleDelay = didWork
            ? Pump.minimumDelay
            : min(idleDelay * Pump.backoffFactor, Pump.maximumDelay)

        queue.asyncAfter(deadline: .now() + idleDelay) { [weak self] in self?.pump() }
    }

    private enum Outcome {
        case working
        case idle
        case closed
    }

    private func service(_ connection: Connection) -> Outcome {
        var didWork = false

        if !connection.pendingWrite.isEmpty {
            switch write(&connection.pendingWrite, to: connection.channel) {
            case .closed: return .closed
            case .working: didWork = true
            case .idle: break
            }
        }

        var buffer = [UInt8](repeating: 0, count: Pump.readBufferSize)
        let read = buffer.withUnsafeMutableBytes { raw in
            libssh2_channel_read_ex(
                connection.channel, 0,
                raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                raw.count
            )
        }

        count { $0.lastRead = read }

        if read > 0 {
            didWork = true
            connection.framing.append(Data(buffer[0..<Int(read)]))
        } else if read == 0 {
            // Zero means nothing to read; only `channel_eof` distinguishes that
            // from the far end having finished with us.
            if libssh2_channel_eof(connection.channel) == 1 { return .closed }
        } else if read != Int(LIBSSH2_ERROR_EAGAIN) {
            return .closed
        }

        while let request = connection.framing.nextRequest() {
            didWork = true
            count { $0.requestsHandled += 1 }
            connection.pendingWrite += SSHAgentFraming.frame(agent.respond(to: request))
        }
        if connection.framing.isPoisoned { return .closed }

        if !connection.pendingWrite.isEmpty {
            switch write(&connection.pendingWrite, to: connection.channel) {
            case .closed: return .closed
            case .working: didWork = true
            case .idle: break
            }
        }

        return didWork ? .working : .idle
    }

    /// Writes what it can, leaving the rest in `data` for the next pass.
    private func write(_ data: inout Data, to channel: OpaquePointer) -> Outcome {
        var didWork = false

        while !data.isEmpty {
            let written = data.withUnsafeBytes { raw -> Int in
                libssh2_channel_write_ex(
                    channel, 0,
                    raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }

            if written > 0 {
                data.removeFirst(written)
                didWork = true
                continue
            }
            if written == Int(LIBSSH2_ERROR_EAGAIN) { break }
            return .closed
        }

        return didWork ? .working : .idle
    }

    // MARK: - Teardown

    /// Must be called on the session queue, before the session is freed.
    func stopOnQueue() {
        isStopped = true
        for connection in connections {
            libssh2_channel_close(connection.channel)
            libssh2_channel_free(connection.channel)
        }
        connections.removeAll()
    }
}

/// libssh2 hands over each accepted `auth-agent@openssh.com` channel here.
private let authAgentOpened: @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, channel, abstract in
    guard let channel,
          let forwarder = SSHSessionContext.from(abstract)?.agentForwarder
    else { return }

    forwarder.accept(channel)
}
