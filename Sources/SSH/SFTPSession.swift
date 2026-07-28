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
                guard name != ".", name != ".." else { continue }

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

    func rename(from source: String, to destination: String) async throws {
        try await run { sftp in
            let flags = Int(
                LIBSSH2_SFTP_RENAME_OVERWRITE
                    | LIBSSH2_SFTP_RENAME_ATOMIC
                    | LIBSSH2_SFTP_RENAME_NATIVE
            )
            let result = source.withCString { from in
                destination.withCString { to in
                    libssh2_sftp_rename_ex(
                        sftp,
                        from, UInt32(strlen(from)),
                        to, UInt32(strlen(to)),
                        flags
                    )
                }
            }
            guard result == 0 else { throw Self.error(sftp, path: source) }
        }
    }

    /// Attributes of one path, or `nil` when it does not exist.
    func stat(_ path: String) async throws -> SFTPEntry? {
        try await run { sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = path.withCString { remote in
                libssh2_sftp_stat_ex(sftp, remote, UInt32(strlen(remote)), LIBSSH2_SFTP_STAT, &attributes)
            }
            guard result == 0 else { return nil }

            let mode = UInt32(attributes.permissions & 0xFFFF_FFFF)
            return SFTPEntry(
                name: (path as NSString).lastPathComponent,
                isDirectory: (mode & 0o170000) == 0o040000,
                isSymlink: false,
                size: attributes.filesize,
                modified: attributes.mtime > 0 ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil,
                permissions: mode & 0o7777
            )
        }
    }

    // MARK: - Transfers

    /// Downloads to a local file, reporting cumulative bytes.
    ///
    /// Streamed to disk rather than gathered in memory: a phone cannot hold a
    /// multi-gigabyte file, and this is a file manager.
    func download(
        from remotePath: String,
        to localURL: URL,
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

                    let chunk = Data(bytes: buffer, count: Int(count))
                    try output.write(contentsOf: chunk)

                    total += UInt64(count)
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
        let input = try FileHandle(forReadingFrom: localURL)
        defer { try? input.close() }

        try await run { sftp in
            let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
            guard let handle = remotePath.withCString({ remote in
                libssh2_sftp_open_ex(
                    sftp, remote, UInt32(strlen(remote)), flags, 0o644, LIBSSH2_SFTP_OPENFILE
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
