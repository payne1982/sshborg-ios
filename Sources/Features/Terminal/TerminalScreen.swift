// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The terminal itself: tab strip, the live view, the extra key row, and the
/// prompts the connection can raise.
///
/// Ported from the Android `TerminalScreen`. The command-history suggestion bar
/// is not here yet: it reads the shell history off the server over SFTP, so it
/// arrives with phase 6.
struct TerminalScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Bindable var manager: SessionManager

    @State private var passwordInput = ""
    @State private var keyboard = KeyboardVisibility()
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = manager.selected {
                terminal(for: session)
            } else {
                ContentUnavailableView(
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: .actionClose), systemImage: "xmark.circle") {
                        manager.close(session)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func terminal(for session: TerminalSession) -> some View {
        ZStack {
            TerminalHostView(session: session, fontSize: environment.preferences.terminalFontSize)
                .ignoresSafeArea(.container, edges: .bottom)
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
            VStack(spacing: 0) {
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
                    if keyboard.isVisible || environment.preferences.extraKeysBarPinned {
                        ExtraKeyRow(
                            session: session,
                            isPinned: Binding(
                                get: { environment.preferences.extraKeysBarPinned },
                                set: { environment.preferences.extraKeysBarPinned = $0 }
                            )
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
            // what it costs a user. Android shows its dialog inside the screen
            // for the same reason.
            StatusOverlay(
                // A first connection is a question, not a fault. A key that has
                // *changed* is a warning, and keeps the alarming presentation.
                kind: isChange ? .failure : .question,
                message: isChange
                    ? String(localized: .iosHostkeyChangedTitle)
                    : String(localized: .hostkeyTitle),
                detail: hostKeyDetail(for: session, info: info, isChange: isChange),
                // Never behind a disclosure: the fingerprint is the thing the
                // user is being asked to look at.
                showsDetailOutright: true,
                actions: AnyView(
                    HStack {
                        Button(String(localized: .actionTrust)) {
                            Task { await session.connect(acceptHostKey: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        // Red when a stored key has changed: that is the case
                        // where accepting out of reflex is the expensive one.
                        .tint(isChange ? Color.red : Color.accentColor)

                        Button(String(localized: .actionReject)) { manager.close(session) }
                    }
                )
            )

        case .needsPassword:
            // In the layout, like the host key prompt — and for a reason found by
            // measuring pixels, not by taste.
            //
            // A system alert's panel is a translucent material, so it takes its
            // colour from whatever is behind it — and behind this one is a
            // terminal. Measured on the same alert, same build, three backdrops:
            //
            //     over the host list      panel (194,194,198)
            //     over the black terminal panel (179,179,179), field (158,158,158)
            //     a context menu platter  (239,239,240), for scale
            //
            // Grey text field on a grey panel on a grey title. It stays legible
            // and it looks like a mistake, and the contrast is not ours to fix:
            // the panel follows the terminal background, which the user chooses.
            //
            // ⚠️ It was first reported as *invisible*, and the build VM agreed —
            // 99.6% of the pixels inside the alert's frame were pure black, with
            // only the placeholder and the caret surviving. That extreme was the
            // VM, which has no GPU, renders in software, and was later caught not
            // drawing a context menu's platter at all. The mechanism was real;
            // the severity was the renderer. Worth remembering before quoting a
            // VM screenshot as evidence about anything translucent.
            //
            // Either way an opaque panel with explicit label colours cannot be
            // wrong-footed by the terminal behind it, and it matches the host key
            // prompt above — two prompts from one connection that look alike.
            StatusOverlay(
                kind: .question,
                message: String(localized: .iosPasswordPrompt)
                    .replacingOccurrences(
                        of: "%1$@",
                        with: "\(session.host.username)@\(session.host.hostname)"
                    ),
                actions: AnyView(
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField(String(localized: .hostFieldPassword), text: $passwordInput)
                            .textFieldStyle(.roundedBorder)
                            .plainTextEntry()
                            .submitLabel(.go)
                            .focused($isPasswordFocused)
                            .onSubmit { submitPassword(for: session) }

                        HStack {
                            Button(String(localized: .actionConnect)) {
                                submitPassword(for: session)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(String(localized: .actionCancel)) { manager.close(session) }
                        }
                    }
                    // The terminal holds first responder, so the field has to take
                    // it or the user types into a shell they cannot see.
                    //
                    // Asked for on the next runloop turn, not inside `onAppear`:
                    // at that point the field is in the view tree but UIKit has
                    // not finished handing responder status around, and a focus
                    // request that lands mid-handover is dropped — the field shows
                    // a caret and no keyboard ever comes up.
                    .task {
                        await Task.yield()
                        isPasswordFocused = true
                    }
                )
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

    /// The fingerprint and the reason to look at it, shown as the overlay's
    /// expandable detail so the headline stays one line.
    private func hostKeyDetail(
        for session: TerminalSession,
        info: HostKeyInfo,
        isChange: Bool
    ) -> String {
        let host = String(localized: .hostkeyTerminalHost)
            .replacingOccurrences(of: "%1$@", with: session.host.hostname)
        let fingerprint = """
        \(String(localized: .hostkeyTerminalFingerprint))
        \(info.algorithm)
        \(info.fingerprint)
        """

        guard isChange else {
            return "\(host)\n\(fingerprint)\n\n\(String(localized: .hostkeyTerminalTrustQuestion))"
        }

        return """
        \(host)
        \(fingerprint)

        This does not match the key stored for this host. A rebuilt server looks \
        like this — so does an intercepted connection. Accept only if you know \
        the server changed.
        """
    }
}

private struct SessionTabRow: View {

    @Bindable var manager: SessionManager

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
                            sessionTab(session, title: session.title)
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
        .onChange(of: manager.selectedID) { _, _ in
            if let expandedHostID, manager.selected?.host.id != expandedHostID {
                self.expandedHostID = nil
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
