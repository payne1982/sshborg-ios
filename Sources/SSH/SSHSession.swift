// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    private init(session: OpaquePointer, socket: Int32, hostKey: HostKeyInfo, hostname: String, queue: DispatchQueue) {
        self.session = session
        self.socket = socket
        self.hostKey = hostKey
        self.hostname = hostname
        self.queue = queue
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
                    continuation.resume(returning: try makeSession(params, queue: queue))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The whole blocking connection sequence. Runs on `queue`.
    private static func makeSession(_ params: SSHConnectionParams, queue: DispatchQueue) throws -> SSHSession {
        guard libssh2Bootstrap == 0 else {
            throw SSHError.library(code: libssh2Bootstrap, message: "libssh2_init failed")
        }

        let socket = try SSHSocket.connect(
            host: params.hostname,
            port: params.port,
            timeout: params.connectTimeout
        )

        // `libssh2_session_init` is a function-like macro and so is invisible to
        // Swift; the `_ex` form it expands to is the real symbol. The same is
        // true of most of the libssh2 API, hence the `_ex` calls throughout.
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close(socket)
            throw SSHError.library(code: 0, message: "could not allocate session")
        }

        var succeeded = false
        defer {
            if !succeeded {
                libssh2_session_free(session)
                close(socket)
            }
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Int(params.connectTimeout * 1000))
        SSHAlgorithms.applyPreferences(to: session, allowLegacy: params.allowLegacyCiphers)

        guard libssh2_session_handshake(session, socket) == 0 else {
            throw SSHError.fromSession(session, fallback: "handshake failed")
        }

        let hostKey = try readHostKey(session: session, host: params.hostname, port: params.port)
        try verify(hostKey: hostKey, policy: params.hostKeyPolicy)
        try authenticate(session: session, params: params)

        let sshSession = SSHSession(
            session: session,
            socket: socket,
            hostKey: hostKey,
            hostname: params.hostname,
            queue: queue
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
        case .trustOnFirstUse, .acceptOnce:
            return
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
        }
    }
}

/// Calls `body` with a C string, or with `nil` when there is nothing to pass.
private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString(body)
}
