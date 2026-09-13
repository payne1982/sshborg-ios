// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import XCTest

@testable import SSHBorg

final class AppDatabaseTests: XCTestCase {

    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
    }

    // MARK: - Schema

    func testMigrationCreatesAllTables() throws {
        try database.writer.read { db in
            XCTAssertTrue(try db.tableExists("hosts"))
            XCTAssertTrue(try db.tableExists("ssh_keys"))
            XCTAssertTrue(try db.tableExists("host_groups"))
        }
    }

    /// The Android Room entity has these 24 columns, its version 13. A mismatch
    /// means the shared JSON backup would silently drop a field.
    ///
    /// It has already earned its keep: `sftpShowHidden` was added to the model,
    /// the migration and the backup, and this is what proved the three agreed.
    func testHostColumnsMatchAndroidEntity() throws {
        try database.writer.read { db in
            let columns = try db.columns(in: "hosts").map(\.name)
            XCTAssertEqual(
                Set(columns),
                [
                    "id", "label", "hostname", "port", "username", "keyId",
                    "password", "encryptedPassword", "knownHostsEntry",
                    "agentForwarding", "lastConnected", "jumpHosts", "jumpHostKeys",
                    "portForwardings", "jumpMode", "jumpHostIdList", "sftpStartMode",
                    "sftpStartDir", "sftpShowHidden", "allowLegacyCiphers",
                    "groupId", "color", "position", "connectCount",
                ]
            )
        }
    }

    // MARK: - Round trips

    func testHostRoundTripPreservesEveryField() async throws {
        let repository = HostRepository(database)

        let host = Host(
            label: "prod",
            hostname: "example.com",
            port: 2222,
            username: "root",
            password: "hunter2",
            knownHostsEntry: "example.com ssh-ed25519 AAAA",
            agentForwarding: true,
            lastConnected: 1_700_000_000_000,
            jumpHosts: "bastion:22",
            jumpHostKeys: "bastion ssh-ed25519 BBBB",
            portForwardings: "8080:localhost:80",
            jumpMode: "host_list",
            jumpHostIdList: "3,7",
            sftpStartMode: "fixed",
            sftpStartDir: "/var/log",
            allowLegacyCiphers: true,
            color: 0xFF43_A047
        )

        let saved = try await repository.save(host)
        let id = try XCTUnwrap(saved.id)

        let fetched = try await repository.fetch(id: id)
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.parsedJumpMode, .hostList)
        XCTAssertEqual(loaded.parsedSFTPStartMode, .fixed)
        XCTAssertTrue(loaded.agentForwarding)
        XCTAssertTrue(loaded.allowLegacyCiphers)
    }

    func testDefaultsMatchAndroidEntity() async throws {
        let repository = HostRepository(database)
        let saved = try await repository.save(
            Host(label: "minimal", hostname: "example.com", username: "user")
        )

        XCTAssertEqual(saved.port, 22)
        XCTAssertEqual(saved.jumpMode, "simple")
        XCTAssertEqual(saved.sftpStartMode, "last")
        XCTAssertFalse(saved.agentForwarding)
        XCTAssertFalse(saved.allowLegacyCiphers)
        XCTAssertNil(saved.groupId)
        XCTAssertNil(saved.color)
    }

    func testHostsAreOrderedByLabel() async throws {
        let repository = HostRepository(database)
        for label in ["zeta", "alpha", "mid"] {
            _ = try await repository.save(Host(label: label, hostname: "h", username: "u"))
        }
        let labels = try await repository.fetchAll().map(\.label)
        XCTAssertEqual(labels, ["alpha", "mid", "zeta"])
    }

    func testRecordingAConnectionStampsTheTimeAndBumpsTheCount() async throws {
        let repository = HostRepository(database)
        let saved = try await repository.save(Host(label: "h", hostname: "h", username: "u"))
        let id = try XCTUnwrap(saved.id)
        XCTAssertNil(saved.lastConnected)
        XCTAssertEqual(saved.connectCount, 0)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.recordConnection(id: id, at: date)

        let fetched = try await repository.fetch(id: id)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertEqual(reloaded.lastConnected, 1_700_000_000_000)
        XCTAssertEqual(reloaded.connectCount, 1)

        // The counter is the only record of a connection that is not the last
        // one, so a second connection must not simply overwrite the first.
        try await repository.recordConnection(id: id, at: date.addingTimeInterval(60))
        let second = try await repository.fetch(id: id)
        let again = try XCTUnwrap(second)
        XCTAssertEqual(again.connectCount, 2)
        XCTAssertEqual(again.lastConnected, 1_700_000_060_000)
    }

    func testPositionsAreWrittenInOneTransaction() async throws {
        let repository = HostRepository(database)
        var ids: [Int64] = []
        for label in ["a", "b", "c"] {
            let saved = try await repository.save(Host(label: label, hostname: "h", username: "u"))
            ids.append(try XCTUnwrap(saved.id))
        }

        try await repository.updatePositions([
            (ids[0], 2), (ids[1], 0), (ids[2], 1),
        ])

        let byID = Dictionary(uniqueKeysWithValues: try await repository.fetchAll().map { ($0.id, $0.position) })
        XCTAssertEqual(byID[ids[0]], 2)
        XCTAssertEqual(byID[ids[1]], 0)
        XCTAssertEqual(byID[ids[2]], 1)
    }

    // MARK: - Referential integrity

    /// Deleting a key must not delete the hosts that used it: they fall back to
    /// password authentication instead of vanishing from the user's list.
    func testDeletingKeyDetachesHostsButKeepsThem() async throws {
        let keys = SSHKeyRepository(database)
        let hosts = HostRepository(database)

        let key = try await keys.save(
            SSHKey(label: "id_ed25519", keyType: "ED25519", publicKey: "ssh-ed25519 AAAA")
        )
        let keyId = try XCTUnwrap(key.id)

        let host = try await hosts.save(
            Host(label: "h", hostname: "example.com", username: "u", keyId: keyId)
        )
        let hostId = try XCTUnwrap(host.id)

        let usageCount = try await keys.hostCount(usingKeyId: keyId)
        XCTAssertEqual(usageCount, 1)

        try await keys.delete(key)

        let fetched = try await hosts.fetch(id: hostId)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertNil(reloaded.keyId, "the host must survive with its key reference cleared")
    }

    /// Same contract for groups: deleting a group ungroups its hosts.
    func testDeletingGroupDetachesHostsButKeepsThem() async throws {
        let groups = HostGroupRepository(database)
        let hosts = HostRepository(database)

        let group = try await groups.save(HostGroup(name: "servers", color: HostGroup.swatches[0]))
        let groupId = try XCTUnwrap(group.id)

        let host = try await hosts.save(
            Host(label: "h", hostname: "example.com", username: "u", groupId: groupId)
        )
        let hostId = try XCTUnwrap(host.id)

        try await groups.delete(group)

        let remainingGroups = try await groups.fetchAll()
        XCTAssertTrue(remainingGroups.isEmpty)

        let fetched = try await hosts.fetch(id: hostId)
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertNil(reloaded.groupId)
    }

    func testGroupLookupByName() async throws {
        let groups = HostGroupRepository(database)
        _ = try await groups.save(HostGroup(name: "servers", color: HostGroup.swatches[1]))

        let existing = try await groups.fetch(name: "servers")
        XCTAssertNotNil(existing)

        let missing = try await groups.fetch(name: "missing")
        XCTAssertNil(missing)
    }

    func testSetCollapsed() async throws {
        let groups = HostGroupRepository(database)
        let group = try await groups.save(HostGroup(name: "servers", color: HostGroup.swatches[2]))
        let id = try XCTUnwrap(group.id)

        try await groups.setCollapsed(id: id, true)

        let all = try await groups.fetchAll()
        let reloaded = try XCTUnwrap(all.first)
        XCTAssertTrue(reloaded.collapsed)
    }

    // MARK: - Colours

    /// The swatch list is shared with Android so that a restored group keeps its
    /// colour. All ten must be fully opaque ARGB values.
    func testSwatchesAreOpaqueARGB() {
        XCTAssertEqual(HostGroup.swatches.count, 10)
        for swatch in HostGroup.swatches {
            XCTAssertEqual((swatch >> 24) & 0xFF, 0xFF, "swatch \(String(swatch, radix: 16)) is not opaque")
        }
    }
}
