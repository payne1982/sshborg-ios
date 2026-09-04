// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

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
            // The audit that wrapped every view body missed this one, because it
            // looked for `some View` and this is `some Scene`. The lock cover is
            // decided here — `lock.isLocked` is read on every evaluation of this
            // closure — so without the wrapper it is both a runtime warning on
            // every pass and, on iOS 16, a cover that would never come down.
            WithPerceptionTracking {
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
                // `nightMode`, which until 04/09/2026 was the *other* setting
                // wired to nothing: offered in Settings, stored, carried in
                // backups, read by no one. On Android it picks between two
                // hand-written Material palettes; here the system colours
                // already follow the appearance, so choosing the appearance is
                // the whole implementation.
                //
                // On the ZStack rather than on RootView so the lock cover
                // follows it too, and above `RootView` so that everything below
                // — including the terminal's "follow app" — reads the resolved
                // appearance from `\.colorScheme` rather than resolving it
                // again.
                .preferredColorScheme(Self.environment.preferences.nightMode.colorScheme)
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
    }

    /// True while the system's own prompt is on screen, so the cover does not
    /// put a second one behind it.
    @State private var isAsking = false
}

extension AppPreferences.NightMode {

    /// What to hand `preferredColorScheme`. Nil is "leave it to the system",
    /// which is the whole of `followSystem`.
    ///
    /// Here and not beside the enum so that `Sources/Data` does not have to
    /// import SwiftUI for it, the same split as `TerminalColorScheme` and
    /// `TerminalPalette`.
    var colorScheme: ColorScheme? {
        switch self {
        case .followSystem: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
