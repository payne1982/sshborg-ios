// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What is shown instead of the app while it is locked.
///
/// It does two jobs at once and they want opposite things. As a **privacy
/// cover** it has to be opaque and instant, hiding a host list that may be on
/// screen the moment the app is swiped away. As a **prompt** it has to explain
/// itself, since a blank screen with no way forward is indistinguishable from a
/// hung app.
///
/// So: opaque from the first frame, with the explanation and the button arriving
/// only once the system has finished asking. While the system's own sheet is up
/// there is nothing to say, and saying it anyway would put two prompts on screen
/// at once.
struct LockScreen: View {

    let biometryName: String
    let isAsking: Bool
    let onRetry: () -> Void

    /// Forces the way out to appear even if nothing ever says the asking is
    /// over.
    ///
    /// `isAsking` is set before the system prompt and cleared after it, so if
    /// that call never returns it is never cleared — and this view would sit
    /// there opaque, with no text and no button, indistinguishable from a hung
    /// app and with no way past it. A cover that cannot be dismissed is worse
    /// than no cover: it locks the owner out of their own hosts.
    ///
    /// Raised as a concern from the Android app on 03/09/2026, where covers
    /// were reported staying up by mistake. The rule taken from it: never show
    /// a wall without a guaranteed way through, and do not make that guarantee
    /// depend on the thing that might be stuck.
    @State private var hasWaitedForPrompt = false

    /// The system prompt takes about a second to appear and answer. Three is
    /// long enough not to race it and short enough not to feel hung.
    private static let promptGracePeriod = Duration.seconds(3)

    private var showsControls: Bool { !isAsking || hasWaitedForPrompt }

    var body: some View {
        ZStack {
            // Opaque, not a material: the whole point is that nothing behind it
            // shows through. The same lesson the terminal's prompts learned the
            // expensive way.
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text(.appName)
                    .font(.headline)

                if showsControls {
                    Text(.biometricPromptSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: onRetry) {
                        Label(
                            String(localized: .iosUnlockWith)
                                .replacingOccurrences(of: "%1$@", with: biometryName),
                            systemImage: "faceid"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
        }
        .task {
            try? await Task.sleep(for: Self.promptGracePeriod)
            hasWaitedForPrompt = true
        }
    }
}

/// The cover when the lock is the app's own PIN or passphrase.
///
/// Opaque from the first frame like the other one, but with nothing to wait
/// for: there is no system sheet in front of it, so the field is there at once
/// and has the keyboard. A PIN gets the number pad, a passphrase the ordinary
/// keyboard; both are secure entry.
///
/// A wrong answer says so and empties the field. Five of them in a row lock the
/// field for thirty seconds, then a minute, then two, up to fifteen minutes —
/// Android's schedule — and the countdown is shown so the wait is not mistaken
/// for a broken button. The count survives the app being killed, because it is
/// kept with the secret and not in this view.
struct SecretLockScreen: View {

    let kind: AppLockSecret.Kind
    let lockoutRemaining: () -> Int
    let onSubmit: (String) async -> AppLockSecret.Verdict

    @State private var typed = ""
    @State private var message: String?
    @State private var waiting = 0
    @State private var isChecking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text(.lockTitle)
                    .font(.headline)

                SecureField(
                    String(localized: kind == .pin ? .lockEnterPin : .lockEnterPassphrase),
                    text: $typed
                )
                .textFieldStyle(.roundedBorder)
                .keyboardType(kind == .pin ? .numberPad : .default)
                .textContentType(.password)
                .plainTextEntry()
                .submitLabel(.go)
                .focused($isFocused)
                .disabled(waiting > 0 || isChecking)
                .onSubmit(submit)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("lock-secret-field")

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .multilineTextAlignment(.center)
                }

                Button(String(localized: .lockUnlockAction), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding(32)
        }
        .onAppear {
            waiting = lockoutRemaining()
            isFocused = waiting == 0
        }
        // The countdown, once a second, for as long as there is one.
        .task(id: waiting > 0) {
            while waiting > 0 {
                message = String(localized: .lockLockedOut)
                    .replacingOccurrences(of: "%1$d", with: "\(waiting)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waiting = lockoutRemaining()
            }
            if message != nil, !isChecking { message = nil }
            isFocused = true
        }
    }

    private var canSubmit: Bool {
        guard waiting == 0, !isChecking else { return false }
        // The same floor the setter used: anything shorter cannot be right, and
        // trying it would spend one of the five attempts for nothing.
        switch kind {
        case .pin: return typed.count >= AppLockSecret.pinMinimum
        case .passphrase: return typed.count >= AppLockSecret.passphraseMinimum
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let attempt = typed
        isChecking = true
        Task {
            let verdict = await onSubmit(attempt)
            isChecking = false
            typed = ""
            switch verdict {
            case .accepted:
                message = nil
            case .refused:
                message = String(localized: .lockIncorrect)
                isFocused = true
            case .lockedOut(let seconds):
                waiting = seconds
            }
        }
    }
}
