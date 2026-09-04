// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The terminal itself: tab strip, the live view, the extra key row, and the
/// prompts the connection can raise.
///
/// Ported from the Android `TerminalScreen`. The command-history suggestion bar
/// is not here yet: it reads the shell history off the server over SFTP, so it
/// arrives with phase 6.
struct TerminalScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Perception.Bindable var manager: SessionManager

    @State private var passwordInput = ""
    @State private var keyboard = KeyboardVisibility()
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if let session = manager.selected {
                    terminal(for: session)
                } else {
                    EmptyStateView(
                        String(localized: .iosTerminalNoSessions),
                        systemImage: "terminal",
                        description: Text(.iosTerminalNoSessionsHint)
                    )
                }
            }
            .navigationTitle(manager.selected?.title ?? String(localized: .terminalTitleDefault))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let session = manager.selected {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(String(localized: .actionClose), systemImage: "xmark.circle") {
                            manager.close(session)
                        }
                    }
                }
            }
        }
    }

    /// Height of the margin below the terminal. See its use site.
    ///
    /// 16, measured by trying: 10 was tried on the phone and the top of the keys
    /// went dead again, so the strip the terminal takes is wider than the ~11
    /// points the key geometry suggested. 16 is the value that worked, twice.
    private static let terminalTouchMargin: CGFloat = 16

    /// What the terminal's backing is actually painted, which the margin has to
    /// match to be invisible.
    ///
    /// ⚠️ Hardcoded, and it should not have to be. `TerminalHostView` paints its
    /// container black by hand because SwiftTerm's `nativeBackgroundColor` is
    /// only ever what someone assigned to it, and nothing here assigns it — so
    /// it reports the library default, white, which is exactly what this margin
    /// came out as when it followed that property.
    ///
    /// The reason nothing assigns it is worth its own note: the
    /// `terminalColorScheme` preference is offered in Settings and carried in
    /// backups, and **no code reads it to colour anything**. Until that is
    /// wired up there is only one terminal appearance, and this matches it.
    private static let terminalBackground = Color.black

    @ViewBuilder
    private func terminal(for session: TerminalSession) -> some View {
        ZStack {
            TerminalHostView(session: session, fontSize: environment.preferences.terminalFontSize)
                // No `ignoresSafeArea(.container, edges: .bottom)` here, though
                // there was from the first terminal commit until 03/09/2026.
                //
                // `safeAreaInset` below puts the bars into the container's
                // bottom safe area, and ignoring that safe area made the
                // terminal draw *underneath* them. Measured on the device: with
                // the keyboard up the window is 812, the bars 88, the keyboard
                // 291 and the terminal 433 — which is 812 exactly, leaving the
                // bars no room of their own. So the last rows were covered, and
                // the count grew with the number of bars: two under the extra
                // key row, three once the suggestion bar joined it. The cursor
                // row was among them.
                //
                // It cost touches too. SwiftTerm's own gesture recognisers were
                // live across that overlap, competing with the buttons drawn on
                // top of it.
                //
                // What it was there for — the terminal's black reaching the
                // bottom edge instead of stopping above the home indicator — is
                // now done by the bars' own background, which is where it
                // belongs.
                //
                // Deliberately *not* keyed on the session id: the view swaps the
                // terminal itself and carries the keyboard focus across. Keying
                // it here would make each switch a teardown, and the keyboard
                // would drop every time. See TerminalHostView.

            overlay(for: session)
        }
        // Every bar lives in the bottom inset, tabs closest to the terminal —
        // the Android order, and the reason is the thumb: the tab strip is the
        // control reached for most often while typing, and at the top of a phone
        // it is the hardest place to reach. The numbered picker opens upward,
        // away from the strip, so it never covers the tab that spawned it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The pin's binding used to be built by hand, and its getter read
            // the preference from inside an escaping closure — outside the
            // tracking scope, which the device reported four times.
            // @Perception.Bindable is what the warning itself recommends: a
            // projected binding that carries the tracking with it. It is
            // declared here, where it is used, because a local property wrapper
            // is visible only in its own scope.
            @Perception.Bindable var preferences = environment.preferences

            VStack(spacing: 0) {
                // A margin between the terminal and everything below it, in the
                // terminal's own colour so it reads as part of the terminal
                // rather than as a seam.
                //
                // Whatever sits directly under the terminal loses its top few
                // points — the key bar when it is closest, the suggestion bar
                // when that is. It follows the boundary and not the control,
                // which is what ruled the buttons out: "I can only click the
                // suggestions in their lower part". The frames do not overlap
                // (terminal ends at 485, bar starts at 485, measured on the
                // device), so this is gesture arbitration, and no `contentShape`
                // on a button reaches it.
                //
                // It has to be *here*, outside the terminal's representable.
                // Two earlier attempts put it inside — first refusing touches
                // along the container's bottom edge, then insetting the terminal
                // within its own container — and neither changed anything: the
                // boundary that matters is the one SwiftUI lays out, not the one
                // inside. "The bar must be outside the terminal", as he put it.
                //
                // `allowsHitTesting(false)`: nothing here is meant to be
                // pressable. It is a sacrificial margin, and it costs a row.
                Self.terminalBackground
                    .frame(height: Self.terminalTouchMargin)
                    .allowsHitTesting(false)


                // Not gated on the phase: switching away from a session that
                // failed is exactly when the tabs are needed most.
                if manager.sessions.count > 1 {
                    Divider()
                    SessionTabRow(manager: manager)
                }

                if session.phase == .connected {
                    ForwardingNotice(statuses: session.forwardingStatus)
                    SuggestionBar(
                        suggestions: session.suggestions,
                        isSticky: environment.preferences.suggestionsBarSticky
                    ) { command in
                        session.apply(suggestion: command)
                    }
                    // With the keyboard, or without it when pinned. Showing it
                    // unconditionally — which is what happened before — left the
                    // pin controlling nothing at all.
                    //
                    // Read into a constant first, because `||` short-circuits.
                    // Written inline after `keyboard.isVisible`, the preference
                    // was never read while the keyboard was up — which is
                    // exactly when the pin is pressed — so no dependency on it
                    // was ever registered, nothing re-rendered, and the pin's
                    // own icon never changed. The value did change underneath;
                    // nobody was watching. Reported from the device on
                    // 03/09/2026 as "it is as if the button were not a button".
                    let isPinned = environment.preferences.extraKeysBarPinned
                    if keyboard.isVisible || isPinned {
                        ExtraKeyRow(
                            session: session,
                            isPinned: $preferences.extraKeysBarPinned
                        )
                    }
                }
            }
        }
        .task(id: session.id) {
            // Only drive the first connection; a reconnect is user-initiated.
            if session.phase == .connecting {
                await session.connect()
            }
        }
        .task(id: session.phase == .connected) {
            // History comes over its own SFTP connection, so it can only be
            // fetched once the credentials are known to work.
            guard session.phase == .connected else { return }
            await session.loadHistory(preferences: environment.preferences)
        }
    }

    @ViewBuilder
    private func overlay(for session: TerminalSession) -> some View {
        switch session.phase {
        case .connecting:
            StatusOverlay(
                kind: .working,
                message: String(localized: .iosTerminalConnecting)
                    .replacingOccurrences(of: "%1$@", with: session.host.hostname),
                actions: AnyView(EmptyView())
            )

        case .failed(let message):
            // The headline stays short and the server's own words go in the
            // detail: "Connection failed" is what the user needs first, and
            // "Unable to exchange encryption keys" is what they need to paste
            // into a search or a message to whoever runs the server.
            StatusOverlay(
                kind: .failure,
                message: String(localized: .terminalConnectionFailed),
                detail: message,
                actions: AnyView(
                    HStack {
                        Button(String(localized: .iosActionRetry)) { Task { await session.connect() } }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: .actionClose)) { manager.close(session) }
                    }
                )
            )

        case .disconnected(let reason):
            StatusOverlay(
                kind: .ended,
                message: String(localized: .terminalDisconnected),
                detail: reason,
                actions: AnyView(
                    HStack {
                        Button(String(localized: .iosActionReconnect)) { Task { await session.connect() } }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: .actionClose)) { manager.close(session) }
                    }
                )
            )

        case .needsHostKeyApproval(let info, let isChange):
            // In the layout, not a system alert.
            //
            // As an alert it sat over an empty black terminal, and someone who
            // did not notice it — or brushed it away — was left staring at that
            // black screen with nothing saying what it waited for. It cost an
            // hour of misdiagnosis during testing, which is a fair warning about
            // what it costs a user.
            //
            // ⚠️ An earlier version of this comment claimed Android does the
            // same for the same reason. It does not: `HostKeyDialog` there is a
            // plain `AlertDialog`, as is its password prompt, in the terminal as
            // well as in the file browser. This is a deliberate divergence, and
            // the measurements behind it are in `ConnectionPrompt`.
            ConnectionPrompt.hostKey(
                info,
                hostname: session.host.hostname,
                isChange: isChange,
                onTrust: { Task { await session.connect(acceptHostKey: true) } },
                onReject: { manager.close(session) }
            )

        case .needsPassword:
            // Same panel as the host key prompt above, for the reasons and the
            // pixel measurements recorded in `ConnectionPrompt`.
            ConnectionPrompt.password(
                for: session.host.username,
                at: session.host.hostname,
                text: $passwordInput,
                isFocused: $isPasswordFocused,
                onConnect: { submitPassword(for: session) },
                onCancel: { manager.close(session) }
            )

        case .connected:
            EmptyView()
        }
    }


    // MARK: - Prompts

    /// Hands the password to the session and forgets it here.
    private func submitPassword(for session: TerminalSession) {
        let password = passwordInput
        passwordInput = ""
        isPasswordFocused = false
        Task { await session.connect(password: password) }
    }

}

private struct SessionTabRow: View {

    @Perception.Bindable var manager: SessionManager

    /// The host whose sessions are being picked, when its group is expanded.
    @State private var expandedHostID: Int64?

    /// Sessions grouped by host, in the order the hosts were first opened, so
    /// the strip does not reshuffle itself as sessions come and go.
    private var byHost: [(hostID: Int64, label: String, sessions: [TerminalSession])] {
        var order: [Int64] = []
        var groups: [Int64: [TerminalSession]] = [:]

        for session in manager.sessions {
            let id = session.host.id ?? -1
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(session)
        }

        return order.map { id in
            let sessions = groups[id] ?? []
            return (id, sessions.first?.host.label ?? "", sessions)
        }
    }

    private var isMultiHost: Bool { byHost.count > 1 }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if let expanded = expandedGroup {
                    sessionPicker(for: expanded)
                    Divider()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if isMultiHost {
                            ForEach(byHost, id: \.hostID) { group in
                                hostTab(group)
                            }
                        } else {
                            ForEach(manager.sessions) { session in
                                // Escaping row builder, outside the wrapper on
                                // the body above. Without this the tab keeps the
                                // title the session had when the strip was built,
                                // and the shell changes it on every `cd`.
                                WithPerceptionTracking {
                                    sessionTab(session, title: session.title)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            // Opaque: the terminal ignores the bottom safe area and draws underneath
            // this strip, so anything translucent here reads as terminal output.
            .background(Color(.systemBackground))
            // Collapse the picker as soon as its host is no longer the point.
            .onValueChange(of: manager.selectedID) { _ in
                if let expandedHostID, manager.selected?.host.id != expandedHostID {
                    self.expandedHostID = nil
                }
            }
        }
    }

    private var expandedGroup: (hostID: Int64, label: String, sessions: [TerminalSession])? {
        guard let expandedHostID else { return nil }
        return byHost.first { $0.hostID == expandedHostID }
    }

    /// One tab per host. A single session jumps straight there; several toggle
    /// the picker instead, because guessing which one the user meant would be
    /// wrong half the time.
    private func hostTab(_ group: (hostID: Int64, label: String, sessions: [TerminalSession])) -> some View {
        let containsSelection = group.sessions.contains { $0.id == manager.selected?.id }

        return Button {
            if group.sessions.count == 1 {
                manager.selectedID = group.sessions.first?.id
                expandedHostID = nil
            } else {
                expandedHostID = (expandedHostID == group.hostID) ? nil : group.hostID
            }
        } label: {
            HStack(spacing: 6) {
                statusDot(for: group.sessions)
                Text(group.label)
                    .lineLimit(1)
                    .font(.footnote)

                if group.sessions.count > 1 {
                    Text(verbatim: "\(group.sessions.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.25), in: .capsule)
                    // Points where the picker will go: up to open, down to put
                    // it away. The strip sits at the bottom of the screen, so
                    // the arrow that means "more" is the one pointing up.
                    Image(systemName: expandedHostID == group.hostID ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                containsSelection ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    private func sessionTab(_ session: TerminalSession, title: String) -> some View {
        let isSelected = session.id == manager.selected?.id

        return Button {
            manager.selectedID = session.id
            expandedHostID = nil
        } label: {
            HStack(spacing: 6) {
                statusDot(for: [session])
                Text(title)
                    .lineLimit(1)
                    .font(.footnote)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    /// The numbered sessions of one host, in the layout rather than over it.
    private func sessionPicker(
        for group: (hostID: Int64, label: String, sessions: [TerminalSession])
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    sessionTab(
                        session,
                        title: String(localized: .sessionPickerSessionLabel)
                            .replacingOccurrences(of: "%1$d", with: "\(index + 1)")
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(.tertiarySystemBackground))
    }

    /// One dot for a whole host: the worst state among its sessions, so a
    /// collapsed group cannot hide a connection that has dropped.
    private func statusDot(for sessions: [TerminalSession]) -> some View {
        let color: Color = if sessions.contains(where: { isBad($0.phase) }) {
            .red
        } else if sessions.contains(where: { needsAnswer($0.phase) }) {
            .orange
        } else if sessions.contains(where: { $0.phase == .connecting }) {
            .yellow
        } else {
            .green
        }

        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func isBad(_ phase: TerminalSession.Phase) -> Bool {
        switch phase {
        case .failed, .disconnected: true
        default: false
        }
    }

    private func needsAnswer(_ phase: TerminalSession.Phase) -> Bool {
        switch phase {
        case .needsPassword, .needsHostKeyApproval: true
        default: false
        }
    }
}
