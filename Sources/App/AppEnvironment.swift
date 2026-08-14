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

    /// Open file browsers, and the transfer queue they feed.
    ///
    /// Both live here rather than on the SFTP screen because both have to
    /// outlive it: a connection should survive the back chevron, and a download
    /// certainly should — it used to be cancelled by walking away from the
    /// screen that started it.
    let browsers: SFTPBrowsers
    let transfers: TransferManager

    /// Whether the app is showing its contents at all. The setting for this
    /// existed and did nothing until 14/08/2026 — the picker was stored, the
    /// timeout was stored, and nothing ever asked.
    let lock: AppLock

    init(database: AppDatabase, preferences: AppPreferences = AppPreferences()) {
        self.database = database
        self.hosts = HostRepository(database)
        self.keys = SSHKeyRepository(database)
        self.groups = HostGroupRepository(database)
        self.preferences = preferences
        self.sessions = SessionManager()
        self.browsers = SFTPBrowsers()
        self.transfers = TransferManager()
        self.lock = AppLock(preferences: preferences)
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
