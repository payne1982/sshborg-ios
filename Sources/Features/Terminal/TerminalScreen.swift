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

    var body: some View {
        VStack(spacing: 0) {
            if manager.sessions.count > 1 {
                SessionTabRow(manager: manager)
                Divider()
            }

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

            overlay(for: session)
        }
        // Both bars live in the bottom inset, stacked. The session tab strip is
        // at the top of the screen, so neither can push the other out — the
        // Android build hides the suggestion bar once a second session opens,
        // and this arrangement makes that impossible rather than unlikely.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.phase == .connected {
                VStack(spacing: 0) {
                    ForwardingNotice(statuses: session.forwardingStatus)
                    SuggestionBar(
                        suggestions: session.suggestions,
                        isSticky: environment.preferences.suggestionsBarSticky
                    ) { command in
                        session.apply(suggestion: command)
                    }
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
        .alert("Password", isPresented: needsPasswordBinding(for: session)) {
            SecureField(String(localized: .hostFieldPassword), text: $passwordInput)
            Button(String(localized: .actionCancel), role: .cancel) { manager.close(session) }
            Button(String(localized: .actionConnect)) {
                let password = passwordInput
                passwordInput = ""
                Task { await session.connect(password: password) }
            }
        } message: {
            Text("Enter the password for \(session.host.username)@\(session.host.hostname).")
        }
        .alert(
            hostKeyTitle(for: session),
            isPresented: needsHostKeyBinding(for: session),
            presenting: hostKeyInfo(for: session)
        ) { _ in
            Button(String(localized: .actionCancel), role: .cancel) { manager.close(session) }
            Button(String(localized: .actionAccept), role: hostKeyIsChange(for: session) ? .destructive : nil) {
                Task { await session.connect(acceptHostKey: true) }
            }
        } message: { info in
            Text(hostKeyMessage(for: session, info: info))
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

        case .connected, .needsPassword, .needsHostKeyApproval:
            EmptyView()
        }
    }


    // MARK: - Alert plumbing
    //
    // SwiftUI wants a Bool binding, while the truth lives in the session's phase.
    // These translate between the two, and never set the phase directly: a
    // dismissal is always routed through an explicit button.

    private func needsPasswordBinding(for session: TerminalSession) -> Binding<Bool> {
        Binding(get: { session.phase == .needsPassword }, set: { _ in })
    }

    private func needsHostKeyBinding(for session: TerminalSession) -> Binding<Bool> {
        Binding(get: { hostKeyInfo(for: session) != nil }, set: { _ in })
    }

    private func hostKeyInfo(for session: TerminalSession) -> HostKeyInfo? {
        guard case .needsHostKeyApproval(let info, _) = session.phase else { return nil }
        return info
    }

    private func hostKeyIsChange(for session: TerminalSession) -> Bool {
        guard case .needsHostKeyApproval(_, let isChange) = session.phase else { return false }
        return isChange
    }

    private func hostKeyTitle(for session: TerminalSession) -> String {
        hostKeyIsChange(for: session) ? String(localized: .iosHostkeyChangedTitle) : String(localized: .hostkeyTitle)
    }

    private func hostKeyMessage(for session: TerminalSession, info: HostKeyInfo) -> String {
        let fingerprint = "\(info.algorithm)\n\(info.fingerprint)"

        if hostKeyIsChange(for: session) {
            return """
            The key presented by \(session.host.hostname) does not match the one stored for it.

            \(fingerprint)

            This happens when a server is rebuilt, but it is also what an intercepted connection looks like. Only accept if you know the server changed.
            """
        }

        return """
        \(session.host.hostname) has not been seen before. Check that this fingerprint matches the server.

        \(fingerprint)
        """
    }
}

/// The strip of open tabs, shown only when there is more than one.
/// The tab strip above the terminal.
///
/// Adaptive, ported from the Android rework: with sessions open on more than one
/// host it shows **one tab per host** rather than one per session, because a
/// dozen tabs all reading "web-01" tell you nothing about which is which. A host
/// with a single session is a direct jump; a host with several expands a
/// numbered picker.
///
/// That picker is laid out **inline, above the tabs — not a popup**. A menu or a
/// sheet resigns first responder, so the soft keyboard closes and has to be
/// brought back after every session switch. Keeping it in the layout is the
/// whole reason it looks like this.
///
/// With one host it stays as it was: a tab per session.
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
                    Image(systemName: expandedHostID == group.hostID ? "chevron.up" : "chevron.down")
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
