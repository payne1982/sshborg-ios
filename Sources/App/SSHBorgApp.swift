// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
