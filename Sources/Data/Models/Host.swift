// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// A saved SSH host.
///
/// Column names deliberately mirror the Android app's Room entity (`HostEntity`),
/// so the JSON backup format is shared between platforms without a translation
/// layer. Do not rename columns without updating the backup importer.
struct Host: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {

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
    var jumpMode: String = JumpMode.simple.rawValue

    /// Ordered comma-separated host IDs, used when ``jumpMode`` is `host_list`.
    var jumpHostIdList: String?

    /// `last` remembers the last visited path, `fixed` always uses
    /// ``sftpStartDir``, `home` always uses the server's home directory.
    var sftpStartMode: String = SFTPStartMode.last.rawValue

    var sftpStartDir: String?

    /// Appends legacy/weak algorithms to the negotiation list, for old servers.
    var allowLegacyCiphers: Bool = false

    /// `nil` means ungrouped.
    var groupId: Int64?

    /// Optional per-host ARGB colour overriding the group colour.
    /// Stored as ARGB (not a SwiftUI `Color`) to stay backup-compatible.
    var color: Int?

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
}
