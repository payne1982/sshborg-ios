// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// One connection: stamps the time and bumps the counter the "most used"
    /// order reads.
    ///
    /// Both in the same statement, as on Android. Two statements would leave a
    /// window where a host has been connected to but not counted, and the
    /// counter is the only record of a connection that is not the last one.
    func recordConnection(id: Int64, at date: Date = Date()) async throws {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET lastConnected = ?, connectCount = connectCount + 1 WHERE id = ?",
                arguments: [milliseconds, id]
            )
        }
    }

    /// Places a host in the manual list order. See ``HostSort``.
    func updatePosition(id: Int64, to position: Int) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET position = ? WHERE id = ?",
                arguments: [position, id]
            )
        }
    }

    /// Several placements in one transaction, so a reorder is all or nothing
    /// and the observation fires once rather than per row.
    func updatePositions(_ writes: [(id: Int64, position: Int)]) async throws {
        guard !writes.isEmpty else { return }
        try await database.writer.write { db in
            for write in writes {
                try db.execute(
                    sql: "UPDATE hosts SET position = ? WHERE id = ?",
                    arguments: [write.position, write.id]
                )
            }
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

    /// Persists the `known_hosts` lines of the hops, one per line.
    ///
    /// Only used in `simple` jump mode, where the hops are text on this record
    /// and have nowhere else to keep a key. In `host_list` mode each hop is a
    /// host of its own and ``updateKnownHostsEntry(id:to:)`` handles it there.
    func updateJumpHostKeys(id: Int64, to lines: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE hosts SET jumpHostKeys = ? WHERE id = ?",
                arguments: [lines, id]
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
