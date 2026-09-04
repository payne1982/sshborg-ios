// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// The open terminal tabs. Counterpart of the Android `SessionManager`.
///
/// Sessions live here rather than in a screen so that a connection survives
/// navigation: leaving the terminal to browse hosts must not drop the shell.
@MainActor
@Perceptible
final class SessionManager {

    private(set) var sessions: [TerminalSession] = []

    /// The tab currently on screen, and the whole answer to whether the
    /// terminal is on screen at all: nil means the host list.
    ///
    /// This is the property to navigate on. `selected` below is not.
    var selectedID: TerminalSession.ID?

    /// The selected session *to draw*, which is a different question.
    ///
    /// The fallback is for the way out. Clearing the selection is what pops the
    /// terminal, and the view is still on screen for the length of that
    /// animation — longer, and under the user's thumb, when it is the back
    /// swipe. Returning nil there would make the last thing seen on every exit
    /// the "no sessions" placeholder, sliding away.
    ///
    /// ⚠️ Never navigate on this. It answers with the first tab for two
    /// different questions — nothing selected, and the first tab selected — so
    /// resuming the only open session is indistinguishable from doing nothing.
    /// That is exactly the bug recorded in `RootView`.
    var selected: TerminalSession? {
        guard let selectedID else { return sessions.first }
        return sessions.first { $0.id == selectedID } ?? sessions.first
    }

    @discardableResult
    func open(host: Host, hosts: HostRepository, keys: SSHKeyRepository) -> TerminalSession {
        let session = TerminalSession(host: host, hosts: hosts, keys: keys)
        // Typing `exit` takes the tab with it. The session notices the shell has
        // gone but cannot remove itself from a list it does not own.
        session.onShellExited = { [weak self] ended in self?.close(ended) }
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

    /// Revives every tab that iOS killed while the app was off screen.
    ///
    /// Called from the scene phase, not from a screen: the terminal view may not
    /// even be on display when the app comes back — the user could have left it
    /// on the host list — and the tabs still have to come back to life.
    ///
    /// Sequential rather than concurrent on purpose. Several tabs on one host
    /// would otherwise open their connections in the same instant, which some
    /// servers rate-limit as a burst; and the reconnections may each need to
    /// read a key out of the keychain.
    func reconnectAfterForeground() async {
        for session in sessions {
            await session.handleReturnToForeground()
        }
    }

    /// Existing tabs for a host, so the UI can offer to reuse one instead of
    /// opening a duplicate connection.
    func sessions(forHostID hostID: Int64) -> [TerminalSession] {
        sessions.filter { $0.host.id == hostID }
    }
}
