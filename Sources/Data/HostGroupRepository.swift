// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// Reads and writes ``HostGroup`` records. Mirrors the Android `GroupDao`.
struct HostGroupRepository {

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func observeAll() -> AsyncValueObservation<[HostGroup]> {
        ValueObservation
            .tracking { db in
                try HostGroup.order(HostGroup.Columns.name.asc).fetchAll(db)
            }
            .values(in: database.writer)
    }

    func fetchAll() async throws -> [HostGroup] {
        try await database.writer.read { db in
            try HostGroup.order(HostGroup.Columns.name.asc).fetchAll(db)
        }
    }

    /// Used by the backup importer to merge into an existing group rather than
    /// creating a duplicate with the same name.
    func fetch(name: String) async throws -> HostGroup? {
        try await database.writer.read { db in
            try HostGroup.filter(HostGroup.Columns.name == name).fetchOne(db)
        }
    }

    @discardableResult
    func save(_ group: HostGroup) async throws -> HostGroup {
        try await database.writer.write { db in
            var group = group
            try group.save(db)
            return group
        }
    }

    /// Deletes the group and detaches its hosts in a single transaction, so a
    /// failure cannot leave hosts pointing at a group that no longer exists.
    func delete(_ group: HostGroup) async throws {
        guard let id = group.id else { return }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE hosts SET groupId = NULL WHERE groupId = ?", arguments: [id])
            _ = try HostGroup.deleteOne(db, key: id)
        }
    }

    func setCollapsed(id: Int64, _ collapsed: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE host_groups SET collapsed = ? WHERE id = ?",
                arguments: [collapsed, id]
            )
        }
    }
}
