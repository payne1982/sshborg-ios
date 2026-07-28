// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// The queue of file transfers and their progress. Counterpart of the Android
/// `TransferManager`.
///
/// Downloads land in the app's Documents folder, which `UIFileSharingEnabled`
/// and `LSSupportsOpeningDocumentsInPlace` expose in the Files app under
/// "On My iPhone → SSHBorg". That avoids making the user choose a destination
/// for every single file, and the folder is reachable from outside the app.
@MainActor
@Observable
final class TransferManager {

    struct Transfer: Identifiable {
        enum Kind { case download, upload }

        enum Status: Equatable {
            case running
            case finished
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let kind: Kind
        let name: String
        let totalBytes: UInt64?
        var transferred: UInt64 = 0
        var status: Status = .running

        /// Where a finished download ended up, so the UI can offer to share it.
        var localURL: URL?

        /// `nil` when the size is unknown, which uploads never are and
        /// downloads only are for odd server replies.
        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(transferred) / Double(totalBytes))
        }

        var isActive: Bool { status == .running }
    }

    private(set) var transfers: [Transfer] = []

    /// IDs the user has asked to stop. Read from the transfer loops, which run
    /// off the main actor, hence the lock rather than plain state.
    @ObservationIgnored private let cancellations = CancellationRegistry()

    var hasActiveTransfers: Bool {
        transfers.contains(where: \.isActive)
    }

    // MARK: - Downloading

    @discardableResult
    func download(_ entry: SFTPEntry, from directory: String, using session: SFTPSession) -> Transfer.ID {
        let destination = Self.uniqueLocalURL(for: entry.name)
        let remotePath = directory == "/" ? "/\(entry.name)" : "\(directory)/\(entry.name)"

        var transfer = Transfer(kind: .download, name: entry.name, totalBytes: entry.size)
        transfer.localURL = destination
        transfers.append(transfer)
        let id = transfer.id

        Task {
            let registry = cancellations
            do {
                try await session.download(
                    from: remotePath,
                    to: destination,
                    isCancelled: { registry.isCancelled(id) },
                    onProgress: { bytes in
                        Task { @MainActor in self.update(id) { $0.transferred = bytes } }
                    }
                )
                finish(id, status: .finished)
            } catch {
                finish(id, status: Self.status(for: error))
            }
        }

        return id
    }

    // MARK: - Uploading

    /// Uploads a local file, resolving a name clash the way the caller chose.
    @discardableResult
    func upload(
        from localURL: URL,
        to directory: String,
        named remoteName: String,
        using session: SFTPSession
    ) -> Transfer.ID {
        let remotePath = directory == "/" ? "/\(remoteName)" : "\(directory)/\(remoteName)"
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? nil

        let transfer = Transfer(kind: .upload, name: remoteName, totalBytes: size)
        transfers.append(transfer)
        let id = transfer.id

        Task {
            let registry = cancellations
            do {
                try await session.upload(
                    from: localURL,
                    to: remotePath,
                    isCancelled: { registry.isCancelled(id) },
                    onProgress: { bytes in
                        Task { @MainActor in self.update(id) { $0.transferred = bytes } }
                    }
                )
                finish(id, status: .finished)
            } catch {
                // A stopped upload leaves a truncated file on the server, which
                // looks like a real one. Remove it.
                if case .cancelled = Self.status(for: error) {
                    await session.discardPartialUpload(at: remotePath)
                }
                finish(id, status: Self.status(for: error))
            }
        }

        return id
    }

    /// Whether a given transfer is still running, so a caller can wait on it.
    func isRunning(_ id: Transfer.ID) -> Bool {
        transfers.first { $0.id == id }?.isActive ?? false
    }

    /// A name that does not collide on the server, `report(1).pdf` style —
    /// the same shape the Android downloader produces.
    static func uniqueRemoteName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }

        let base = (name as NSString).deletingPathExtension
        let extensionPart = (name as NSString).pathExtension
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"

        var counter = 1
        while true {
            let candidate = "\(base)(\(counter))\(suffix)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    // MARK: - Controlling

    func cancel(_ id: Transfer.ID) {
        cancellations.cancel(id)
    }

    func dismiss(_ id: Transfer.ID) {
        transfers.removeAll { $0.id == id }
        cancellations.forget(id)
    }

    func dismissFinished() {
        for transfer in transfers where !transfer.isActive {
            cancellations.forget(transfer.id)
        }
        transfers.removeAll { !$0.isActive }
    }

    // MARK: - Plumbing

    private func update(_ id: Transfer.ID, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func finish(_ id: Transfer.ID, status: Transfer.Status) {
        update(id) { transfer in
            transfer.status = status
            // Snap the bar to full so a finished row does not sit at 99%.
            if status == .finished, let total = transfer.totalBytes {
                transfer.transferred = total
            }
        }
        cancellations.forget(id)
    }

    private static func status(for error: Error) -> Transfer.Status {
        if let sshError = error as? SSHError, sshError == .cancelled { return .cancelled }
        return .failed(error.localizedDescription)
    }

    /// Somewhere in Documents that is not already taken, so two downloads of the
    /// same file do not overwrite each other.
    private static func uniqueLocalURL(for name: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let existing = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        )
        return documents.appendingPathComponent(uniqueRemoteName(for: name, existing: existing))
    }
}

/// Tracks which transfers have been cancelled.
///
/// The transfer loops run on the SFTP queue and ask this from there, so it
/// cannot live in main-actor state. A lock around a small set is all it needs.
private final class CancellationRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelled: Set<UUID> = []

    func cancel(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cancelled.insert(id)
    }

    func isCancelled(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(id)
    }

    func forget(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cancelled.remove(id)
    }
}
