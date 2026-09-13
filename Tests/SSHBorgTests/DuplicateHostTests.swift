// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// Duplicating a host, ported from the Android `cloneHost`.
///
/// The assertion that matters is the boring one: everything except the three
/// fields that must change is carried over. Duplicating exists to reuse a host's
/// settings and tweak one detail, so a field quietly dropped here — a jump
/// chain, a port forward, an agent-forwarding flag — turns the copy into a host
/// that looks right and does not work.
@MainActor
final class DuplicateHostTests: XCTestCase {

    private var database: AppDatabase!
    private var model: HostsModel!
    private var preferences: AppPreferences!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()

        // A suite of its own, so the test never reads or writes the real defaults.
        let suiteName = "duplicate-host-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        preferences = AppPreferences(defaults: defaults)

        model = HostsModel(
            hosts: HostRepository(database),
            groups: HostGroupRepository(database),
            preferences: preferences
        )
    }

    private func makeFullyConfiguredHost() -> Host {
        var host = Host(label: "production", hostname: "server.example", username: "deploy")
        host.port = 2222
        host.password = "hunter2"
        host.knownHostsEntry = "server.example ssh-ed25519 AAAAC3Nz…"
        host.agentForwarding = true
        host.lastConnected = 1_700_000_000_000
        host.connectCount = 7
        host.position = 3
        host.jumpHosts = "bastion.example:22"
        host.jumpHostKeys = "bastion.example ssh-ed25519 AAAAC3Nz…"
        host.portForwardings = "8080:localhost:80"
        host.jumpMode = Host.JumpMode.simple.rawValue
        host.sftpStartMode = Host.SFTPStartMode.fixed.rawValue
        host.sftpStartDir = "/var/www"
        host.allowLegacyCiphers = true
        host.color = 0xFF0000
        return host
    }

    func testTheCopyIsANewRowWithACopyLabelAndNoHistory() async throws {
        let saved = try await HostRepository(database).save(makeFullyConfiguredHost())
        let copy = await model.duplicate(saved)

        let unwrapped = try XCTUnwrap(copy)
        XCTAssertNotNil(unwrapped.id)
        XCTAssertNotEqual(unwrapped.id, saved.id, "the copy reused the original's row")
        XCTAssertEqual(unwrapped.label, "production (copy)")
        XCTAssertNil(unwrapped.lastConnected, "the copy inherited a history that is not its own")
        XCTAssertEqual(unwrapped.connectCount, 0, "the copy inherited a usage count that is not its own")
        XCTAssertNil(unwrapped.position, "the copy took the original's turn in the manual order")
    }

    func testEverythingElseComesAcrossVerbatim() async throws {
        let saved = try await HostRepository(database).save(makeFullyConfiguredHost())
        let duplicated = await model.duplicate(saved)
        let copy = try XCTUnwrap(duplicated)

        XCTAssertEqual(copy.hostname, saved.hostname)
        XCTAssertEqual(copy.port, saved.port)
        XCTAssertEqual(copy.username, saved.username)
        XCTAssertEqual(copy.password, saved.password)
        XCTAssertEqual(copy.keyId, saved.keyId)
        XCTAssertEqual(copy.agentForwarding, saved.agentForwarding)
        XCTAssertEqual(copy.jumpHosts, saved.jumpHosts)
        XCTAssertEqual(copy.jumpHostKeys, saved.jumpHostKeys)
        XCTAssertEqual(copy.portForwardings, saved.portForwardings)
        XCTAssertEqual(copy.jumpMode, saved.jumpMode)
        XCTAssertEqual(copy.sftpStartMode, saved.sftpStartMode)
        XCTAssertEqual(copy.sftpStartDir, saved.sftpStartDir)
        XCTAssertEqual(copy.allowLegacyCiphers, saved.allowLegacyCiphers)
        XCTAssertEqual(copy.groupId, saved.groupId)
        XCTAssertEqual(copy.color, saved.color)

        // Deliberate: the copy points at the same server, so the key verified for
        // the original is the right one. Dropping it would raise a fingerprint
        // prompt with nothing to check it against.
        XCTAssertEqual(copy.knownHostsEntry, saved.knownHostsEntry)
    }

    func testTheOriginalIsUntouched() async throws {
        let saved = try await HostRepository(database).save(makeFullyConfiguredHost())
        _ = await model.duplicate(saved)

        let all = try await HostRepository(database).fetchAll()
        XCTAssertEqual(all.count, 2)
        let original = try XCTUnwrap(all.first { $0.id == saved.id })
        XCTAssertEqual(original.label, "production")
        XCTAssertEqual(original.lastConnected, 1_700_000_000_000)
    }
}
