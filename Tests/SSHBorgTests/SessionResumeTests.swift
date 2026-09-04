// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Going back into a terminal you have left, when it is the only one open.
///
/// Reported from the phone on 04/09/2026: open a session, leave with the back
/// chevron or the swipe, and there is no way back in. The host row does
/// nothing, "Resume terminal" does nothing, the session picker does nothing.
/// Opening a *second* session works, and closing it lands you back in the
/// first — which is what made it look like a problem with the tabs.
///
/// It was not. `RootView` drove the navigation off `selected?.id`, and
/// `selected` answers with the first tab when nothing is selected. Leaving set
/// the selection to nil, which that property reported as session 1; tapping the
/// host set it to session 1, which it also reported as session 1. The navigation
/// watches for a change, and there was none to see. A second session was the
/// only thing that produced a different id.
///
/// No server needed: nothing here connects, and the defect never involved a
/// connection.
@MainActor
final class SessionResumeTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
    }

    private func makeHost(_ label: String) async throws -> Host {
        try await hosts.save(Host(label: label, hostname: "example.invalid", username: "user"))
    }

    /// The property `RootView` navigates on must tell the two screens apart.
    func testLeavingTheOnlySessionIsDistinguishableFromBeingInIt() async throws {
        let manager = SessionManager()
        let session = manager.open(host: try await makeHost("only"), hosts: hosts, keys: keys)

        let inTerminal = manager.selectedID
        XCTAssertEqual(inTerminal, session.id)

        // The back chevron and the swipe, both of which end here.
        manager.selectedID = nil
        let onHostList = manager.selectedID

        XCTAssertNotEqual(
            inTerminal, onHostList,
            "nothing selected reads the same as session 1 selected, so there is no edge to navigate on"
        )

        // Tapping the host row, "Resume terminal", or the session picker.
        manager.selectedID = session.id
        XCTAssertNotEqual(
            manager.selectedID, onHostList,
            "resuming the only session has to move the value the stack watches"
        )
        XCTAssertEqual(manager.sessions.count, 1, "resuming must reuse the tab, not open another")
    }

    /// The fallback that caused it is still there, on purpose — it is what the
    /// terminal draws while it slides away. This pins it, so that anyone who
    /// points navigation back at `selected` finds the reason not to.
    func testSelectedStillReportsTheFirstTabWhenNothingIsSelected() async throws {
        let manager = SessionManager()
        let session = manager.open(host: try await makeHost("only"), hosts: hosts, keys: keys)

        manager.selectedID = nil

        XCTAssertEqual(
            manager.selected?.id, session.id,
            "display fallback: it draws the last session on the way out, and it cannot be navigated on"
        )
    }

    /// The way it was found: a second session made everything work again.
    func testASecondSessionAndTheWayBackFromIt() async throws {
        let manager = SessionManager()
        let host = try await makeHost("twice")
        let first = manager.open(host: host, hosts: hosts, keys: keys)

        manager.selectedID = nil

        let second = manager.open(host: host, hosts: hosts, keys: keys)
        XCTAssertEqual(manager.selectedID, second.id)
        XCTAssertEqual(manager.sessions.count, 2)

        // Picking the first from the tab strip, which was the one press that
        // appeared to do nothing.
        manager.selectedID = first.id
        XCTAssertEqual(manager.selected?.id, first.id)

        // Closing the visible one falls back to what is left, as it always did.
        manager.selectedID = second.id
        manager.close(second)
        XCTAssertEqual(manager.selectedID, first.id)
        XCTAssertEqual(manager.sessions.map(\.id), [first.id])

        manager.close(first)
        XCTAssertNil(manager.selectedID, "the last tab closing has to send the stack back to the host list")
        XCTAssertNil(manager.selected)
    }
}
