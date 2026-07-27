// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// Reads and writes ``Host`` records. Mirrors the Android `HostDao`.
///
/// The `observe*` methods are the equivalent of the DAO's `Flow` queries: they
/// emit the current value immediately and then again on every change.
struct HostRepository {

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func observeAll() -> AsyncValueObservation<[Host]> {
        ValueObservation
            .tracking { db in
                try Host.order(Host.Columns.label.asc).fetchAll(db)
            }
            .values(in: database.writer)
    }

    func fetchAll() async throws -> [Host] {
        try await database.writer.read { db in
            try Host.order(Host.Columns.label.asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> Host? {
        try await database.writer.read { db in
            try Host.fetchOne(db, key: id)
        }
    }

    /// Inserts or updates, returning the record with its assigned ID.
    @discardableResult
    func save(_ host: Host) async throws -> Host {
        try await database.writer.write { db in
            var host = host
            try host.save(db)
            return host
        }
    }

    func delete(_ host: Host) async throws {
        guard let id = host.id else { return }
        _ = try await database.writer.write { db in
            try Host.deleteOne(db, key: id)
        }
    }

    func updateLastConnected(id: Int64, to date: Date = Date()) async throws {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET lastConnected = ? WHERE id = ?",
                arguments: [milliseconds, id]
            )
        }
    }

    /// Persists the `known_hosts` line pinned on first connection.
    func updateKnownHostsEntry(id: Int64, to entry: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET knownHostsEntry = ? WHERE id = ?",
                arguments: [entry, id]
            )
        }
    }

    /// Detaches every host from a group, used before deleting the group itself.
    func clearGroup(groupId: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET groupId = NULL WHERE groupId = ?",
                arguments: [groupId]
            )
        }
    }
}
