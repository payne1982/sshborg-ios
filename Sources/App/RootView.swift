// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The app shell: the host list, with the terminal pushed on top of it when a
/// session is open.
struct RootView: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase

    /// Whether the terminal is on the navigation stack.
    ///
    /// Plain `@State`, and not a `Binding` derived from the session list. Both
    /// halves of that were learned the hard way on 30/08/2026.
    ///
    /// A Binding's getter is escaping: it runs outside the tracking scope, so it
    /// registers no dependency and the device reports it. Making the getter
    /// return a value captured in the body fixed that and broke something worse
    /// — popping calls the setter, but SwiftUI then reads the getter of the
    /// binding it already holds, frozen at the previous body pass and still
    /// saying "presented". The pop was cancelled and the terminal pushed itself
    /// straight back, sometimes with no touch at all.
    ///
    /// A plain Bool has no getter to run at the wrong moment. The session list
    /// is read below, inside the tracking scope, and moves this in step.
    @State private var showsTerminal = false

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                HostsScreen()
                    .navigationDestination(isPresented: $showsTerminal) {
                        TerminalScreen(manager: environment.sessions)
                    }
            }
            // The session list is read here, inside the tracking scope, so
            // opening or closing one re-evaluates this body and moves the plain
            // Bool the stack watches. `initial` so a session already open when
            // the view appears is on screen rather than one gesture away.
            .onValueChange(of: environment.sessions.selected?.id, initial: true) { id in
                showsTerminal = id != nil
            }
            // And the way back: the chevron and the swipe both clear the Bool,
            // which is what closes the session rather than leaving it selected
            // behind a screen nobody is looking at.
            .onValueChange(of: showsTerminal) { shown in
                if !shown { environment.sessions.selectedID = nil }
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
