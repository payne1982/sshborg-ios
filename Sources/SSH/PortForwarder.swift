// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation
import Network

/// Local port forwarding: the `-L` of the command line.
///
/// Listens on the device and tunnels whatever connects to it out through the
/// SSH session, so `localhost:8080` on the phone reaches a service that is only
/// visible from the server.
///
/// It runs on a connection of its own rather than sharing the terminal's. The
/// terminal's session goes non-blocking once a shell is open and its read pump
/// backs off to a quarter of a second when idle; a forwarded connection would
/// inherit that latency, which is fine for a keystroke and not fine for a
/// database. Android attaches forwarding to the shell session instead, so a
/// server's logs will show one more connection here than there.
final class PortForwarder: @unchecked Sendable {

    /// What a caller can observe about one rule.
    struct Status: Identifiable, Equatable {
        let rule: PortForwarding
        var isListening: Bool
        var failure: String?

        var id: String { "\(rule.bindAddress):\(rule.localPort)" }
    }

    private let session: SSHSession
    private let queue: DispatchQueue
    private var listeners: [NWListener] = []
    private var statuses: [Status] = []
    private let lock = NSLock()

    private init(session: SSHSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    /// Opens its own connection and starts listening for every rule.
    static func start(_ rules: [PortForwarding], params: SSHConnectionParams) async throws -> PortForwarder {
        let session = try await SSHSession.connect(params)

        // Everything past the handshake is driven from the listener callbacks,
        // which must never block waiting for the network.
        try await session.withRawSession { raw in
            libssh2_session_set_blocking(raw, 0)
        }

        let forwarder = PortForwarder(
            session: session,
            queue: DispatchQueue(label: "com.sshborg.forward.\(params.hostname)")
        )
        for rule in rules {
            forwarder.listen(rule)
        }
        return forwarder
    }

    var status: [Status] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    // MARK: - Listening

    private func listen(_ rule: PortForwarding) {
        var status = Status(rule: rule, isListening: false, failure: nil)

        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: rule.localPort)), rule.localPort > 0 else {
            status.failure = "\(rule.localPort) is not a usable port."
            record(status)
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Binding to a specific address is what "bindAddress" means; without
        // this a rule for 127.0.0.1 would also accept from the network.
        //
        // The port goes in exactly one place. Setting requiredLocalEndpoint
        // *and* passing `on:` states it twice and Network rejects the pair with
        // EINVAL, which is what the first run of these tests produced.
        let bindsToOneAddress = rule.bindAddress != "0.0.0.0" && !rule.bindAddress.isEmpty
        if bindsToOneAddress {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(rule.bindAddress),
                port: port
            )
        }

        let listener: NWListener
        do {
            listener = bindsToOneAddress
                ? try NWListener(using: parameters)
                : try NWListener(using: parameters, on: port)
        } catch {
            // The usual cause is a port already taken, or one below 1024 that
            // an unprivileged app may not bind.
            status.failure = error.localizedDescription
            record(status)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.record(Status(rule: rule, isListening: true, failure: nil))
            case .failed(let error):
                self?.record(Status(rule: rule, isListening: false, failure: error.localizedDescription))
            case .cancelled:
                self?.record(Status(rule: rule, isListening: false, failure: nil))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, for: rule)
        }

        listener.start(queue: queue)
        listeners.append(listener)
        record(status)
    }

    private func record(_ status: Status) {
        lock.lock()
        defer { lock.unlock() }

        if let index = statuses.firstIndex(where: { $0.id == status.id }) {
            statuses[index] = status
        } else {
            statuses.append(status)
        }
    }

    // MARK: - Forwarding one connection

    private func accept(_ connection: NWConnection, for rule: PortForwarding) {
        connection.start(queue: queue)

        Task { [session, queue] in
            do {
                // On a non-blocking session, opening a channel returns NULL with
                // EAGAIN until the exchange completes — it is not a refusal, and
                // treating it as one closed every forwarded connection before a
                // single byte moved.
                let channel = try await Self.openChannel(
                    on: session,
                    to: rule.remoteHost,
                    port: rule.remotePort
                )

                ForwardedConnection(
                    connection: connection,
                    channel: channel,
                    session: session,
                    queue: queue
                ).run()
            } catch {
                // Nothing useful to tell the app: the peer simply sees the
                // connection close, which is what it would see if the remote
                // service were down.
                connection.cancel()
            }
        }
    }

    /// Opens a `direct-tcpip` channel, retrying while libssh2 reports EAGAIN.
    private static func openChannel(
        on session: SSHSession,
        to host: String,
        port: Int,
        timeout: TimeInterval = 10
    ) async throws -> ForwardedChannel {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let outcome = try await session.withRawSession { raw -> ForwardedChannel? in
                if let channel = host.withCString({ target in
                    libssh2_channel_direct_tcpip_ex(raw, target, Int32(port), "127.0.0.1", 0)
                }) {
                    return ForwardedChannel(pointer: channel)
                }
                // Only EAGAIN is worth another attempt; a refusal is final.
                guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
                    throw SSHError.fromSession(
                        raw,
                        fallback: "the server refused a tunnel to \(host):\(port)"
                    )
                }
                return nil
            }

            if let outcome { return outcome }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        throw SSHError.timedOut
    }

    // MARK: - Teardown

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        session.disconnect()

        lock.lock()
        statuses = statuses.map { Status(rule: $0.rule, isListening: false, failure: $0.failure) }
        lock.unlock()
    }
}

/// The libssh2 channel pointer, boxed so it can cross into `@Sendable` closures.
/// It is only ever touched inside `withRawSession`, which serialises onto the
/// session's queue.
private struct ForwardedChannel: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Pumps one accepted connection in both directions until either end closes.
private final class ForwardedConnection: @unchecked Sendable {

    private let connection: NWConnection
    private let channel: ForwardedChannel
    private let session: SSHSession
    private let queue: DispatchQueue
    private var isFinished = false

    init(connection: NWConnection, channel: ForwardedChannel, session: SSHSession, queue: DispatchQueue) {
        self.connection = connection
        self.channel = channel
        self.session = session
        self.queue = queue
    }

    func run() {
        receiveFromLocal()
        pumpFromRemote()
    }

    /// Local app to server.
    private func receiveFromLocal() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                let channel = self.channel
                Task { [self] in
                    try? await self.session.withRawSession { _ in
                        var sent = 0
                        data.withUnsafeBytes { raw in
                            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                            while sent < data.count {
                                let written = libssh2_channel_write_ex(
                                    channel.pointer, 0, base + sent, data.count - sent
                                )
                                if written > 0 { sent += written; continue }
                                // EAGAIN here is rare for the sizes involved;
                                // anything else means the tunnel is gone.
                                break
                            }
                        }
                    }
                }
            }

            if isComplete || error != nil {
                finish()
            } else {
                receiveFromLocal()
            }
        }
    }

    /// Server to local app. Polls, because a libssh2 channel has nothing to
    /// wake us with.
    private func pumpFromRemote() {
        let channel = self.channel

        Task { [self] in
            var idleDelay: UInt64 = 5_000_000 // 5ms while busy

            while !self.isFinished {
                let chunk: Data? = try? await self.session.withRawSession { _ -> Data? in
                    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                    let read = buffer.withUnsafeMutableBytes { raw in
                        libssh2_channel_read_ex(
                            channel.pointer, 0,
                            raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                            raw.count
                        )
                    }
                    if read > 0 { return Data(buffer[0..<Int(read)]) }
                    if read == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
                    return nil // EOF or error
                }

                guard let chunk else { break }

                if chunk.isEmpty {
                    // Back off while quiet, but never past 50ms: this carries
                    // interactive traffic, not bulk transfer.
                    try? await Task.sleep(nanoseconds: idleDelay)
                    idleDelay = min(idleDelay * 2, 50_000_000)
                } else {
                    idleDelay = 5_000_000
                    self.connection.send(content: chunk, completion: .contentProcessed { _ in })
                }
            }

            self.finish()
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true

        connection.cancel()
        let channel = channel
        Task { [session] in
            try? await session.withRawSession { _ in
                libssh2_channel_close(channel.pointer)
                libssh2_channel_free(channel.pointer)
            }
        }
    }
}
