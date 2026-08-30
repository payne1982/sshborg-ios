// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// Drives the backup rows on the settings screen.
///
/// The preference rows need no model at all — they read and write
/// ``AppPreferences`` directly, which is already observable. Only export and
/// import have work to report on, so only they are here.
@MainActor
@Perceptible
final class SettingsModel {

    /// A finished operation, shown until the user dismisses it.
    enum Outcome: Equatable {
        case exported(hosts: Int)
        case imported(inserted: Int, updated: Int)
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) var outcome: Outcome?
    private(set) var isWorking = false

    /// The file offered to the exporter, written when the user asks to export.
    private(set) var exportDocument: BackupDocument?

    @PerceptionIgnored private let service: BackupService

    init(service: BackupService) {
        self.service = service
    }

    func dismissOutcome() {
        outcome = nil
    }

    // MARK: - Export

    /// Builds the file. The share sheet is presented by the view once
    /// ``exportDocument`` is set.
    func prepareExport() async {
        isWorking = true
        defer { isWorking = false }

        do {
            let archive = try await service.export()
            exportDocument = BackupDocument(data: try archive.jsonData())
            pendingHostCount = archive.hosts.count
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    /// Called once the exporter has finished, successfully or not.
    func finishExport(succeeded: Bool, message: String?) {
        exportDocument = nil

        if succeeded {
            outcome = .exported(hosts: pendingHostCount)
        } else if let message {
            outcome = .failed(message)
        }
    }

    private var pendingHostCount = 0

    /// A suggested name carrying the date, so several backups do not collide in
    /// the Files app.
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "sshborg-backup-\(formatter.string(from: Date()))"
    }

    // MARK: - Import

    func importBackup(from url: URL) async {
        isWorking = true
        defer { isWorking = false }

        // A file chosen outside the sandbox needs its access opened explicitly.
        guard url.startAccessingSecurityScopedResource() else {
            outcome = .failed("That file could not be opened.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let archive = try BackupArchive.decode(try Data(contentsOf: url))
            let result = try await service.restore(archive)
            outcome = .imported(inserted: result.inserted, updated: result.updated)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }
}
