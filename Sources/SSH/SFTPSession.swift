// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// One entry in a remote directory listing.
struct SFTPEntry: Identifiable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modified: Date?
    let permissions: UInt32

    var id: String { name }
}

/// A live SFTP connection, the counterpart of the Android `SftpSession`.
///
/// It carries its own SSH connection rather than sharing the terminal's. That
/// mirrors Android, where `openSftp` builds a separate session, and it avoids a
/// concrete problem here: a session with a shell on it has been switched to
/// non-blocking mode, and every SFTP call would then have to grow an EAGAIN
/// retry loop.
final class SFTPSession: @unchecked Sendable {

    /// The directory the server put us in, which is the user's home.
    let homePath: String

    /// The key the server presented, for the caller to persist on first connect.
    var hostKey: HostKeyInfo { session.hostKey }

    /// Host keys seen for the first time on a jump host, for the caller to
    /// store. Empty on a direct connection.
    var newJumpHostKeys: [SSHSession.JumpHostKey] { session.newJumpHostKeys }

    private let session: SSHSession
    private let sftp: Handle

    /// The libssh2 SFTP pointer, boxed so it can be captured by the `@Sendable`
    /// closures the queue requires.
    ///
    /// The unchecked conformance states the invariant the compiler cannot see:
    /// the pointer is only ever dereferenced inside `withRawSession`, which
    /// serialises everything onto the session's own queue.
    struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private init(session: SSHSession, sftp: Handle, homePath: String) {
        self.session = session
        self.sftp = sftp
        self.homePath = homePath
    }

    // MARK: - Connecting

    static func connect(_ params: SSHConnectionParams) async throws -> SFTPSession {
        let session = try await SSHSession.connect(params)

        do {
            let handle = try await session.withRawSession { raw -> Handle in
                guard let sftp = libssh2_sftp_init(raw) else {
                    throw SSHError.fromSession(raw, fallback: "the server refused an SFTP channel")
                }
                return Handle(pointer: sftp)
            }

            let home = try await Self.resolveHome(session: session, sftp: handle)
            return SFTPSession(session: session, sftp: handle, homePath: home)
        } catch {
            session.disconnect()
            throw error
        }
    }

    private static func resolveHome(session: SSHSession, sftp: Handle) async throws -> String {
        try await session.withRawSession { _ in
            let sftp = sftp.pointer
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = ".".withCString { path in
                libssh2_sftp_symlink_ex(
                    sftp,
                    path, UInt32(1),
                    &buffer, UInt32(buffer.count),
                    LIBSSH2_SFTP_REALPATH
                )
            }
            // A server that will not resolve "." is unusual but not fatal:
            // the root is always a valid place to start browsing from.
            guard length > 0 else { return "/" }
            return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    func disconnect() {
        let handle = sftp
        Task { [session] in
            try? await session.withRawSession { _ in
                _ = libssh2_sftp_shutdown(handle.pointer)
            }
            session.disconnect()
        }
    }

    // MARK: - Listing

    /// Lists `path`, directories first and then files, each alphabetically —
    /// the same ordering the Android list uses.
    func list(_ path: String) async throws -> [SFTPEntry] {
        let entries = try await run { sftp in
            guard let handle = path.withCString({ remote in
                libssh2_sftp_open_ex(sftp, remote, UInt32(strlen(remote)), 0, 0, LIBSSH2_SFTP_OPENDIR)
            }) else {
                throw Self.error(sftp, path: path)
            }
            defer { libssh2_sftp_close_handle(handle) }

            var result: [SFTPEntry] = []
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()

            while true {
                let count = libssh2_sftp_readdir_ex(
                    handle,
                    &nameBuffer, nameBuffer.count,
                    nil, 0,
                    &attributes
                )
                guard count > 0 else { break }

                let name = String(
                    decoding: nameBuffer[0..<Int(count)].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                // `.` and `..` are in every listing and are simply not shown.
                // Anything else that is not a name is a name the server should
                // not have been able to offer, and it is dropped rather than
                // used — see ``SFTPNames``, where the reasoning lives.
                guard SFTPNames.isPlain(name) else { continue }

                let mode = UInt32(attributes.permissions & 0xFFFF_FFFF)
                let isSymlink = (mode & 0o170000) == 0o120000

                result.append(SFTPEntry(
                    name: name,
                    isDirectory: (mode & 0o170000) == 0o040000,
                    isSymlink: isSymlink,
                    size: attributes.filesize,
                    modified: attributes.mtime > 0 ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil,
                    permissions: mode & 0o7777
                ))
            }
            return result
        }

        return try await resolveSymlinks(in: entries, at: path)
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// A directory listing reports a symlink's own attributes, so a link to a
    /// folder would look like a file and refuse to open. Only links pay the cost
    /// of the extra round trip.
    private func resolveSymlinks(in entries: [SFTPEntry], at path: String) async throws -> [SFTPEntry] {
        guard entries.contains(where: \.isSymlink) else { return entries }

        let base = path.hasSuffix("/") ? String(path.dropLast()) : path

        return try await run { sftp in
            entries.map { entry in
                guard entry.isSymlink else { return entry }

                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let target = "\(base)/\(entry.name)"
                let ok = target.withCString { remote in
                    libssh2_sftp_stat_ex(
                        sftp, remote, UInt32(strlen(remote)), LIBSSH2_SFTP_STAT, &attributes
                    )
                } == 0

                guard ok else { return entry }

                return SFTPEntry(
                    name: entry.name,
                    isDirectory: (attributes.permissions & 0o170000) == 0o040000,
                    isSymlink: true,
                    size: entry.size,
                    modified: entry.modified,
                    permissions: entry.permissions
                )
            }
        }
    }

    // MARK: - Mutating

    func createDirectory(at path: String) async throws {
        try await run { sftp in
            let result = path.withCString { remote in
                libssh2_sftp_mkdir_ex(sftp, remote, UInt32(strlen(remote)), 0o755)
            }
            guard result == 0 else { throw Self.error(sftp, path: path) }
        }
    }

    func removeFile(at path: String) async throws {
        try await run { sftp in
            let result = path.withCString { remote in
                libssh2_sftp_unlink_ex(sftp, remote, UInt32(strlen(remote)))
            }
            guard result == 0 else { throw Self.error(sftp, path: path) }
        }
    }

    func removeDirectory(at path: String) async throws {
        try await run { sftp in
            let result = path.withCString { remote in
                libssh2_sftp_rmdir_ex(sftp, remote, UInt32(strlen(remote)))
            }
            guard result == 0 else { throw Self.error(sftp, path: path) }
        }
    }

    /// Renames an entry, which is also how it is moved: the server does the work
    /// on its own filesystem and not one byte crosses the network, so a 10 GB
    /// file moves as fast as an empty one.
    ///
    /// **The destination must not already exist**, and that is the caller's job
    /// to check — with ``lstat(_:)``, before calling this. It is the one place
    /// where this project's two SFTP clients disagree, which is why the Android
    /// repo carries `docs/sftp-move.md` about it: SFTP v3 says a rename onto an
    /// existing name is an error, POSIX `rename(2)` says it replaces the
    /// destination, and OpenSSH bridges the two with `posix-rename@openssh.com`.
    /// JSch, on the Android side, switches to that extension whenever the server
    /// offers it and so **overwrites silently**; this call never does, so it
    /// **fails** — the same gesture destroying a file on one platform and being
    /// refused on the other.
    ///
    /// The flags that used to be passed here — `OVERWRITE | ATOMIC | NATIVE` —
    /// were never sent. libssh2 speaks version 3 (`LIBSSH2_SFTP_VERSION 3`) and
    /// writes the flag word only `if(sftp->version >= 5)`, which is in the
    /// shipped `sftp.c` and was read there rather than guessed. They are gone
    /// rather than left as a statement of intent: a constant named `OVERWRITE`
    /// that cannot overwrite is worse than no constant at all.
    func rename(from source: String, to destination: String) async throws {
        try await run { sftp in
            let result = source.withCString { from in
                destination.withCString { to in
                    libssh2_sftp_rename_ex(
                        sftp,
                        from, UInt32(strlen(from)),
                        to, UInt32(strlen(to)),
                        0
                    )
                }
            }
            guard result == 0 else { throw Self.error(sftp, path: source) }
        }
    }

    /// Creates a symbolic link. Not offered anywhere in the app: it exists
    /// because the rule the move feature is built on — check with ``lstat(_:)``,
    /// never with ``stat(_:)`` — is only demonstrable against a link whose
    /// target is gone, and a claim about the server that no test can reach is a
    /// claim nobody is checking.
    func createSymbolicLink(at path: String, pointingAt target: String) async throws {
        try await run { sftp in
            // The argument order is the library's, not the obvious one: for
            // `LIBSSH2_SFTP_SYMLINK` the first path is what the link points at
            // and the mutable buffer is the link being created — the same way
            // round as the `libssh2_sftp_symlink` macro, which reads
            // `(orig, linkpath)`. Passing them the other way answers
            // "SFTP operation failed", which is how this was found.
            var link = Array(path.utf8CString)
            let result = target.withCString { original in
                libssh2_sftp_symlink_ex(
                    sftp,
                    original, UInt32(strlen(original)),
                    &link, UInt32(path.utf8.count),
                    LIBSSH2_SFTP_SYMLINK
                )
            }
            guard result == 0 else { throw Self.error(sftp, path: path) }
        }
    }

    /// Attributes of one path, or `nil` when it does not exist. Follows symbolic
    /// links, so it describes whatever a link points at.
    func stat(_ path: String) async throws -> SFTPEntry? {
        try await attributes(of: path, following: true)
    }

    /// Attributes of one path **without following a symbolic link**, or `nil`.
    ///
    /// This is the one to ask with before a rename, and the difference is not
    /// academic: a symbolic link whose target has been deleted still owns its
    /// name on the server, and ``stat(_:)`` — which follows it — reports nothing
    /// at all. The name would look free, the rename would be issued, and the
    /// server would refuse it. `docs/sftp-move.md` in the Android repo says the
    /// same thing for the same reason.
    func lstat(_ path: String) async throws -> SFTPEntry? {
        try await attributes(of: path, following: false)
    }

    /// `chmod`, over SFTP: only the permission bits are sent, so nothing else
    /// about the file is touched.
    func setPermissions(_ mode: UInt32, at path: String) async throws {
        try await run { sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attributes.permissions = UInt(mode & 0o7777)
            let result = path.withCString { remote in
                libssh2_sftp_stat_ex(
                    sftp, remote, UInt32(strlen(remote)), LIBSSH2_SFTP_SETSTAT, &attributes
                )
            }
            guard result == 0 else { throw Self.error(sftp, path: path) }
        }
    }

    private func attributes(of path: String, following: Bool) async throws -> SFTPEntry? {
        try await run { sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let kind = following ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT
            let result = path.withCString { remote in
                libssh2_sftp_stat_ex(sftp, remote, UInt32(strlen(remote)), kind, &attributes)
            }
            guard result == 0 else { return nil }

            let mode = UInt32(attributes.permissions & 0xFFFF_FFFF)
            return SFTPEntry(
                name: (path as NSString).lastPathComponent,
                isDirectory: (mode & 0o170000) == 0o040000,
                // Always false when the link was followed: there is nothing left
                // to report, the answer is about the target.
                isSymlink: !following && (mode & 0o170000) == 0o120000,
                size: attributes.filesize,
                modified: attributes.mtime > 0 ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil,
                permissions: mode & 0o7777
            )
        }
    }

    // MARK: - Transfers

    /// A download that went past the `maximumBytes` it was given.
    struct TooLarge: Error, Equatable {
        /// What had arrived when it stopped, the chunk that crossed included.
        let received: UInt64
    }

    /// Downloads to a local file, reporting cumulative bytes.
    ///
    /// Streamed to disk rather than gathered in memory: a phone cannot hold a
    /// multi-gigabyte file, and this is a file manager.
    ///
    /// `maximumBytes` counts what arrives, not what the server said the size
    /// was: a file that grows while it is read, or a server whose `stat` is
    /// wrong, would otherwise take a caller past a limit it had checked. Nil
    /// for a transfer, which has none. Proposed by an audit on 30/10/2026.
    func download(
        from remotePath: String,
        to localURL: URL,
        maximumBytes: UInt64? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: localURL)

        do {
            try await run { sftp in
                guard let handle = remotePath.withCString({ remote in
                    libssh2_sftp_open_ex(
                        sftp, remote, UInt32(strlen(remote)),
                        UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE
                    )
                }) else {
                    throw Self.error(sftp, path: remotePath)
                }
                defer { libssh2_sftp_close_handle(handle) }

                var buffer = [CChar](repeating: 0, count: Self.chunkSize)
                var total: UInt64 = 0

                while true {
                    if isCancelled?() == true { throw SSHError.cancelled }

                    let count = libssh2_sftp_read(handle, &buffer, buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw Self.error(sftp, path: remotePath) }

                    total += UInt64(count)
                    if let maximumBytes, total > maximumBytes { throw TooLarge(received: total) }

                    let chunk = Data(bytes: buffer, count: Int(count))
                    try output.write(contentsOf: chunk)
                    onProgress?(total)
                }
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    /// Uploads a local file, reporting cumulative bytes.
    func upload(
        from localURL: URL,
        to remotePath: String,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws {
        try await write(
            localURL,
            to: remotePath,
            flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC),
            mode: 0o644,
            isCancelled: isCancelled,
            onProgress: onProgress
        )
    }

    /// Create the file, and refuse a name that is already taken rather than
    /// opening whatever is under it — a leftover, a race, or a symlink somebody
    /// left waiting, which "opening" would mean writing through.
    ///
    /// Named here rather than written at the call site so that a test can ask
    /// for the same thing: the C module is not importable from the test target
    /// (adding the package there links it twice and the app stops linking), so
    /// anything a test needs to say about libssh2's flags has to be said from
    /// this side.
    static let createExclusively = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL)

    /// `0600`: what a scratch file is created with, and what a file whose own
    /// mode could not be read is saved as — the safe way for it to be wrong.
    static let ownerOnly: UInt32 = 0o600

    /// The bytes, however the caller wants the file opened.
    ///
    /// `mode` is only consulted when the file is **created**: an existing file
    /// keeps its own permissions through a truncating write, which is why
    /// saving a 0600 config in place never widens it.
    ///
    /// Internal rather than private because it is the only way a test can make
    /// a file with a mode of its choosing, and "the mode is preserved" cannot be
    /// asserted against a file whose mode is whatever the server's umask felt
    /// like.
    func write(
        _ localURL: URL,
        to remotePath: String,
        flags: UInt,
        mode: Int,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws {
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }

        try await run { sftp in
            guard let handle = remotePath.withCString({ remote in
                libssh2_sftp_open_ex(
                    sftp, remote, UInt32(strlen(remote)), flags, mode, LIBSSH2_SFTP_OPENFILE
                )
            }) else {
                throw Self.error(sftp, path: remotePath)
            }
            defer { libssh2_sftp_close_handle(handle) }

            var total: UInt64 = 0

            while true {
                if isCancelled?() == true { throw SSHError.cancelled }

                let chunk = try input.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }

                // A short write is normal, so keep going until the chunk is gone.
                var sent = 0
                while sent < chunk.count {
                    let written: Int = chunk.withUnsafeBytes { raw in
                        let base = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                        return libssh2_sftp_write(handle, base + sent, chunk.count - sent)
                    }
                    guard written > 0 else { throw Self.error(sftp, path: remotePath) }
                    sent += written
                }

                total += UInt64(chunk.count)
                onProgress?(total)
            }
        }
    }

    /// Writes `localURL` over `remotePath` without ever cutting it short,
    /// keeping the file's own permissions, and leaving the original in place —
    /// or, in one narrow case, under a name the error gives — if anything fails.
    ///
    /// ⚠️ Not atomic, and it used to say so. The new contents are never half on
    /// the name the user is editing, which is the promise that matters; but the
    /// swap is three renames, and between the first two the destination has no
    /// file under it. OpenSSH offers no single-step replacing rename through
    /// libssh2 (see ``rename(from:to:)``), so this is as close as it gets, and
    /// ``replace(source:destination:)`` names the parked original if the
    /// connection goes in that gap.
    ///
    /// What this buys over a truncating write is the half-saved file. A save
    /// writes straight onto the name the user is editing, so a network that goes
    /// away mid-upload — which on a phone is the ordinary case rather than the
    /// exception — leaves a file with the first half of the new contents and
    /// nothing else. Here the bytes go to a name nobody is reading, and the
    /// user's file is only touched by renames, each of which either happens or
    /// does not.
    ///
    /// Three things make it safe, and each of them is a thing that went wrong
    /// somewhere else first:
    ///
    /// - **`LIBSSH2_FXF_EXCL`**, so the scratch name is *created* and never
    ///   opened. Android's editor wrote to `.<name>.sshborg-tmp`, a name anyone
    ///   can work out in advance, and in a directory a second account can write
    ///   to that account could leave a symlink waiting under it — the write then
    ///   follows the link and truncates a file somewhere else, with our access.
    ///   Their comment says the guarantee they wanted was `SSH_FXF_EXCL`, which
    ///   the client they use does not expose. libssh2 does.
    /// - **The target's own mode, read before anything is written**, so the
    ///   contents never sit in a file more open than the one they are replacing.
    ///   A new file takes the mode it is given, so this is the one place the mode
    ///   argument matters.
    /// - **Park, move, delete**, because no rename here may land on a name that
    ///   exists: libssh2 speaks SFTP 3 and writes rename flags only from version
    ///   5, so its `OVERWRITE` never leaves the phone. The sequence is the one
    ///   `docs/sftp-move.md` in the Android repo describes for both apps, and at
    ///   no point does the user's file exist under no name at all.
    ///
    /// A target that has gone — somebody deleted it while the editor was open —
    /// is created instead, which is what the editor's Save means there.
    func uploadReplacing(
        from localURL: URL,
        to remotePath: String,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (UInt64) -> Void)? = nil
    ) async throws {
        guard let existing = try await lstat(remotePath), !existing.isDirectory else {
            try await upload(
                from: localURL, to: remotePath, isCancelled: isCancelled, onProgress: onProgress
            )
            return
        }

        // The mode of what is being edited, which for a symbolic link is its
        // **target's**, read with `stat` because `stat` follows. This is what
        // Android does, and the reason it matters: a link's own mode is usually
        // 0777, so taking it from `lstat` gave a file read through a 0600
        // target the permissions of the link — readable by every account that
        // can reach the directory. A target that cannot be read is saved
        // owner-only, which is the safe way for that to be wrong.
        //
        // The save then replaces the link with a regular file, as Android's
        // does; his decision on 29/10/2026, over writing through the link.
        let wanted: UInt32
        if existing.isSymlink {
            wanted = try await stat(remotePath)?.permissions ?? Self.ownerOnly
        } else {
            wanted = existing.permissions
        }

        let scratch = try await freeName(besides: remotePath, marker: "saving")
        do {
            // Created owner-only, whatever the file will end up as: the contents
            // go in while nobody else could read them.
            try await write(
                localURL,
                to: scratch,
                flags: Self.createExclusively,
                mode: Int(Self.ownerOnly),
                isCancelled: isCancelled,
                onProgress: onProgress
            )
            // And the real mode set explicitly, then looked at. What `open` is
            // given goes through the server's umask, so a 0664 original used to
            // come back 0644 — Android sets and checks, and so does this now. A
            // mode that cannot be put on is a save that does not happen, rather
            // than one that quietly changes the file it is saving. A filesystem
            // without modes reads every file back the same, so `wanted` already
            // matches there and nothing is refused.
            if try await stat(scratch)?.permissions != wanted {
                try? await setPermissions(wanted, at: scratch)
                guard try await stat(scratch)?.permissions == wanted else {
                    throw SSHError.library(
                        code: 0,
                        message: "\(scratch) could not be given the file's own permissions"
                    )
                }
            }
            try await replace(source: scratch, destination: remotePath)
        } catch {
            // One `catch` for both steps, and the test is why: a cancelled save
            // throws out of the *write*, which the first version of this did not
            // clean up after — so an interrupted save left the user's file
            // intact, which was the point, and a scratch file beside it, which
            // was not. The user's file is never in doubt here; the only thing to
            // tidy is our own litter. Best effort, and never reported over the
            // top of the failure that matters.
            try? await removeFile(at: scratch)
            throw error
        }
    }

    /// Overwriting, done here rather than asked of the server: park what is in
    /// the way under a free name, move the source into place, delete the parked
    /// copy — and if the move fails, put the parked file back where it was.
    ///
    /// Every rename in that sequence has a free destination, which is what makes
    /// it behave the same under both of this project's SFTP clients, and at no
    /// point does the user's file exist under no name at all.
    ///
    /// Only ever reached for a file: a folder collision does not offer this.
    func replace(source: String, destination: String) async throws {
        let parked = try await freeName(besides: destination, marker: "replaced")
        try await rename(from: destination, to: parked)
        do {
            try await rename(from: source, to: destination)
        } catch {
            // Putting it back, and if that works the original failure is the
            // one to report. If it does not — the connection went between the
            // two renames — the original is safe but under the parked name, and
            // that name is the one thing the person needs: without it the file
            // looks lost. ⚠️ Which is also why this is not called atomic: on
            // OpenSSH there is no rename that replaces a name in one step through
            // libssh2, so for the length of one round trip the destination has
            // no file under it.
            do {
                try await rename(from: parked, to: destination)
            } catch {
                throw SSHError.library(
                    code: 0,
                    message: "The file was not replaced, and the original is kept on the server as "
                        + "\((parked as NSString).lastPathComponent)."
                )
            }
            throw error
        }
        try? await removeFile(at: parked)
    }

    /// A name next to `path` that nothing is using, checked with ``lstat(_:)``
    /// because a dangling symlink still owns its name and `stat` would report it
    /// free.
    ///
    /// Unpredictable rather than merely unique: the point is that nobody can
    /// have arranged for something to be sitting under it. `EXCL` is what makes
    /// that a guarantee rather than a hope, and this only keeps the number of
    /// times it has to be relied on down to one.
    private func freeName(besides path: String, marker: String) async throws -> String {
        for _ in 0..<8 {
            let candidate = "\(path).sshborg-\(marker)-\(UUID().uuidString.prefix(12))"
            if try await lstat(candidate) == nil { return candidate }
        }
        // Eight unpredictable names all taken is not a server, so the message
        // says what was being attempted rather than pretending to diagnose.
        throw SSHError.library(code: 0, message: "no free name beside \(path)")
    }

    /// Removes a partly written remote file, used when an upload is cancelled.
    /// Best effort: if it fails the user sees a truncated file, which is still
    /// better than the app pretending the upload succeeded.
    func discardPartialUpload(at remotePath: String) async {
        try? await removeFile(at: remotePath)
    }

    /// Reads a small remote file whole. Used for things like the shell history,
    /// never for user downloads.
    func readSmallFile(at path: String, limit: Int = 512 * 1024) async throws -> Data {
        try await run { sftp in
            guard let handle = path.withCString({ remote in
                libssh2_sftp_open_ex(
                    sftp, remote, UInt32(strlen(remote)),
                    UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE
                )
            }) else {
                throw Self.error(sftp, path: path)
            }
            defer { libssh2_sftp_close_handle(handle) }

            var buffer = [CChar](repeating: 0, count: Self.chunkSize)
            var data = Data()

            while data.count < limit {
                let count = libssh2_sftp_read(handle, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(Data(bytes: buffer, count: Int(count)))
            }
            return data
        }
    }

    // MARK: - Plumbing

    /// 32 KiB: libssh2's own maximum SFTP packet payload, so a larger buffer
    /// buys nothing.
    private static let chunkSize = 32 * 1024

    private func run<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        let handle = sftp
        return try await session.withRawSession { _ in try body(handle.pointer) }
    }

    /// Turns the SFTP status code into something a person can act on.
    private static func error(_ sftp: OpaquePointer, path: String) -> SSHError {
        let name = (path as NSString).lastPathComponent

        switch libssh2_sftp_last_error(sftp) {
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .library(code: 2, message: "\(name) does not exist.")
        case UInt(LIBSSH2_FX_PERMISSION_DENIED):
            return .library(code: 3, message: "Permission denied for \(name).")
        case UInt(LIBSSH2_FX_FILE_ALREADY_EXISTS):
            return .library(code: 11, message: "\(name) already exists.")
        case UInt(LIBSSH2_FX_DIR_NOT_EMPTY):
            return .library(code: 18, message: "\(name) is not empty.")
        case UInt(LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM):
            return .library(code: 14, message: "The server has no space left.")
        case UInt(LIBSSH2_FX_QUOTA_EXCEEDED):
            return .library(code: 15, message: "The server quota is exhausted.")
        case let code:
            return .library(code: Int32(code), message: "SFTP operation failed on \(name).")
        }
    }
}
