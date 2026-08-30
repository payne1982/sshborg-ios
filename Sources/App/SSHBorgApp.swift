// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct SSHBorgApp: App {

    /// Built once for the process. The database and the open sessions have to
    /// outlive any individual view, and a scene can be rebuilt.
    @MainActor private static let environment = AppEnvironment.live()

    /// Watched here rather than in `RootView` because the cover has to go up
    /// before anything is drawn, and come down only once the gate says so.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(\.appEnvironment, Self.environment)

                if Self.environment.lock.isLocked {
                    LockScreen(
                        biometryName: BiometricLock.availability().displayName,
                        isAsking: isAsking,
                        onRetry: { Task { await Self.environment.lock.authenticate() } }
                    )
                    // No animation on the way in. A cover that fades is a cover
                    // that shows the host list for a few frames on the way out
                    // of the app, which is exactly what it exists to prevent.
                    .transition(.identity)
                }
            }
            .onValueChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    Task {
                        isAsking = true
                        await Self.environment.lock.didBecomeActive()
                        isAsking = false
                    }
                // `inactive` and not just `background`: iOS takes the app
                // switcher's snapshot on the way out, and by the time the phase
                // reaches `background` the picture has been taken.
                case .inactive, .background:
                    Self.environment.lock.willResignActive()
                @unknown default:
                    Self.environment.lock.willResignActive()
                }
            }
        }
    }

    /// True while the system's own prompt is on screen, so the cover does not
    /// put a second one behind it.
    @State private var isAsking = false
}
