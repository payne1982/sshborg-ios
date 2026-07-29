// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// One-time global initialisation. A Swift global `let` is lazy and runs exactly
/// once, which is precisely libssh2's contract for `libssh2_init`.
private let libssh2Bootstrap: Int32 = libssh2_init(0)

/// An authenticated SSH session.
///
/// libssh2 is a blocking C library and a session is not thread-safe, so every
/// call for a given session is funnelled through one private serial queue and
/// the public API is `async` wrappers over it. This is deliberately not an
/// `actor`: blocking a cooperative-pool thread inside an actor would starve
/// Swift concurrency, whereas a dedicated queue is allowed to block.
///
/// Ported from the Android `SshManager`, minus the jump-host chain and port
/// forwarding, which arrive in phase 7.
///
/// `@unchecked Sendable` is accurate rather than a shortcut: every mutable
/// property is only ever touched from `queue`, and the keepalive timer fires on
/// that same queue. The compiler cannot see that invariant, so it is asserted
/// here and must be preserved by anything added later — if you introduce a
/// property, it belongs behind `queue` too.
final class SSHSession: @unchecked Sendable {

    /// The key the server presented, for the caller to persist on first connect.
    let hostKey: HostKeyInfo

    let hostname: String

    private let queue: DispatchQueue
    private var session: OpaquePointer?
    private var socket: Int32
    private var keepAliveTimer: DispatchSourceTimer?

    /// Weak so that a channel the caller has dropped does not keep living, but
    /// tracked so teardown can stop it before the session handle goes away.
    private weak var shellChannel: SSHShellChannel?

    /// The tunnel this session travels through, when it is behind jump hosts.
    /// Retained so the whole chain below stays alive, and torn down after it.
    private var tunnel: SSHTunnel?

    /// Host keys seen for the first time on a hop, for the caller to store.
    /// Empty on a direct connection.
    private(set) var newJumpHostKeys: [JumpHostKey] = []

    /// A hop's key, paired with the host record it came from when there is one.
    struct JumpHostKey: Equatable {
        let hostId: Int64?
        let knownHostsLine: String
    }

    private init(
        session: OpaquePointer,
        socket: Int32,
        hostKey: HostKeyInfo,
        hostname: String,
        queue: DispatchQueue,
        tunnel: SSHTunnel? = nil
    ) {
        self.session = session
        self.socket = socket
        self.hostKey = hostKey
        self.hostname = hostname
        self.queue = queue
        self.tunnel = tunnel
    }

    deinit {
        // Tear down without hopping queues: by deinit nothing else can be using
        // these handles.
        keepAliveTimer?.cancel()
        shellChannel?.teardownOnQueue()
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "closing", "")
            libssh2_session_free(session)
        }
        if socket >= 0 { close(socket) }
        tunnel?.close()
    }

    // MARK: - Connecting

    /// Opens a TCP connection, performs the handshake, checks the host key and
    /// authenticates.
    ///
    /// Throws ``SSHError/unknownHostKey(_:)`` or ``SSHError/hostKeyMismatch(_:)``
    /// *before* sending any credentials, so a rejected key never leaks a
    /// password to the wrong server.
    static func connect(_ params: SSHConnectionParams) async throws -> SSHSession {
        let queue = DispatchQueue(label: "com.sshborg.ssh.\(params.hostname)")

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try makeChain(params, queue: queue))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Builds the jump-host chain, then the target session at the end of it.
    ///
    /// Every session in the chain shares one queue: a hop is only ever driven
    /// from inside the next session's socket callbacks, so putting them on
    /// separate queues would mean two threads inside libssh2 at once.
    private static func makeChain(_ params: SSHConnectionParams, queue: DispatchQueue) throws -> SSHSession {
        guard !params.jumpHosts.isEmpty else {
            return try makeSession(params, queue: queue, tunnel: nil)
        }

        var tunnel: SSHTunnel?
        var realSocket: Int32 = -1
        var collectedKeys: [JumpHostKey] = []

        // Unwind everything built so far if a later hop fails, rather than
        // leaking a half-built chain of live connections.
        func abandon() {
            tunnel?.close()
            tunnel = nil
        }

        for (index, hop) in params.jumpHosts.enumerated() {
            var hopParams = SSHConnectionParams(
                hostname: hop.host,
                port: hop.port,
                // A hop with no username of its own reuses the target's, which
                // is what an ssh_config ProxyJump does.
                username: hop.username ?? params.username,
                auth: hop.auth ?? params.auth
            )
            // A hop with a stored key must match it. Without one, the hop
            // follows the target's policy: when the user has accepted this
            // connection they have accepted its path, and there is otherwise no
            // way to complete a first connection through a bastion at all.
            // A key that is stored and *differs* still stops the chain, which is
            // the case that matters.
            if let entry = hop.knownHostsEntry, !entry.isEmpty {
                hopParams.hostKeyPolicy = .requireMatch(entry)
            } else {
                hopParams.hostKeyPolicy = params.hostKeyPolicy == .acceptOnce
                    ? .acceptOnce
                    : .promptIfUnknown
            }
            hopParams.allowLegacyCiphers = params.allowLegacyCiphers
            hopParams.connectTimeout = params.connectTimeout

            let hopSession: SSHSession
            do {
                hopSession = try makeSession(hopParams, queue: queue, tunnel: tunnel)
            } catch {
                abandon()
                throw error
            }

            if index == 0 { realSocket = hopSession.socket }

            if hop.knownHostsEntry?.isEmpty ?? true {
                collectedKeys.append(
                    JumpHostKey(hostId: hop.hostId, knownHostsLine: hopSession.hostKey.knownHostsLine)
                )
            }

            // Aim at the next hop, or at the real target after the last one.
            let isLast = index == params.jumpHosts.count - 1
            let nextHost = isLast ? params.hostname : params.jumpHosts[index + 1].host
            let nextPort = isLast ? params.port : params.jumpHosts[index + 1].port

            do {
                guard let raw = hopSession.session else { throw SSHError.notConnected }
                tunnel = try SSHTunnel.open(
                    through: hopSession,
                    raw: raw,
                    to: nextHost,
                    port: nextPort,
                    realSocket: realSocket
                )
            } catch {
                hopSession.disconnect()
                abandon()
                throw error
            }
        }

        do {
            let target = try makeSession(params, queue: queue, tunnel: tunnel)
            target.newJumpHostKeys = collectedKeys
            return target
        } catch {
            abandon()
            throw error
        }
    }

    /// The whole blocking connection sequence. Runs on `queue`.
    private static func makeSession(
        _ params: SSHConnectionParams,
        queue: DispatchQueue,
        tunnel: SSHTunnel?
    ) throws -> SSHSession {
        guard libssh2Bootstrap == 0 else {
            throw SSHError.library(code: libssh2Bootstrap, message: "libssh2_init failed")
        }

        // Behind a tunnel there is no socket of our own: we wait on the real one
        // at the bottom of the chain, which is where tunnelled bytes arrive.
        let ownsSocket = tunnel == nil
        let socket: Int32
        if let tunnel {
            socket = tunnel.realSocket
        } else {
            socket = try SSHSocket.connect(
                host: params.hostname,
                port: params.port,
                timeout: params.connectTimeout
            )
        }

        // `libssh2_session_init` is a function-like macro and so is invisible to
        // Swift; the `_ex` form it expands to is the real symbol. The same is
        // true of most of the libssh2 API, hence the `_ex` calls throughout.
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            if ownsSocket { close(socket) }
            throw SSHError.library(code: 0, message: "could not allocate session")
        }

        var succeeded = false
        defer {
            if !succeeded {
                libssh2_session_free(session)
                if ownsSocket { close(socket) }
            }
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Int(params.connectTimeout * 1000))
        // Must be attached before the handshake: it is the first thing to put
        // bytes on the wire.
        tunnel?.attach(to: session)
        SSHAlgorithms.applyPreferences(to: session, allowLegacy: params.allowLegacyCiphers)

        guard libssh2_session_handshake(session, socket) == 0 else {
            throw SSHError.fromSession(session, fallback: "handshake failed")
        }

        let hostKey = try readHostKey(session: session, host: params.hostname, port: params.port)
        try verify(hostKey: hostKey, policy: params.hostKeyPolicy)
        try authenticate(session: session, params: params)

        let sshSession = SSHSession(
            session: session,
            socket: ownsSocket ? socket : -1,
            hostKey: hostKey,
            hostname: params.hostname,
            queue: queue,
            tunnel: tunnel
        )
        sshSession.startKeepAlive(interval: params.keepAliveInterval)

        succeeded = true
        return sshSession
    }

    // MARK: - Host key

    private static func readHostKey(session: OpaquePointer, host: String, port: Int) throws -> HostKeyInfo {
        var length = 0
        var type: Int32 = 0
        guard let blobPointer = libssh2_session_hostkey(session, &length, &type), length > 0 else {
            throw SSHError.library(code: 0, message: "the server presented no host key")
        }

        let blob = Data(bytes: blobPointer, count: length)

        return HostKeyInfo(
            marker: KnownHostsLine.marker(host: host, port: port),
            algorithm: algorithmName(forHostKeyType: type),
            base64Key: blob.base64EncodedString(),
            fingerprint: KnownHostsLine.fingerprint(forKeyBlob: blob)
        )
    }

    private static func algorithmName(forHostKeyType type: Int32) -> String {
        switch type {
        case LIBSSH2_HOSTKEY_TYPE_RSA: "ssh-rsa"
        case LIBSSH2_HOSTKEY_TYPE_DSS: "ssh-dss"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: "ecdsa-sha2-nistp256"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: "ecdsa-sha2-nistp384"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: "ecdsa-sha2-nistp521"
        case LIBSSH2_HOSTKEY_TYPE_ED25519: "ssh-ed25519"
        default: "unknown"
        }
    }

    private static func verify(hostKey: HostKeyInfo, policy: HostKeyPolicy) throws {
        switch policy {
        case .acceptOnce:
            return
        case .promptIfUnknown:
            throw SSHError.unknownHostKey(hostKey)
        case .requireMatch(let storedLine):
            let matches = KnownHostsLine.matches(
                storedLine: storedLine,
                algorithm: hostKey.algorithm,
                base64Key: hostKey.base64Key
            )
            guard matches else { throw SSHError.hostKeyMismatch(hostKey) }
        }
    }

    // MARK: - Authentication

    private static func authenticate(session: OpaquePointer, params: SSHConnectionParams) throws {
        let username = params.username

        switch params.auth {
        case .password(let password):
            let result = username.withCString { user in
                password.withCString { secret in
                    libssh2_userauth_password_ex(
                        session,
                        user, UInt32(strlen(user)),
                        secret, UInt32(strlen(secret)),
                        nil
                    )
                }
            }
            guard result == 0 else {
                throw SSHError.fromSession(session, fallback: "password rejected")
            }

        case .publicKey(let privateKeyPEM, let passphrase):
            let result = username.withCString { user in
                privateKeyPEM.withCString { key in
                    withOptionalCString(passphrase) { secret in
                        // A null public key tells libssh2 to derive it from the
                        // private key, which is what we always want here: the
                        // stored record only carries the private half.
                        libssh2_userauth_publickey_frommemory(
                            session,
                            user, strlen(user),
                            nil, 0,
                            key, strlen(key),
                            secret
                        )
                    }
                }
            }
            guard result == 0 else {
                throw SSHError.fromSession(session, fallback: "key rejected")
            }
        }

        guard libssh2_userauth_authenticated(session) == 1 else {
            throw SSHError.authenticationFailed("the server did not accept the credentials")
        }
    }

    // MARK: - Shell

    /// Opens an interactive shell with a PTY attached.
    func openShell(
        term: String = "xterm-256color",
        columns: Int = 80,
        rows: Int = 24
    ) async throws -> SSHShellChannel {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let session = self.session else {
                    continuation.resume(throwing: SSHError.notConnected)
                    return
                }

                do {
                    let channel = try SSHShellChannel(
                        session: session,
                        queue: self.queue,
                        term: term,
                        columns: columns,
                        rows: rows
                    )
                    self.shellChannel = channel
                    continuation.resume(returning: channel)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Raw access

    /// Runs `body` on the session's serial queue with the libssh2 handle.
    ///
    /// This is the seam SFTP is built on. It is deliberately the only way to
    /// reach the raw pointer: the queue is what makes a libssh2 session safe to
    /// touch, and handing the pointer out unguarded would break that.
    ///
    /// Note the session is in blocking mode until a shell is opened on it, and
    /// SFTP therefore uses a connection of its own — the same arrangement the
    /// Android app has, where `openSftp` builds its own session.
    func withRawSession<T: Sendable>(
        _ body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let session = self?.session else {
                    continuation.resume(throwing: SSHError.notConnected)
                    return
                }
                do {
                    continuation.resume(returning: try body(session))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Keepalive

    /// Matches the Android configuration: a keepalive every 30 seconds, with the
    /// server asked to reply so a dead link is noticed rather than lingering.
    private func startKeepAlive(interval: TimeInterval) {
        guard let session, interval > 0 else { return }
        libssh2_keepalive_config(session, 1, UInt32(interval))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let session = self?.session else { return }
            var secondsToNext: Int32 = 0
            // Once a shell is open the session is non-blocking, so this can
            // return EAGAIN. That is harmless: the next tick sends it.
            _ = libssh2_keepalive_send(session, &secondsToNext)
        }
        timer.resume()
        keepAliveTimer = timer
    }

    // MARK: - Teardown

    func disconnect() {
        queue.async { [self] in
            keepAliveTimer?.cancel()
            keepAliveTimer = nil

            // Stop the channel first: once the session is freed and the socket
            // closed, any pump still scheduled would be operating on dangling
            // handles.
            shellChannel?.teardownOnQueue()
            shellChannel = nil

            if let session {
                libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "closing", "")
                libssh2_session_free(session)
                self.session = nil
            }
            if socket >= 0 {
                close(socket)
                socket = -1
            }
            // After this session's own handles, never before: the chain below
            // is what its bytes were travelling through.
            tunnel?.close()
            tunnel = nil
        }
    }
}

/// Calls `body` with a C string, or with `nil` when there is nothing to pass.
private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString(body)
}
