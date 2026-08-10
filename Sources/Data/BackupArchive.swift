// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The backup file, in the format the Android app reads and writes.
///
/// This is the one place where the two platforms have to agree byte for byte,
/// because the point of it is moving a configuration between them: export from
/// SSHBorg on Android, import here, and every host is there. So the shape is not
/// designed, it is *matched* — field names, defaults and omissions all follow
/// `SettingsViewModel.exportHosts` in the Android source, and the tests check
/// against a file that app produced rather than against our own writer.
///
/// **A backup carries no credentials.** No password, no key, no pinned host
/// key, no last-connected time. That is deliberate on Android and kept here: the
/// file is meant to be moved between devices and mailed to oneself, and it can
/// be handled as ordinary configuration rather than as a secret.
///
/// Encoding is by hand rather than `Codable` because the format omits null
/// fields entirely instead of writing `null`, and `Codable` would need almost as
/// much custom code to do that as writing it out plainly.
struct BackupArchive: Equatable {

    /// Version 3 added `settings`; 2 added `groups`. Older files still load —
    /// their missing sections simply do not apply.
    static let currentVersion = 3

    var version: Int = currentVersion
    var exportedAt: String
    var groups: [Group] = []
    var hosts: [HostEntry] = []
    var settings: Settings?

    struct Group: Equatable {
        var name: String
        /// ARGB, matching ``HostGroup/swatches``.
        var color: Int
    }

    /// A host as the backup carries it: identity and behaviour, never secrets.
    struct HostEntry: Equatable {
        var label: String
        var hostname: String
        var port: Int = 22
        var username: String
        var agentForwarding: Bool = false
        var jumpMode: String = Host.JumpMode.simple.rawValue
        var sftpStartMode: String = Host.SFTPStartMode.last.rawValue
        var allowLegacyCiphers: Bool = false

        var jumpHosts: String?

        /// Exported for fidelity with Android, and of no use across devices: it
        /// holds local row IDs, which mean nothing in another installation. A
        /// host imported in `host_list` mode therefore arrives with a jump list
        /// that has to be re-picked. Carrying the field anyway means a backup
        /// round-tripped through this app is byte-identical to the Android one.
        var jumpHostIdList: String?

        var portForwardings: String?
        var sftpStartDir: String?

        /// Group *name*, not ID: names are what survive between installations.
        var group: String?

        /// Label of the SSH key this host uses, if any.
        ///
        /// The label rather than the row ID, for the same reason groups travel
        /// by name: an ID means nothing in another installation. The key itself
        /// is never exported — only which one to look for — so a backup still
        /// carries no secret. A host whose key is not present after import is
        /// simply left without one.
        var keyLabel: String?

        /// Per-host ARGB tint, or `nil` to inherit the group's.
        var color: Int?
    }

    /// The twelve preference keys the Android app exports, by its own names.
    struct Settings: Equatable {
        var confirmExit: Bool?
        var lockTimeoutSeconds: Int?
        var invertTerminalScroll: Bool?
        var nightMode: Int?
        var allowScreenshots: Bool?
        var scrollbackLines: Int?
        var terminalFontSize: Int?
        var keepScreenOn: Bool?
        var terminalColorScheme: Int?
        var historySuggestions: Bool?
        var suggestionsBarSticky: Bool?
        var doubleTapAction: Int?
        var extraKeysBarPinned: Bool?
    }

    enum DecodingFailure: LocalizedError, Equatable {
        case notJSON
        case missingHosts
        case malformedHost(index: Int)

        var errorDescription: String? {
            switch self {
            case .notJSON:
                return "That file is not a SSHBorg backup."
            case .missingHosts:
                return "The backup contains no host list."
            case .malformedHost(let index):
                return "Host number \(index + 1) in the backup is incomplete."
            }
        }
    }
}

// MARK: - Writing

extension BackupArchive {

    /// Android writes with `JSONObject.toString(2)`, so this uses the same
    /// two-space indentation. Nothing depends on it, but a file a user opens in
    /// an editor should look the same on both platforms.
    func jsonData() throws -> Data {
        var root: [String: Any] = [
            "version": version,
            "exported_at": exportedAt,
            "groups": groups.map { ["name": $0.name, "color": $0.color] },
            "hosts": hosts.map(Self.encode),
        ]
        if let settings {
            root["settings"] = Self.encode(settings)
        }

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func encode(_ host: HostEntry) -> [String: Any] {
        var object: [String: Any] = [
            "label": host.label,
            "hostname": host.hostname,
            "port": host.port,
            "username": host.username,
            "agentForwarding": host.agentForwarding,
            "jumpMode": host.jumpMode,
            "sftpStartMode": host.sftpStartMode,
            "allowLegacyCiphers": host.allowLegacyCiphers,
        ]

        // Absent rather than null, which is what the Android writer does: it
        // only puts these when the value is non-null.
        if let value = host.jumpHosts { object["jumpHosts"] = value }
        if let value = host.jumpHostIdList { object["jumpHostIdList"] = value }
        if let value = host.portForwardings { object["portForwardings"] = value }
        if let value = host.sftpStartDir { object["sftpStartDir"] = value }
        if let value = host.group { object["group"] = value }
        if let value = host.keyLabel { object["keyLabel"] = value }
        if let value = host.color { object["color"] = value }

        return object
    }

    private static func encode(_ settings: Settings) -> [String: Any] {
        var object: [String: Any] = [:]

        if let value = settings.confirmExit { object["confirm_exit"] = value }
        if let value = settings.lockTimeoutSeconds { object["lock_timeout_seconds"] = value }
        if let value = settings.invertTerminalScroll { object["invert_terminal_scroll"] = value }
        if let value = settings.nightMode { object["night_mode"] = value }
        if let value = settings.allowScreenshots { object["allow_screenshots"] = value }
        if let value = settings.scrollbackLines { object["scrollback_lines"] = value }
        if let value = settings.terminalFontSize { object["terminal_font_size"] = value }
        if let value = settings.keepScreenOn { object["keep_screen_on"] = value }
        if let value = settings.terminalColorScheme { object["terminal_color_scheme"] = value }
        if let value = settings.historySuggestions { object["history_suggestions"] = value }
        if let value = settings.suggestionsBarSticky { object["suggestions_bar_sticky"] = value }
        if let value = settings.doubleTapAction { object["double_tap_action"] = value }
        if let value = settings.extraKeysBarPinned { object["extra_keys_bar_pinned"] = value }

        return object
    }
}

// MARK: - Reading

extension BackupArchive {

    /// Parses a backup written by either platform.
    ///
    /// Tolerant on purpose, matching Android's use of `opt…` accessors: an
    /// unknown key is ignored, a missing optional falls back to its default, and
    /// only a host without the fields needed to connect is an error. A backup is
    /// something a user may have hand-edited, and refusing the whole file over
    /// one stray key would be the wrong trade.
    static func decode(_ data: Data) throws -> BackupArchive {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingFailure.notJSON
        }
        guard let rawHosts = root["hosts"] as? [[String: Any]] else {
            throw DecodingFailure.missingHosts
        }

        var archive = BackupArchive(
            version: root["version"] as? Int ?? 1,
            exportedAt: root["exported_at"] as? String ?? ""
        )

        archive.groups = (root["groups"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
            return Group(name: name, color: raw["color"] as? Int ?? HostGroup.swatches[0])
        }

        archive.hosts = try rawHosts.enumerated().map { index, raw in
            guard let label = raw["label"] as? String,
                  let hostname = raw["hostname"] as? String,
                  let username = raw["username"] as? String
            else { throw DecodingFailure.malformedHost(index: index) }

            return HostEntry(
                label: label,
                hostname: hostname,
                port: raw["port"] as? Int ?? 22,
                username: username,
                agentForwarding: raw["agentForwarding"] as? Bool ?? false,
                jumpMode: raw["jumpMode"] as? String ?? Host.JumpMode.simple.rawValue,
                sftpStartMode: raw["sftpStartMode"] as? String ?? Host.SFTPStartMode.last.rawValue,
                allowLegacyCiphers: raw["allowLegacyCiphers"] as? Bool ?? false,
                jumpHosts: nonEmpty(raw["jumpHosts"]),
                jumpHostIdList: nonEmpty(raw["jumpHostIdList"]),
                portForwardings: nonEmpty(raw["portForwardings"]),
                sftpStartDir: nonEmpty(raw["sftpStartDir"]),
                group: nonEmpty(raw["group"]),
                keyLabel: nonEmpty(raw["keyLabel"]),
                color: raw["color"] as? Int
            )
        }

        if let rawSettings = root["settings"] as? [String: Any] {
            archive.settings = Settings(
                confirmExit: rawSettings["confirm_exit"] as? Bool,
                lockTimeoutSeconds: rawSettings["lock_timeout_seconds"] as? Int,
                invertTerminalScroll: rawSettings["invert_terminal_scroll"] as? Bool,
                nightMode: rawSettings["night_mode"] as? Int,
                allowScreenshots: rawSettings["allow_screenshots"] as? Bool,
                scrollbackLines: rawSettings["scrollback_lines"] as? Int,
                terminalFontSize: rawSettings["terminal_font_size"] as? Int,
                keepScreenOn: rawSettings["keep_screen_on"] as? Bool,
                terminalColorScheme: rawSettings["terminal_color_scheme"] as? Int,
                historySuggestions: rawSettings["history_suggestions"] as? Bool,
                suggestionsBarSticky: rawSettings["suggestions_bar_sticky"] as? Bool,
                doubleTapAction: rawSettings["double_tap_action"] as? Int,
                extraKeysBarPinned: rawSettings["extra_keys_bar_pinned"] as? Bool
            )
        }

        return archive
    }

    /// An empty string means "not set" in the Android file, which writes `""`
    /// for a field it has nothing for rather than omitting it in every case.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
