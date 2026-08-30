// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// The open file browsers, one per host, held above the screen that shows them.
///
/// Counterpart of Android keeping its SFTP connection in the `SessionManager`
/// rather than the screen: `sessionManager.update(id) { it.copy(sftpSession =
/// session) }` on the way in, and `if (session.sftpSession != null)` to pick it
/// back up on the way back.
///
/// Here the browser's model used to be `@State` on the screen with an
/// `.onDisappear { disconnect() }`, so tapping the back chevron threw the
/// connection away — and, worse, took any download running at that moment with
/// it. Now leaving the screen leaves the session alone and coming back re-attaches
/// to it; only the close button ends it, which is how a terminal tab already
/// behaves.
@MainActor
@Perceptible
final class SFTPBrowsers {

    /// Keyed by host id. A host with no id has never been saved and cannot be
    /// browsed, so there is nothing to key.
    private var models: [Int64: SFTPModel] = [:]

    /// The browser for a host, made on first use and kept afterwards.
    func browser(
        for host: Host,
        hosts: HostRepository,
        keys: SSHKeyRepository
    ) -> SFTPModel {
        guard let id = host.id else {
            return SFTPModel(host: host, hosts: hosts, keys: keys)
        }
        if let existing = models[id] { return existing }

        let model = SFTPModel(host: host, hosts: hosts, keys: keys)
        models[id] = model
        return model
    }

    /// Whether a browser is open for a host, which the host list shows as a
    /// badge of its own.
    ///
    /// Android draws a count there because it can hold several SFTP sessions per
    /// host; this holds one, keyed by host, so a number would always read "1"
    /// and say nothing the badge does not already say by existing.
    func isOpen(hostID: Int64?) -> Bool {
        guard let hostID else { return false }
        return models[hostID] != nil
    }

    /// Ends a browser and forgets it — the close button, not the back chevron.
    func close(_ host: Host) {
        guard let id = host.id, let model = models.removeValue(forKey: id) else { return }
        model.disconnect()
    }

    func closeAll() {
        models.values.forEach { $0.disconnect() }
        models.removeAll()
    }
}
