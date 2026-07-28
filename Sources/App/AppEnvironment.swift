// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

/// The app's shared services, assembled once and handed down through the view
/// tree. The Android app reaches these off the `Application` object; on iOS the
/// SwiftUI environment is the equivalent seam, and it also makes previews and
/// tests able to substitute an in-memory database.
@MainActor
final class AppEnvironment {

    let database: AppDatabase
    let hosts: HostRepository
    let keys: SSHKeyRepository
    let groups: HostGroupRepository
    let preferences: AppPreferences
    let sessions: SessionManager

    init(database: AppDatabase, preferences: AppPreferences = AppPreferences()) {
        self.database = database
        self.hosts = HostRepository(database)
        self.keys = SSHKeyRepository(database)
        self.groups = HostGroupRepository(database)
        self.preferences = preferences
        self.sessions = SessionManager()
    }

    /// The real, on-disk environment.
    static func live() -> AppEnvironment {
        do {
            return AppEnvironment(database: try AppDatabase.makeShared())
        } catch {
            // A database we cannot open is not recoverable: every screen needs
            // it. Failing loudly here beats a silently empty host list.
            fatalError("Could not open the database: \(error)")
        }
    }

    /// An empty in-memory environment, for previews and tests.
    static func inMemory() -> AppEnvironment {
        AppEnvironment(
            database: try! AppDatabase.makeInMemory(),
            preferences: AppPreferences(
                defaults: UserDefaults(suiteName: "preview.\(UUID().uuidString)") ?? .standard
            )
        )
    }
}

private struct AppEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: AppEnvironment = .inMemory()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
