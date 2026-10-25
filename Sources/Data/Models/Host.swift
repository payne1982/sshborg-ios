// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// A saved SSH host.
///
/// Column names deliberately mirror the Android app's Room entity (`HostEntity`),
/// so the JSON backup format is shared between platforms without a translation
/// layer. Do not rename columns without updating the backup importer.
struct Host: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {

    static let databaseTableName = "hosts"

    var id: Int64?
    var label: String
    var hostname: String
    var port: Int = 22
    var username: String

    /// `nil` means password authentication; otherwise the ID of the key to use.
    var keyId: Int64?

    /// Plaintext password. Empty when `encryptedPassword` is set.
    var password: String?

    /// AES-GCM blob written by ``KeychainCrypto`` when encryption is enabled.
    var encryptedPassword: String?

    /// The `known_hosts` line for this host, pinned on first connection.
    /// SSHBorg stores host keys per-host rather than in one global file.
    var knownHostsEntry: String?

    var agentForwarding: Bool = false

    /// Milliseconds since the Unix epoch, matching the Android representation.
    var lastConnected: Int64?

    /// Comma-separated jump hosts, `"host1:port,host2:port"`. Used in `simple` mode.
    var jumpHosts: String?

    /// Newline-separated `known_hosts` lines for each jump host, one per hop.
    var jumpHostKeys: String?

    /// Newline-separated local forwarding rules in SSH `-L` syntax,
    /// `[bindAddr:]localPort:remoteHost:remotePort`.
    var portForwardings: String?

    /// `simple` uses ``jumpHosts``; `host_list` uses ``jumpHostIdList``.
    ///
    /// `host_list` is the default for a host created from now on, following
    /// Android: it is the mode that can carry credentials, because a hop picked
    /// from the host list brings its own key or password where one typed into
    /// the text field has none of its own. Nothing existing moves — the column
    /// has been written on every save since it appeared, so every host keeps
    /// what it was saved with, and a backup old enough not to carry the field
    /// is still read as `simple`, which is what it meant when the text string
    /// was the only mode there was.
    var jumpMode: String = JumpMode.hostList.rawValue

    /// Ordered comma-separated host IDs, used when ``jumpMode`` is `host_list`.
    var jumpHostIdList: String?

    /// `last` remembers the last visited path, `fixed` always uses
    /// ``sftpStartDir``, `home` always uses the server's home directory.
    var sftpStartMode: String = SFTPStartMode.last.rawValue

    var sftpStartDir: String?

    /// Shows dotfiles in the file browser. Off by default, as on Android, and
    /// display-only: a folder download still takes everything inside it.
    var sftpShowHidden: Bool = false

    /// Appends legacy/weak algorithms to the negotiation list, for old servers.
    var allowLegacyCiphers: Bool = false

    /// `nil` means ungrouped.
    var groupId: Int64?

    /// Optional per-host ARGB colour overriding the group colour.
    /// Stored as ARGB (not a SwiftUI `Color`) to stay backup-compatible.
    var color: Int?

    /// Place in the manual list order, scoped to the host's own section.
    ///
    /// `nil` means "not placed yet", and it stays that way until the manual
    /// order is actually chosen: seeding lazily is what keeps every path that
    /// inserts a host — the editor, a clone, a restored backup — free of any
    /// ordering logic at all.
    var position: Int?

    /// How many times this host has been connected to, for the "most used"
    /// order. Bumped by ``HostRepository/recordConnection(id:at:)``.
    var connectCount: Int = 0

    /// Whether the terminal for this host rides mosh instead of the SSH shell
    /// channel, on the platform where that exists.
    ///
    /// **Nothing in this app reads this or the three fields below.** Android
    /// gained mosh in its versionCode 39 and these are its per-host
    /// configuration; they are here because the backup format is shared, and a
    /// field this app drops is a field the user loses by passing a backup
    /// through it. Stored, exported, and not acted on — the plan for acting on
    /// it is in PIANO.md, 25/10/2026.
    var mosh: Bool = false

    /// Which address family a mosh session is made over: `auto`, `ipv4` or
    /// `ipv6`.
    ///
    /// It matters because a mosh session is bound to the family it was born on
    /// — `mosh-server -s` listens on the one address the SSH connection arrived
    /// on — so it can only follow a device between networks that both have it.
    /// A preference and not a demand: with no address of that family, the other
    /// is used.
    var moshFamily: String = "auto"

    /// The UDP port range `mosh-server` may choose from, as `60001-60999` or a
    /// single port. `nil` means mosh's own default, which is that whole range.
    var moshPorts: String?

    /// What to run on the server when `mosh-server` is not what a
    /// non-interactive shell finds on its PATH. `nil` means `mosh-server`.
    var moshCommand: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Host {

    enum JumpMode: String {
        case simple
        case hostList = "host_list"
    }

    enum SFTPStartMode: String {
        case last
        case fixed
        case home
    }

    enum Columns {
        static let id = Column("id")
        static let label = Column("label")
        static let groupId = Column("groupId")
        static let lastConnected = Column("lastConnected")
    }

    /// Parsed form of ``jumpMode``, falling back to `simple` on unknown values
    /// so a hand-edited backup cannot break the connection flow.
    var parsedJumpMode: JumpMode {
        JumpMode(rawValue: jumpMode) ?? .simple
    }

    var parsedSFTPStartMode: SFTPStartMode {
        SFTPStartMode(rawValue: sftpStartMode) ?? .last
    }

    var lastConnectedDate: Date? {
        lastConnected.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// The hops recorded in ``jumpHostIdList``, in order.
    ///
    /// Unparsable entries are dropped rather than failing: the field is a plain
    /// string in the shared backup format and can be hand-edited.
    var jumpHostIDs: [Int64] {
        Host.parseIDList(jumpHostIdList)
    }

    static func parseIDList(_ raw: String?) -> [Int64] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `nil` when there are no hops, which is how "not set" is stored.
    static func formatIDList(_ ids: [Int64]) -> String? {
        let usable = ids.filter { $0 != 0 }
        guard !usable.isEmpty else { return nil }
        return usable.map(String.init).joined(separator: ",")
    }

    /// Whether this host can serve as a hop for another one.
    ///
    /// A hop authenticates with nobody at the keyboard, so it needs a stored
    /// credential. Android greys out the others in the picker for the same
    /// reason.
    var canBeJumpHost: Bool {
        if keyId != nil { return true }
        if let encryptedPassword, !encryptedPassword.isEmpty { return true }
        if let password, !password.isEmpty { return true }
        return false
    }
}
