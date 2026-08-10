// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads and writes ``BackupArchive`` against the app's own storage.
///
/// The interesting half is importing. Exporting is a copy; importing has to
/// merge a file into a database that already has hosts in it, and the rules for
/// that are the ones the Android app settled on — reproduced here because a user
/// moving between platforms should get the same outcome, and because each rule
/// exists to avoid a specific way of losing something.
struct BackupService {

    let hosts: HostRepository
    let groups: HostGroupRepository
    let keys: SSHKeyRepository
    let preferences: AppPreferences

    init(
        hosts: HostRepository,
        groups: HostGroupRepository,
        keys: SSHKeyRepository,
        preferences: AppPreferences
    ) {
        self.hosts = hosts
        self.groups = groups
        self.keys = keys
        self.preferences = preferences
    }

    /// What an import did, for the message shown afterwards.
    struct ImportResult: Equatable {
        var inserted = 0
        var updated = 0
    }

    // MARK: - Export

    func export(now: Date = Date()) async throws -> BackupArchive {
        let allGroups = try await groups.fetchAll()
        let allHosts = try await hosts.fetchAll()
        let allKeys = try await keys.fetchAll()

        // The key's *label*, never its material: a backup says which key to look
        // for, and the receiving installation resolves it among its own.
        let keyLabelByID = Dictionary(
            uniqueKeysWithValues: allKeys.compactMap { key in key.id.map { ($0, key.label) } }
        )

        let groupNameByID = Dictionary(
            uniqueKeysWithValues: allGroups.compactMap { group in
                group.id.map { ($0, group.name) }
            }
        )

        return BackupArchive(
            exportedAt: Self.timestampFormatter.string(from: now),
            groups: allGroups.map { BackupArchive.Group(name: $0.name, color: $0.color) },
            hosts: allHosts.map { host in
                BackupArchive.HostEntry(
                    label: host.label,
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    agentForwarding: host.agentForwarding,
                    jumpMode: host.jumpMode,
                    sftpStartMode: host.sftpStartMode,
                    allowLegacyCiphers: host.allowLegacyCiphers,
                    jumpHosts: host.jumpHosts,
                    jumpHostIdList: host.jumpHostIdList,
                    portForwardings: host.portForwardings,
                    sftpStartDir: host.sftpStartDir,
                    group: host.groupId.flatMap { groupNameByID[$0] },
                    keyLabel: host.keyId.flatMap { keyLabelByID[$0] },
                    color: host.color
                )
            },
            settings: currentSettings()
        )
    }

    /// `java.time.Instant.toString()`, which is what the Android file carries.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private func currentSettings() -> BackupArchive.Settings {
        BackupArchive.Settings(
            confirmExit: preferences.confirmExit,
            lockTimeoutSeconds: preferences.lockTimeoutSeconds,
            invertTerminalScroll: preferences.invertTerminalScroll,
            nightMode: preferences.nightMode.rawValue,
            allowScreenshots: preferences.allowScreenshots,
            scrollbackLines: preferences.scrollbackLines,
            terminalFontSize: preferences.terminalFontSize,
            keepScreenOn: preferences.keepScreenOn,
            terminalColorScheme: preferences.terminalColorScheme.rawValue,
            historySuggestions: preferences.historySuggestions,
            suggestionsBarSticky: preferences.suggestionsBarSticky,
            doubleTapAction: preferences.doubleTapAction.rawValue,
            extraKeysBarPinned: preferences.extraKeysBarPinned
        )
    }

    // MARK: - Import

    @discardableResult
    func restore(_ archive: BackupArchive) async throws -> ImportResult {
        var groupIDByName = try await upsertGroups(archive.groups)
        var result = ImportResult()

        let existingByLabel = Dictionary(
            try await hosts.fetchAll().map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Keys are matched by label, like groups: the backup names the key it
        // wants and this installation supplies its own. A label with no local
        // key resolves to nothing and the host arrives without one.
        let keyIDByLabel = Dictionary(
            try await keys.fetchAll().compactMap { key in key.id.map { (key.label, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        for entry in archive.hosts {
            let groupID = try await resolveGroupID(named: entry.group, cache: &groupIDByName)
            var host = Self.host(
                from: entry,
                groupID: groupID,
                keyID: entry.keyLabel.flatMap { keyIDByLabel[$0] }
            )

            if let existing = existingByLabel[entry.label] {
                host = Self.merge(imported: host, into: existing)
                result.updated += 1
            } else {
                result.inserted += 1
            }

            _ = try await hosts.save(host)
        }

        if let settings = archive.settings {
            apply(settings)
        }

        return result
    }

    /// Groups are matched by name and their colour is refreshed. Matching by
    /// name rather than ID is what makes a backup portable at all: row IDs are
    /// local to an installation and mean nothing in another one.
    private func upsertGroups(_ entries: [BackupArchive.Group]) async throws -> [String: Int64] {
        var idsByName: [String: Int64] = [:]

        for entry in entries {
            if var existing = try await groups.fetch(name: entry.name) {
                existing.color = entry.color
                let saved = try await groups.save(existing)
                idsByName[entry.name] = saved.id
            } else {
                let saved = try await groups.save(HostGroup(name: entry.name, color: entry.color))
                idsByName[entry.name] = saved.id
            }
        }

        return idsByName
    }

    /// A host may name a group the backup's own group list does not contain, in
    /// files written before groups were exported at all. Recreating it is better
    /// than dropping the host's grouping silently.
    private func resolveGroupID(
        named name: String?,
        cache: inout [String: Int64]
    ) async throws -> Int64? {
        guard let name, !name.isEmpty else { return nil }
        if let known = cache[name] { return known }

        if let existing = try await groups.fetch(name: name) {
            cache[name] = existing.id
            return existing.id
        }

        let created = try await groups.save(
            HostGroup(name: name, color: HostGroup.swatches[0])
        )
        cache[name] = created.id
        return created.id
    }

    private static func host(
        from entry: BackupArchive.HostEntry,
        groupID: Int64?,
        keyID: Int64?
    ) -> Host {
        Host(
            label: entry.label,
            hostname: entry.hostname,
            port: entry.port,
            username: entry.username,
            keyId: keyID,
            agentForwarding: entry.agentForwarding,
            jumpHosts: entry.jumpHosts,
            portForwardings: entry.portForwardings,
            jumpMode: entry.jumpMode,
            jumpHostIdList: entry.jumpHostIdList,
            sftpStartMode: entry.sftpStartMode,
            sftpStartDir: entry.sftpStartDir,
            allowLegacyCiphers: entry.allowLegacyCiphers,
            groupId: groupID,
            color: entry.color
        )
    }

    /// Folds an imported host onto one that already exists under the same label.
    ///
    /// Two different things are being protected here.
    ///
    /// Credentials and history are simply not in the file, so they are always
    /// kept: re-importing a backup must not log the user out of a host.
    ///
    /// Pinned host keys are subtler. A stored key is a trust-on-first-use anchor
    /// bound to one endpoint, so it may only survive while that endpoint is
    /// unchanged. If the import repoints the host, the old pin is not merely
    /// stale but harmful — it would refuse every future connection to the new
    /// target — so it is dropped and the key is verified again on next connect.
    /// The same reasoning applies to the hops' keys, which are tied to the
    /// `jumpHosts` string that produced them.
    private static func merge(imported: Host, into existing: Host) -> Host {
        var host = imported
        host.id = existing.id

        // A host that already has a key keeps it; one that has none adopts what
        // the backup named. Overwriting would silently repoint a working host at
        // a different key, which is the kind of change nobody notices until a
        // connection stops authenticating.
        host.keyId = existing.keyId ?? imported.keyId
        host.password = existing.password
        host.encryptedPassword = existing.encryptedPassword
        host.lastConnected = existing.lastConnected

        let sameEndpoint = existing.hostname == imported.hostname && existing.port == imported.port
        host.knownHostsEntry = sameEndpoint ? existing.knownHostsEntry : nil

        let sameChain = imported.jumpMode == Host.JumpMode.simple.rawValue
            && existing.jumpHosts == imported.jumpHosts
        host.jumpHostKeys = sameChain ? existing.jumpHostKeys : nil

        return host
    }

    /// Missing keys are left alone, and bounded values are clamped by the
    /// setters themselves — a backup can be hand-edited, and a font size of
    /// 400 should not be able to make the terminal unusable.
    private func apply(_ settings: BackupArchive.Settings) {
        if let value = settings.confirmExit { preferences.confirmExit = value }
        if let value = settings.lockTimeoutSeconds { preferences.lockTimeoutSeconds = max(0, value) }
        if let value = settings.invertTerminalScroll { preferences.invertTerminalScroll = value }
        if let value = settings.nightMode {
            preferences.nightMode = AppPreferences.NightMode(rawValue: value) ?? .followSystem
        }
        if let value = settings.allowScreenshots { preferences.allowScreenshots = value }
        if let value = settings.scrollbackLines { preferences.scrollbackLines = value }
        if let value = settings.terminalFontSize { preferences.terminalFontSize = value }
        if let value = settings.keepScreenOn { preferences.keepScreenOn = value }
        if let value = settings.terminalColorScheme {
            preferences.terminalColorScheme = AppPreferences.TerminalColorScheme(rawValue: value) ?? .dark
        }
        if let value = settings.historySuggestions { preferences.historySuggestions = value }
        if let value = settings.suggestionsBarSticky { preferences.suggestionsBarSticky = value }
        if let value = settings.doubleTapAction {
            preferences.doubleTapAction = AppPreferences.DoubleTapAction(rawValue: value) ?? .none
        }
        if let value = settings.extraKeysBarPinned { preferences.extraKeysBarPinned = value }
    }
}
