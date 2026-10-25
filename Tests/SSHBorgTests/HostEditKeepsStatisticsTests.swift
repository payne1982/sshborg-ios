// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Saving an edit must not throw away what the app knows about a host.
///
/// Five columns of the hosts table are not fields of the edit form: when the
/// host was last connected to, how many times, where the user dragged it in the
/// manual order, and the two sets of pinned host keys, which the connection
/// writes and not the form.
///
/// Android lost all of them, and the diagnosis is worth keeping because the
/// shape of the mistake is available to us too (`ccf94ea`): `upsert` replaces
/// the whole row, so leaving a column out of the entity did not mean "do not
/// touch it", it meant "put it back to the default". Saving an edit reset the
/// most-used counter, forgot the last connection and lost the host's place —
/// two of the three list orders degrading quietly every time anybody renamed
/// anything, and the third losing its arrangement.
///
/// It does not happen here, and the whole reason is one line of
/// `HostEditorScreen.save()`: it starts from the stored record — "Start from the
/// stored record so anything this form does not show survives the edit" — and
/// assigns only what the form shows. That is a property with nothing to stop a
/// later edit dropping it, which is what this test is for.
///
/// It drives the repository the way the screen does rather than the screen
/// itself, because `save()` is private to the view. In exchange the assertion is
/// stronger than naming the five columns: the record must come back **whole**
/// apart from the field that was edited, so a column added later is covered
/// without anybody remembering to come back here.
final class HostEditKeepsStatisticsTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
    }

    func testEditingAHostKeepsEverythingTheFormDoesNotShow() async throws {
        let created = try await hosts.save(
            Host(
                label: "prod",
                hostname: "example.com",
                port: 2222,
                username: "root",
                knownHostsEntry: "example.com ssh-ed25519 AAAA",
                agentForwarding: true,
                jumpHosts: "bastion:22",
                jumpHostKeys: "bastion ssh-ed25519 BBBB",
                jumpMode: Host.JumpMode.simple.rawValue,
                color: 0xFF43_A047,
                mosh: true,
                moshFamily: "ipv6",
                moshPorts: "60010-60020",
                moshCommand: "/usr/local/bin/mosh-server"
            )
        )
        let id = try XCTUnwrap(created.id)

        // Two connections and a drag: the three columns the form never sees, put
        // there the way the app itself puts them.
        try await hosts.recordConnection(id: id, at: Date(timeIntervalSince1970: 1_700_000_000))
        try await hosts.recordConnection(id: id, at: Date(timeIntervalSince1970: 1_700_000_100))
        try await hosts.updatePosition(id: id, to: 4)

        let afterUse = try await hosts.fetch(id: id)
        let stored = try XCTUnwrap(afterUse)
        XCTAssertEqual(stored.connectCount, 2, "the fixture recorded nothing to lose")
        XCTAssertEqual(stored.position, 4)
        XCTAssertNotNil(stored.lastConnected)

        // What the editor does with the Save button: start from the stored
        // record, assign the form's fields, write it back.
        var edited = stored
        edited.label = "production"
        _ = try await hosts.save(edited)

        var expected = stored
        expected.label = "production"
        let afterEdit = try await hosts.fetch(id: id)
        let reloaded = try XCTUnwrap(afterEdit)
        XCTAssertEqual(reloaded, expected, "the save lost a column the form does not show")
    }

    /// The other half of the same property: a host saved from scratch gets the
    /// defaults, so the test above is not passing because everything is already
    /// zero.
    func testANewHostStartsWithNoStatistics() async throws {
        let saved = try await hosts.save(Host(label: "new", hostname: "h.example", username: "u"))

        XCTAssertNil(saved.lastConnected)
        XCTAssertEqual(saved.connectCount, 0)
        XCTAssertNil(saved.position)
    }
}
