// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The app shell: the host list, with the terminal pushed on top of it when a
/// session is open.
struct RootView: View {

    @Environment(\.appEnvironment) private var environment

    var body: some View {
        NavigationStack {
            HostsScreen()
                .navigationDestination(isPresented: hasOpenSession) {
                    TerminalScreen(manager: environment.sessions)
                }
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
