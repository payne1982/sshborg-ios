// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The app shell: the host list, with the terminal pushed on top of it when a
/// session is open.
struct RootView: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WithPerceptionTracking {
            // Read here rather than inside the Binding below: a Binding's
            // getter is escaping and runs outside this tracking scope, so on
            // iOS 16 opening a session would not have pushed the terminal.
            let hasOpenSession = environment.sessions.selected != nil
            NavigationStack {
                HostsScreen()
                    .navigationDestination(isPresented: Binding(
                        get: { hasOpenSession },
                        set: { isShown in
                            if !isShown { environment.sessions.selectedID = nil }
                        }
                    )) {
                        TerminalScreen(manager: environment.sessions)
                    }
            }
            // iOS suspends an app about thirty seconds after it leaves the screen and
            // the connections die with it. Android holds them open with a foreground
            // service, which has no counterpart here, so the sessions are brought
            // back on the way in. This lives at the root because the terminal may not
            // be the visible screen when the app returns.
            .onValueChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await environment.sessions.reconnectAfterForeground() }
            }
            .startupNotices(preferences: environment.preferences, lock: environment.lock)
        }
    }
}

#Preview {
    RootView()
        .environment(\.appEnvironment, .inMemory())
}
