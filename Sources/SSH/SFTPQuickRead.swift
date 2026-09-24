// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// Reads a few small files over an SFTP channel opened on a session that is
/// already connected — the terminal's own.
///
/// ``SFTPSession`` deliberately carries a connection of its own, because a
/// session with a shell on it has been switched to non-blocking mode and every
/// call there can come back `EAGAIN` instead of waiting. That is the right trade
/// for the file browser, which makes hundreds of calls; it is the wrong one for
/// the shell history, which reads three files once and used to pay for a second
/// handshake and a second login to do it — another entry in `fail2ban`'s count,
/// another prompt for anyone on OTP or keyboard-interactive, the whole jump-host
/// chain again, and a host-key check that could only be `acceptOnce` because the
/// key had just been verified by the connection standing right next to it.
/// Android removed that second login on 19/09/2026 and this is the same removal.
///
/// So the `EAGAIN` handling lives here instead. Each attempt is its own hop onto
/// the session queue — never a spin inside one — so the terminal keeps reading
/// while the history is fetched.
///
/// ⚠️ **A call that answers `EAGAIN` must be repeated until it answers something
/// else.** libssh2 keeps its state machine in the call itself, and starting a
/// different call on the same handle leaves that state half-finished. Abandoning
/// a `libssh2_sftp_shutdown` after five seconds is what crashed the test
/// process on 24/09/2026: `libssh2_session_free` later walked the channel list
/// it had half-unlinked and died in `_libssh2_list_remove`. So nothing here
/// gives up mid-call. The deadline is checked *between* calls, and the only
/// thing that ends a retry loop early is the session going away underneath it —
/// at which point libssh2 owns the wreckage and nobody will touch it again.
enum SFTPQuickRead {

    /// The libssh2 SFTP pointer, boxed so the `@Sendable` closures can carry it
    /// between attempts. Same invariant as ``SFTPSession/Handle``: it is only
    /// ever dereferenced inside `withRawSession`, on the session's own queue.
    private struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    /// Reads `names`, each relative to the remote home directory, and returns
    /// what was found. A name that does not exist is simply absent from the
    /// result: a missing `.zsh_history` is the normal state of most accounts.
    ///
    /// `timeout` bounds the whole operation, and only between calls: a file
    /// still arriving when it expires is given up on, the channel is closed
    /// properly, and whatever arrived before it is returned.
    static func readFromHome(
        _ names: [String],
        on session: SSHSession,
        limit: Int = 512 * 1024,
        timeout: TimeInterval = 20
    ) async throws -> [String: Data] {
        let deadline = Date().addingTimeInterval(timeout)
        let sftp = try await open(on: session)

        do {
            let home = try await resolveHome(sftp, on: session)

            var result: [String: Data] = [:]
            for name in names where Date() < deadline {
                let path = home == "/" ? "/\(name)" : "\(home)/\(name)"
                if let data = try await read(path, sftp: sftp, on: session, limit: limit, deadline: deadline) {
                    result[name] = data
                }
            }

            // Before returning, never after: the caller may disconnect the
            // session the moment this call comes back, and a channel still
            // being shut down then is the crash described above.
            try await shutdown(sftp, on: session)
            return result
        } catch {
            try? await shutdown(sftp, on: session)
            throw error
        }
    }

    // MARK: - The steps

    private static func open(on session: SSHSession) async throws -> Handle {
        try await repeating(on: session) { raw in
            if let sftp = libssh2_sftp_init(raw) {
                return Handle(pointer: sftp)
            }
            // A pointer-returning call reports EAGAIN through the session, not
            // through a return code: NULL alone is not a refusal.
            guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
                throw SSHError.fromSession(raw, fallback: "the server refused an SFTP channel")
            }
            return nil
        }
    }

    /// The directory the server puts us in. A server that will not resolve "."
    /// is unusual but not fatal here: the caller's paths are then relative to
    /// the root, which is what an absolute-path history file would want anyway.
    private static func resolveHome(_ sftp: Handle, on session: SSHSession) async throws -> String {
        try await repeating(on: session) { _ in
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = ".".withCString { path in
                libssh2_sftp_symlink_ex(
                    sftp.pointer,
                    path, UInt32(1),
                    &buffer, UInt32(buffer.count),
                    LIBSSH2_SFTP_REALPATH
                )
            }
            if length == LIBSSH2_ERROR_EAGAIN { return nil }
            guard length > 0 else { return "/" }
            return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Reads one file whole, or `nil` when the server says there is no such
    /// file. Reading is the one step that spans several attempts: each one takes
    /// what libssh2 has ready and the rest is picked up on the next.
    private static func read(
        _ path: String,
        sftp: Handle,
        on session: SSHSession,
        limit: Int,
        deadline: Date
    ) async throws -> Data? {
        guard let file = try await openFile(path, sftp: sftp, on: session) else {
            return nil
        }

        var data = Data()

        while data.count < limit, Date() < deadline {
            // Not `repeating`: EAGAIN in the middle of a file is not a call to
            // resume, it is "nothing has arrived yet", and the loop below is
            // already the repetition. It carries the deadline for the same
            // reason — this is the one step that can take real time.
            let chunk: Data? = try await session.withRawSession { _ in
                var buffer = [CChar](repeating: 0, count: chunkSize)
                let count = libssh2_sftp_read(file.pointer, &buffer, buffer.count)
                if count == Int(LIBSSH2_ERROR_EAGAIN) { return nil }
                // Zero is the end of the file; a negative code is a read that
                // will not recover, and there is nothing useful to say about a
                // history file that stopped arriving.
                guard count > 0 else { return Data() }
                return Data(bytes: buffer, count: Int(count))
            }

            guard let chunk else {
                try await Task.sleep(nanoseconds: retryInterval)
                continue
            }
            if chunk.isEmpty { break }
            data.append(chunk)
        }

        try await close(file, on: session)
        return data
    }

    private static func openFile(
        _ path: String,
        sftp: Handle,
        on session: SSHSession
    ) async throws -> Handle? {
        // Optional twice over: `nil` from the closure means "not yet", and the
        // `Handle?` it eventually yields means "no such file".
        try await repeating(on: session) { raw -> Handle?? in
            if let handle = path.withCString({ remote in
                libssh2_sftp_open_ex(
                    sftp.pointer, remote, UInt32(strlen(remote)),
                    UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE
                )
            }) {
                return .some(Handle(pointer: handle))
            }
            guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
                // Anything else is the file's own business — most often that it
                // is not there, which is not worth failing the history over.
                return .some(nil)
            }
            return nil
        }
    }

    private static func close(_ file: Handle, on session: SSHSession) async throws {
        try await repeating(on: session) { _ in
            let result = libssh2_sftp_close_handle(file.pointer)
            return result == Int32(LIBSSH2_ERROR_EAGAIN) ? nil : ()
        }
    }

    private static func shutdown(_ sftp: Handle, on session: SSHSession) async throws {
        try await repeating(on: session) { _ in
            let result = libssh2_sftp_shutdown(sftp.pointer)
            return result == Int32(LIBSSH2_ERROR_EAGAIN) ? nil : ()
        }
    }

    // MARK: - Plumbing

    /// 32 KiB, libssh2's own maximum SFTP payload, as in ``SFTPSession``.
    private static let chunkSize = 32 * 1024

    private static let retryInterval: UInt64 = 10_000_000   // 10 ms

    /// Runs `body` on the session queue and repeats it, unbounded, until it
    /// returns something other than `nil` — which is how a step says "EAGAIN,
    /// call me again".
    ///
    /// Unbounded is the contract, not an oversight: see the warning on the type.
    /// The loop ends when the call finishes, when it throws, or when
    /// `withRawSession` reports the session gone, which is the one exit that
    /// leaves nothing behind to be walked.
    ///
    /// Deliberately one hop per attempt rather than a loop inside the queue: the
    /// terminal's own reads run on that queue, and spinning there would stop the
    /// screen for as long as the history takes.
    private static func repeating<T: Sendable>(
        on session: SSHSession,
        _ body: @escaping @Sendable (OpaquePointer) throws -> T?
    ) async throws -> T {
        while true {
            if let outcome = try await session.withRawSession(body) {
                return outcome
            }
            try await Task.sleep(nanoseconds: retryInterval)
        }
    }
}
