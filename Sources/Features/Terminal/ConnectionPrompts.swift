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

    /// Asks for a password, with the field already focused.
    ///
    /// `onSubmit` and the Connect button do the same thing on purpose: a
    /// keyboard's Go key and a button that says Connect are the same intention.
    @MainActor
    static func password(
        for user: String,
        at hostname: String,
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

    /// Shows a host key and asks whether to trust it.
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
                ? String(localized: .iosHostkeyChangedTitle)
                : String(localized: .hostkeyTitle),
            detail: detail(info, hostname: hostname, isChange: isChange),
            // Never behind a disclosure: the fingerprint is the thing the user
            // is being asked to look at.
            showsDetailOutright: true,
            actions: AnyView(
                HStack {
                    Button(String(localized: .actionTrust), action: onTrust)
                        .buttonStyle(.borderedProminent)
                        // Red when a stored key has changed: that is the case
                        // where accepting out of reflex is the expensive one.
                        .tint(isChange ? Color.red : Color.accentColor)

                    Button(String(localized: .actionReject), action: onReject)
                }
            )
        )
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
