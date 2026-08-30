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
            // This body has to depend on the session list, or nothing
            // re-evaluates it when a session opens and the terminal is never
            // pushed. The Binding's getter below cannot create that dependency:
            // a Binding getter is escaping and runs outside this scope. So the
            // read happens here, and only for that.
            //
            // What it must *not* be is the value the getter returns. That was
            // tried, on 30/08/2026, and it trapped the user in the terminal:
            // popping calls the setter, but SwiftUI then reads the getter of the
            // binding it already has, which was a constant frozen at the last
            // body pass and still said "presented" — so the pop was cancelled
            // and the terminal pushed itself straight back. Reported as "it goes
            // back into the terminal by itself, sometimes without touching
            // anything". The getter reads live state; this line only registers
            // the dependency.
            let _ = environment.sessions.selected

            NavigationStack {
                HostsScreen()
                    .navigationDestination(isPresented: Binding(
                        get: { environment.sessions.selected != nil },
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
