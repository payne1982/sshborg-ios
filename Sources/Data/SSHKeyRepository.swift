// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import GRDB

/// Reads and writes ``SSHKey`` records. Mirrors the Android `SshKeyDao`.
struct SSHKeyRepository {

    let database: AppDatabase

    init(_ database: AppDatabase) {
        self.database = database
    }

    func observeAll() -> AsyncValueObservation<[SSHKey]> {
        ValueObservation
            .tracking { db in
                try SSHKey.order(SSHKey.Columns.label.asc).fetchAll(db)
            }
            .values(in: database.writer)
    }

    func fetchAll() async throws -> [SSHKey] {
        try await database.writer.read { db in
            try SSHKey.order(SSHKey.Columns.label.asc).fetchAll(db)
        }
    }

    func fetch(id: Int64) async throws -> SSHKey? {
        try await database.writer.read { db in
            try SSHKey.fetchOne(db, key: id)
        }
    }

    @discardableResult
    func save(_ key: SSHKey) async throws -> SSHKey {
        try await database.writer.write { db in
            var key = key
            try key.save(db)
            return key
        }
    }

    /// Deletes the key. Hosts referencing it keep working: the foreign key is
    /// declared `ON DELETE SET NULL`, so they silently fall back to password auth.
    func delete(_ key: SSHKey) async throws {
        guard let id = key.id else { return }
        _ = try await database.writer.write { db in
            try SSHKey.deleteOne(db, key: id)
        }
    }

    /// Number of hosts currently configured to use this key, so the UI can warn
    /// before deletion instead of silently breaking those hosts.
    func hostCount(usingKeyId keyId: Int64) async throws -> Int {
        try await database.writer.read { db in
            try Host.filter(Column("keyId") == keyId).fetchCount(db)
        }
    }
}
