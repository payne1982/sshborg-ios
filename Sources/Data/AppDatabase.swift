// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Owns the SQLite connection and the schema.
///
/// The schema is the Android app's Room schema, created in one step at its
/// version 11. The eleven incremental Room migrations before that are
/// deliberately not replayed: no iOS device has ever held an older version, and
/// hosts move between platforms through the JSON backup, never by copying the
/// database file.
///
/// Everything Android adds *after* 11 gets a migration of its own here, even
/// though the app has not shipped yet. Folding a new column into `v1` instead
/// would be tidier to read and would wipe every test device: GRDB's
/// `eraseDatabaseOnSchemaChange` fires when a registered migration changes, and
/// the hosts someone has been testing with all week are worth more than a tidy
/// schema.
final class AppDatabase: Sendable {

    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// Opens the on-disk database in Application Support.
    static func makeShared() throws -> AppDatabase {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true

        var databaseURL = folder.appendingPathComponent("sshborg.sqlite")
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        // Host and key material must never end up in an iCloud or iTunes backup
        // in a form we do not control. The JSON export is the supported path.
        // Set after the file exists, otherwise the flag has nothing to attach to.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? databaseURL.setResourceValues(values)

        return try AppDatabase(queue)
    }

    /// An empty in-memory database, for tests and SwiftUI previews.
    static func makeInMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(try DatabaseQueue(configuration: configuration))
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Recreate the schema from scratch whenever a migration is edited during
        // development, instead of silently running against a stale database.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "host_groups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .integer).notNull()
                t.column("collapsed", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "ssh_keys") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("keyType", .text).notNull()
                t.column("privateKeyPem", .text).notNull().defaults(to: "")
                t.column("publicKey", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("encryptedBlob", .text)
            }

            try db.create(table: "hosts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("label", .text).notNull()
                t.column("hostname", .text).notNull()
                t.column("port", .integer).notNull().defaults(to: 22)
                t.column("username", .text).notNull()
                // Deleting a key must not delete the hosts using it: the host
                // falls back to password auth and the user is told to re-select.
                t.column("keyId", .integer).references("ssh_keys", onDelete: .setNull)
                t.column("password", .text)
                t.column("encryptedPassword", .text)
                t.column("knownHostsEntry", .text)
                t.column("agentForwarding", .boolean).notNull().defaults(to: false)
                t.column("lastConnected", .integer)
                t.column("jumpHosts", .text)
                t.column("jumpHostKeys", .text)
                t.column("portForwardings", .text)
                t.column("jumpMode", .text).notNull().defaults(to: "simple")
                t.column("jumpHostIdList", .text)
                t.column("sftpStartMode", .text).notNull().defaults(to: "last")
                t.column("sftpStartDir", .text)
                t.column("allowLegacyCiphers", .boolean).notNull().defaults(to: false)
                t.column("groupId", .integer).references("host_groups", onDelete: .setNull)
                t.column("color", .integer)
            }

            try db.create(index: "index_hosts_groupId", on: "hosts", columns: ["groupId"])
        }

        // Android's Room migration 11 -> 12.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "hosts") { t in
                t.add(column: "sftpShowHidden", .boolean).notNull().defaults(to: false)
            }
        }

        // Android's Room migration 12 -> 13: the host list order (#16).
        //
        // Both positions are nullable on purpose — "no manual place yet" is a
        // state, not a zero — while the counter is not: a host that has never
        // been connected to has been connected to nought times.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "hosts") { t in
                t.add(column: "position", .integer)
                t.add(column: "connectCount", .integer).notNull().defaults(to: 0)
            }
            try db.alter(table: "host_groups") { t in
                t.add(column: "position", .integer)
            }
        }

        return migrator
    }
}
