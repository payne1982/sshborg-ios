// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// Checks the backup format against the Android app's, and the merge rules
/// against the ways an import can lose something.
///
/// The parsing tests read a file in the shape the Android writer produces rather
/// than one this app wrote: a reader tested only against our own writer would
/// agree with our own mistakes, and the whole point of this format is that the
/// other platform can read it.
final class BackupTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var groups: HostGroupRepository!
    private var keys: SSHKeyRepository!
    private var preferences: AppPreferences!
    private var service: BackupService!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        groups = HostGroupRepository(database)
        keys = SSHKeyRepository(database)

        // A suite of its own, so the test never reads or writes the real defaults.
        let suiteName = "backup-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        preferences = AppPreferences(defaults: defaults)

        service = BackupService(hosts: hosts, groups: groups, keys: keys, preferences: preferences)
    }

    // MARK: - The Android file

    /// Written by SSHBorg for Android. Note `jumpHosts: ""`, which that writer
    /// emits for an unset field, and the absence of any credential.
    private let androidBackup = """
    {
      "version": 3,
      "exported_at": "2026-07-20T10:31:02.418Z",
      "groups": [
        { "name": "Work", "color": -1499549 },
        { "name": "Home", "color": -12417548 }
      ],
      "hosts": [
        {
          "label": "gateway",
          "hostname": "gw.example.com",
          "port": 2222,
          "username": "admin",
          "agentForwarding": true,
          "jumpMode": "simple",
          "sftpStartMode": "home",
          "allowLegacyCiphers": false,
          "group": "Work",
          "color": -1499549
        },
        {
          "label": "backend",
          "hostname": "10.0.0.5",
          "port": 22,
          "username": "deploy",
          "agentForwarding": false,
          "jumpMode": "simple",
          "sftpStartMode": "last",
          "allowLegacyCiphers": true,
          "jumpHosts": "gw.example.com:2222",
          "portForwardings": "5432:localhost:5432",
          "group": "Work"
        },
        {
          "label": "nas",
          "hostname": "nas.local",
          "port": 22,
          "username": "payne",
          "agentForwarding": false,
          "jumpMode": "simple",
          "sftpStartMode": "fixed",
          "sftpStartDir": "/volume1",
          "allowLegacyCiphers": false,
          "jumpHosts": ""
        }
      ],
      "settings": {
        "confirm_exit": true,
        "lock_timeout_seconds": 300,
        "scrollback_lines": 5000,
        "terminal_font_size": 16,
        "night_mode": 2,
        "terminal_color_scheme": 1,
        "double_tap_action": 2,
        "history_suggestions": false,
        "suggestions_bar_sticky": true,
        "keep_screen_on": true,
        "invert_terminal_scroll": false,
        "allow_screenshots": false
      }
    }
    """

    func testReadsABackupWrittenByAndroid() throws {
        let archive = try BackupArchive.decode(Data(androidBackup.utf8))

        XCTAssertEqual(archive.version, 3)
        XCTAssertEqual(archive.exportedAt, "2026-07-20T10:31:02.418Z")
        XCTAssertEqual(archive.groups.map(\.name), ["Work", "Home"])
        XCTAssertEqual(archive.hosts.count, 3)

        let gateway = archive.hosts[0]
        XCTAssertEqual(gateway.port, 2222)
        XCTAssertTrue(gateway.agentForwarding)
        XCTAssertEqual(gateway.group, "Work")
        XCTAssertEqual(gateway.sftpStartMode, "home")

        let backend = archive.hosts[1]
        XCTAssertEqual(backend.jumpHosts, "gw.example.com:2222")
        XCTAssertEqual(backend.portForwardings, "5432:localhost:5432")
        XCTAssertTrue(backend.allowLegacyCiphers)

        // Android writes "" for a field it has nothing for; that is not a value.
        XCTAssertNil(archive.hosts[2].jumpHosts)
        XCTAssertEqual(archive.hosts[2].sftpStartDir, "/volume1")

        XCTAssertEqual(archive.settings?.lockTimeoutSeconds, 300)
        XCTAssertEqual(archive.settings?.nightMode, 2)
        XCTAssertEqual(archive.settings?.historySuggestions, false)
    }

    /// Older files predate groups and settings and must still load.
    func testReadsAVersionOneBackup() throws {
        let old = """
        { "version": 1, "hosts": [
            { "label": "a", "hostname": "a.example", "username": "u" } ] }
        """

        let archive = try BackupArchive.decode(Data(old.utf8))

        XCTAssertEqual(archive.hosts.count, 1)
        XCTAssertEqual(archive.hosts[0].port, 22)
        XCTAssertEqual(archive.hosts[0].jumpMode, "simple")
        XCTAssertTrue(archive.groups.isEmpty)
        XCTAssertNil(archive.settings)
    }

    func testRejectsSomethingThatIsNotABackup() {
        XCTAssertThrowsError(try BackupArchive.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try BackupArchive.decode(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? BackupArchive.DecodingFailure, .missingHosts)
        }
    }

    func testRejectsAHostWithoutTheFieldsNeededToConnect() {
        let broken = """
        { "version": 3, "hosts": [ { "label": "a", "username": "u" } ] }
        """
        XCTAssertThrowsError(try BackupArchive.decode(Data(broken.utf8))) { error in
            XCTAssertEqual(error as? BackupArchive.DecodingFailure, .malformedHost(index: 0))
        }
    }

    // MARK: - Round trip

    func testWritingAndReadingBackGivesTheSameArchive() throws {
        let original = try BackupArchive.decode(Data(androidBackup.utf8))
        let reparsed = try BackupArchive.decode(try original.jsonData())

        XCTAssertEqual(original, reparsed)
    }

    /// A null field is omitted, not written as `null`: Android's reader uses
    /// `optString`, which turns a JSON null into the string "null".
    func testUnsetFieldsAreOmittedRatherThanNull() throws {
        let archive = BackupArchive(
            exportedAt: "2026-07-20T10:31:02.418Z",
            hosts: [BackupArchive.HostEntry(label: "a", hostname: "a.example", username: "u")]
        )

        let text = String(decoding: try archive.jsonData(), as: UTF8.self)

        XCTAssertFalse(text.contains("null"), "a null leaked into the file:\n\(text)")
        XCTAssertFalse(text.contains("jumpHosts"))
        XCTAssertFalse(text.contains("color"))
    }

    /// The file must never be able to carry a secret.
    func testExportContainsNoCredentials() async throws {
        _ = try await hosts.save(
            Host(
                label: "secret",
                hostname: "h.example",
                username: "u",
                password: "hunter2",
                encryptedPassword: "AAAA-encrypted",
                knownHostsEntry: "h.example ssh-ed25519 AAAA"
            )
        )

        let text = String(decoding: try await service.export().jsonData(), as: UTF8.self)

        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("AAAA-encrypted"))
        XCTAssertFalse(text.contains("knownHostsEntry"))
        XCTAssertFalse(text.contains("keyId"))
    }

    // MARK: - Restoring into a populated database

    func testRestoreInsertsHostsAndGroups() async throws {
        let archive = try BackupArchive.decode(Data(androidBackup.utf8))
        let result = try await service.restore(archive)

        XCTAssertEqual(result.inserted, 3)
        XCTAssertEqual(result.updated, 0)

        let stored = try await hosts.fetchAll()
        XCTAssertEqual(Set(stored.map(\.label)), ["gateway", "backend", "nas"])

        let storedGroups = try await groups.fetchAll()
        XCTAssertEqual(Set(storedGroups.map(\.name)), ["Work", "Home"])

        let backend = try XCTUnwrap(stored.first { $0.label == "backend" })
        let work = try XCTUnwrap(storedGroups.first { $0.name == "Work" })
        XCTAssertEqual(backend.groupId, work.id)
        XCTAssertEqual(backend.portForwardings, "5432:localhost:5432")
    }

    /// Importing the same file twice must update, not duplicate.
    func testRestoreIsIdempotent() async throws {
        let archive = try BackupArchive.decode(Data(androidBackup.utf8))

        _ = try await service.restore(archive)
        let second = try await service.restore(archive)

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.updated, 3)
        let storedHosts = try await hosts.fetchAll()
        let storedGroups = try await groups.fetchAll()
        XCTAssertEqual(storedHosts.count, 3)
        XCTAssertEqual(storedGroups.count, 2)
    }

    /// Credentials are not in the file, so re-importing must never remove them.
    func testRestoreKeepsCredentialsAndHistory() async throws {
        _ = try await hosts.save(
            Host(
                label: "gateway",
                hostname: "gw.example.com",
                port: 2222,
                username: "admin",
                keyId: nil,
                password: "kept",
                encryptedPassword: "kept-encrypted",
                lastConnected: 1_700_000_000_000
            )
        )

        let archive = try BackupArchive.decode(Data(androidBackup.utf8))
        _ = try await service.restore(archive)

        let all = try await hosts.fetchAll()
        let reloaded = try XCTUnwrap(all.first { $0.label == "gateway" })
        XCTAssertEqual(reloaded.password, "kept")
        XCTAssertEqual(reloaded.encryptedPassword, "kept-encrypted")
        XCTAssertEqual(reloaded.lastConnected, 1_700_000_000_000)
    }

    /// A pinned key belongs to one endpoint. Same endpoint, keep it.
    func testPinnedHostKeySurvivesWhenTheEndpointIsUnchanged() async throws {
        _ = try await hosts.save(
            Host(
                label: "gateway",
                hostname: "gw.example.com",
                port: 2222,
                username: "admin",
                knownHostsEntry: "gw.example.com ssh-ed25519 PINNED"
            )
        )

        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        let all = try await hosts.fetchAll()
        let reloaded = try XCTUnwrap(all.first { $0.label == "gateway" })
        XCTAssertEqual(reloaded.knownHostsEntry, "gw.example.com ssh-ed25519 PINNED")
    }

    /// Different endpoint: the old pin would refuse every future connection to
    /// the new target, so it has to go rather than linger.
    func testPinnedHostKeyIsDroppedWhenTheImportRepointsTheHost() async throws {
        _ = try await hosts.save(
            Host(
                label: "gateway",
                hostname: "old.example.com",
                port: 22,
                username: "admin",
                knownHostsEntry: "old.example.com ssh-ed25519 STALE"
            )
        )

        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        let all = try await hosts.fetchAll()
        let reloaded = try XCTUnwrap(all.first { $0.label == "gateway" })
        XCTAssertEqual(reloaded.hostname, "gw.example.com")
        XCTAssertNil(reloaded.knownHostsEntry, "a stale pin was carried over to a new endpoint")
    }

    /// The hops' keys follow the chain that produced them.
    func testJumpHostKeysAreDroppedWhenTheChainChanges() async throws {
        _ = try await hosts.save(
            Host(
                label: "backend",
                hostname: "10.0.0.5",
                username: "deploy",
                jumpHosts: "someone.else:22",
                jumpHostKeys: "someone.else ssh-ed25519 STALE"
            )
        )

        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        let all = try await hosts.fetchAll()
        let reloaded = try XCTUnwrap(all.first { $0.label == "backend" })
        XCTAssertEqual(reloaded.jumpHosts, "gw.example.com:2222")
        XCTAssertNil(reloaded.jumpHostKeys)
    }

    func testJumpHostKeysSurviveAnUnchangedChain() async throws {
        _ = try await hosts.save(
            Host(
                label: "backend",
                hostname: "10.0.0.5",
                username: "deploy",
                jumpHosts: "gw.example.com:2222",
                jumpHostKeys: "gw.example.com ssh-ed25519 GOOD"
            )
        )

        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        let all = try await hosts.fetchAll()
        let reloaded = try XCTUnwrap(all.first { $0.label == "backend" })
        XCTAssertEqual(reloaded.jumpHostKeys, "gw.example.com ssh-ed25519 GOOD")
    }

    /// A host naming a group the file does not list still gets grouped.
    func testGroupNamedOnlyByAHostIsRecreated() async throws {
        let file = """
        { "version": 3, "hosts": [
            { "label": "a", "hostname": "a.example", "username": "u", "group": "Orphan" } ] }
        """

        _ = try await service.restore(try BackupArchive.decode(Data(file.utf8)))

        let fetchedGroup = try await groups.fetch(name: "Orphan")
        let allHosts = try await hosts.fetchAll()
        let group = try XCTUnwrap(fetchedGroup)
        let host = try XCTUnwrap(allHosts.first)
        XCTAssertEqual(host.groupId, group.id)
        XCTAssertEqual(group.color, HostGroup.swatches[0])
    }

    func testExistingGroupKeepsItsIdentityAndTakesTheNewColour() async throws {
        let existing = try await groups.save(HostGroup(name: "Work", color: HostGroup.swatches[3]))

        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        let fetched = try await groups.fetch(name: "Work")
        let reloaded = try XCTUnwrap(fetched)
        XCTAssertEqual(reloaded.id, existing.id, "the group was recreated instead of updated")
        XCTAssertEqual(reloaded.color, -1_499_549)
    }

    // MARK: - Settings

    func testSettingsRoundTripThroughPreferences() async throws {
        _ = try await service.restore(try BackupArchive.decode(Data(androidBackup.utf8)))

        XCTAssertTrue(preferences.confirmExit)
        XCTAssertEqual(preferences.lockTimeoutSeconds, 300)
        XCTAssertEqual(preferences.scrollbackLines, 5000)
        XCTAssertEqual(preferences.terminalFontSize, 16)
        XCTAssertEqual(preferences.nightMode, .dark)
        XCTAssertEqual(preferences.terminalColorScheme, .light)
        XCTAssertEqual(preferences.doubleTapAction, .tabTwice)
        XCTAssertFalse(preferences.historySuggestions)
        XCTAssertTrue(preferences.suggestionsBarSticky)
    }

    /// A hand-edited file must not be able to make the app unusable.
    func testAbsurdSettingsAreClamped() async throws {
        let file = """
        { "version": 3, "hosts": [],
          "settings": { "terminal_font_size": 400, "scrollback_lines": -5,
                        "lock_timeout_seconds": -10, "night_mode": 99 } }
        """

        _ = try await service.restore(try BackupArchive.decode(Data(file.utf8)))

        XCTAssertLessThanOrEqual(preferences.terminalFontSize, AppPreferences.Limits.maxTerminalFontSize)
        XCTAssertGreaterThanOrEqual(preferences.scrollbackLines, 1)
        XCTAssertGreaterThanOrEqual(preferences.lockTimeoutSeconds, 0)
        // An unknown enum value falls back rather than being stored as-is.
        XCTAssertEqual(preferences.nightMode, .followSystem)
    }

    /// Settings absent from the file leave the current ones alone.
    func testMissingSettingsAreNotOverwritten() async throws {
        preferences.terminalFontSize = 18

        let file = """
        { "version": 3, "hosts": [], "settings": { "confirm_exit": true } }
        """
        _ = try await service.restore(try BackupArchive.decode(Data(file.utf8)))

        XCTAssertEqual(preferences.terminalFontSize, 18)
        XCTAssertTrue(preferences.confirmExit)
    }
}
