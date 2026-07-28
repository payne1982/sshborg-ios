// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct SSHBorgApp: App {

    /// Built once for the process. The database and the open sessions have to
    /// outlive any individual view, and a scene can be rebuilt.
    @MainActor private static let environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appEnvironment, Self.environment)
        }
    }
}
