// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The two questions any connection can ask — a password, and whether to trust a
/// host key — drawn the same way wherever they are asked.
///
/// They started out different: the terminal moved to these in-layout panels
/// while the SFTP browser kept system alerts, and the same question looked like
/// two different things a minute apart. Android has them consistent too, though
/// the other way round — `PasswordDialog` and `HostKeyDialog` are `AlertDialog`s
/// in both of its screens.
///
/// The panel was chosen over the alert for a reason that only applies to one of
/// the two screens: an alert's translucent platter takes its colour from what is
/// behind it, and behind the terminal is a black surface the user chooses the
/// colour of. Measured, the same alert's panel reads `(194,194,198)` over the
/// host list and `(179,179,179)` over the terminal, with its text field a
/// near-identical `(158,158,158)` inside it. Rather than have one screen dodge
/// that and the other not, both use the opaque panel.
enum ConnectionPrompt {

    /// Asks for a password, with the field already focused and whatever the
    /// server said on the way in above it.
    ///
    /// `onSubmit` and the Connect button do the same thing on purpose: a
    /// keyboard's Go key and a button that says Connect are the same intention.
    @MainActor
    static func password(
        for user: String,
        at hostname: String,
        banner: String?,
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        onConnect: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        StatusOverlay(
            kind: .question,
            message: String(localized: .iosPasswordPrompt)
                .replacingOccurrences(of: "%1$@", with: "\(user)@\(hostname)"),
            actions: AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    // Above the field, because a banner read after typing is a
                    // banner that was never read: the server's terms, or the
                    // warning that this is the wrong machine, have to be in
                    // front of the person while the field is still empty.
                    if let banner, !banner.isEmpty {
                        ServerBannerView(text: banner)
                    }

                    SecureField(String(localized: .hostFieldPassword), text: text)
                        .textFieldStyle(.roundedBorder)
                        .plainTextEntry()
                        .submitLabel(.go)
                        .focused(isFocused)
                        .onSubmit(onConnect)

                    HStack {
                        Button(String(localized: .actionConnect), action: onConnect)
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: .actionCancel), action: onCancel)
                    }
                }
                // Asked for on the next runloop turn, not inside `onAppear`: at
                // that point the field is in the tree but UIKit has not finished
                // handing responder status around, and a request that lands
                // mid-handover is dropped — leaving a caret and no keyboard.
                //
                // Then asked again, because the yield above was measured on the
                // simulator and the simulator is not the slow case. On an iPhone
                // X the handover takes longer, and the report from that device
                // was exactly the symptom this is meant to prevent: the prompt
                // up, no keyboard. Setting it true when it is already true costs
                // nothing, so the second ask is free wherever the first one took.
                .task {
                    await Task.yield()
                    isFocused.wrappedValue = true

                    try? await Task.sleep(nanoseconds: 350_000_000)
                    isFocused.wrappedValue = true
                }
            )
        )
    }

    /// Shows a host key and asks whether to trust it — or, when it is not the
    /// key saved for this host, says so before anything else.
    ///
    /// The two are not the same event, and Android made them look different on
    /// 30/10/2026 after a user reported a changed key arriving at the same calm
    /// question as a new one. Same structure here: a red, bold line that this is
    /// not the saved key, what that can mean, then the host and the fingerprint;
    /// and the accept button says what it will do — **replace the key** — rather
    /// than how to feel about it. The red moves to Reject, the answer that keeps
    /// the saved key, and the two buttons weigh the same, so a reflex does not
    /// land on the expensive one by being the prominent one.
    @MainActor
    static func hostKey(
        _ info: HostKeyInfo,
        hostname: String,
        isChange: Bool,
        onTrust: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) -> some View {
        StatusOverlay(
            // A first connection is a question, not a fault. A key that has
            // *changed* is a warning, and keeps the alarming presentation.
            kind: isChange ? .failure : .question,
            message: isChange
                ? String(localized: .hostkeyChangedTitle)
                : String(localized: .hostkeyTitle),
            detail: detail(info, hostname: hostname),
            // Never behind a disclosure: the fingerprint is the thing the user
            // is being asked to look at.
            showsDetailOutright: true,
            warning: isChange
                ? (String(localized: .hostkeyChangedWarning), String(localized: .hostkeyChangedExplain))
                : nil,
            actions: AnyView(
                HStack {
                    if isChange {
                        Button(String(localized: .hostkeyChangedAccept), action: onTrust)
                            .buttonStyle(.bordered)
                        Button(String(localized: .actionReject), action: onReject)
                            .buttonStyle(.bordered)
                            .tint(.red)
                    } else {
                        Button(String(localized: .actionTrust), action: onTrust)
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: .actionReject), action: onReject)
                    }
                }
            )
        )
    }

    /// The host, the fingerprint and the question — the same for a new key and a
    /// changed one, as on Android. What is different about a changed key is said
    /// above it, in words that are translated; the paragraph that used to sit
    /// here was English in every language.
    static func detail(_ info: HostKeyInfo, hostname: String) -> String {
        let host = String(localized: .hostkeyTerminalHost)
            .replacingOccurrences(of: "%1$@", with: hostname)
        return """
        \(host)
        \(String(localized: .hostkeyTerminalFingerprint))
        \(info.algorithm)
        \(info.fingerprint)

        \(String(localized: .hostkeyTerminalTrustQuestion))
        """
    }

    /// Says why mosh could not start, and offers the two answers there are.
    ///
    /// A question rather than a failure, which is what it is: the SSH session is
    /// already open — it is the one that started the server — so carrying on
    /// without mosh costs nothing but the feature. There is no silent fall back,
    /// because the switch is per host and explicit.
    ///
    /// Three of the four reasons are on the server and arrive as "the app does
    /// not work", so each says what to do about it. The fourth is only ever
    /// silence.
    @MainActor
    static func moshUnavailable(
        _ failure: MoshBootstrap.Unavailable,
        onCarryOn: @escaping () -> Void,
        onLeave: @escaping () -> Void
    ) -> some View {
        StatusOverlay(
            kind: .question,
            // What happened, and then what to do about it. Two lines in the one
            // slot the overlay has for them, because the second is the half
            // somebody has to act on.
            message: String(localized: .moshFailedTitle)
                + "\n"
                + String(localized: explanation(of: failure.reason)),
            // What the server actually said, where that is the diagnosis, and
            // where we were trying to talk when it was not. Monospaced,
            // selectable and copyable, which the overlay gives for nothing. The
            // handover line never reaches here: the session key is taken out of
            // the text before anything else happens to it.
            detail: failure.detail,
            showsDetailOutright: true,
            actions: AnyView(
                HStack {
                    Button(String(localized: .moshActionCarryOn), action: onCarryOn)
                        .buttonStyle(.borderedProminent)

                    Button(String(localized: .moshActionLeave), action: onLeave)
                }
            )
        )
    }

    private static func explanation(
        of reason: MoshBootstrap.Unavailable.Reason
    ) -> LocalizedStringResource {
        switch reason {
        case .notInstalled: .moshFailedNotInstalled
        case .localeNotUTF8: .moshFailedLocale
        case .noConnectLine: .moshFailedNoAnswer
        case .noUDPAnswer: .moshFailedNoUdp
        }
    }

    static func detail(_ info: HostKeyInfo, hostname: String, isChange: Bool) -> String {
        let host = String(localized: .hostkeyTerminalHost)
            .replacingOccurrences(of: "%1$@", with: hostname)
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
