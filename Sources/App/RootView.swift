// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The app shell: the host list, with the terminal pushed on top of it when a
/// session is open.
struct RootView: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            HostsScreen()
                .navigationDestination(isPresented: hasOpenSession) {
                    TerminalScreen(manager: environment.sessions)
                }
        }
        // iOS suspends an app about thirty seconds after it leaves the screen and
        // the connections die with it. Android holds them open with a foreground
        // service, which has no counterpart here, so the sessions are brought
        // back on the way in. This lives at the root because the terminal may not
        // be the visible screen when the app returns.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.sessions.reconnectAfterForeground() }
        }
    }

    /// Opening a session from anywhere in the list pushes the terminal, and
    /// closing the last one pops back. Driving navigation off the session list
    /// rather than off each button keeps those two in step.
    private var hasOpenSession: Binding<Bool> {
        Binding(
            get: { environment.sessions.selected != nil },
            set: { isShown in
                if !isShown { environment.sessions.selectedID = nil }
            }
        )
    }
}

#Preview {
    RootView()
        .environment(\.appEnvironment, .inMemory())
}
