// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// The open terminal tabs. Counterpart of the Android `SessionManager`.
///
/// Sessions live here rather than in a screen so that a connection survives
/// navigation: leaving the terminal to browse hosts must not drop the shell.
@MainActor
@Observable
final class SessionManager {

    private(set) var sessions: [TerminalSession] = []

    /// The tab currently on screen.
    var selectedID: TerminalSession.ID?

    var selected: TerminalSession? {
        guard let selectedID else { return sessions.first }
        return sessions.first { $0.id == selectedID } ?? sessions.first
    }

    @discardableResult
    func open(host: Host, hosts: HostRepository, keys: SSHKeyRepository) -> TerminalSession {
        let session = TerminalSession(host: host, hosts: hosts, keys: keys)
        sessions.append(session)
        selectedID = session.id
        return session
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }

        if selectedID == session.id {
            selectedID = sessions.last?.id
        }
    }

    func closeAll() {
        sessions.forEach { $0.disconnect() }
        sessions.removeAll()
        selectedID = nil
    }

    /// Existing tabs for a host, so the UI can offer to reuse one instead of
    /// opening a duplicate connection.
    func sessions(forHostID hostID: Int64) -> [TerminalSession] {
        sessions.filter { $0.host.id == hostID }
    }
}
