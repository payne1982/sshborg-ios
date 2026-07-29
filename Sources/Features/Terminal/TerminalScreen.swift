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
                    ExtraKeyRow(session: session)
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
            statusCard {
                ProgressView()
                Text(String(localized: .iosTerminalConnecting).replacingOccurrences(of: "%1$@", with: session.host.hostname))
            }

        case .failed(let message):
            statusCard {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Button(String(localized: .iosActionRetry)) { Task { await session.connect() } }
                    .buttonStyle(.borderedProminent)
            }

        case .disconnected(let reason):
            statusCard {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                Text(reason.map { "\(String(localized: .terminalDisconnected)) — \($0)" } ?? String(localized: .terminalDisconnected))
                HStack {
                    Button(String(localized: .iosActionReconnect)) { Task { await session.connect() } }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: .actionClose)) { manager.close(session) }
                }
            }

        case .connected, .needsPassword, .needsHostKeyApproval:
            EmptyView()
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(radius: 8)
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
private struct SessionTabRow: View {

    @Bindable var manager: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(manager.sessions) { session in
                    let isSelected = session.id == manager.selected?.id

                    Button {
                        manager.selectedID = session.id
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(for: session)
                            Text(session.title)
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func statusDot(for session: TerminalSession) -> some View {
        let color: Color = switch session.phase {
        case .connected: .green
        case .connecting: .yellow
        case .failed, .disconnected: .red
        case .needsPassword, .needsHostKeyApproval: .orange
        }

        return Circle().fill(color).frame(width: 7, height: 7)
    }
}
