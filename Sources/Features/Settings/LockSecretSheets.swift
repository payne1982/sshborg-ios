// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Setting the app's own PIN or passphrase, and changing one.
///
/// Android's `LockSecretDialog`, as a sheet: a choice between a PIN and a
/// passphrase, the secret twice, and — when there is one already — the current
/// one first. The current one is checked with ``AppLockSecret/check(_:)``,
/// which does not count failures: the app is already unlocked here, and the
/// attempts are what guard the unlock screen, not this one.
///
/// The rules are the ones the unlock screen enforces: four to twelve digits for a
/// PIN, at least four characters for a passphrase.
struct NewSecretSheet: View {

    /// Asked first when a secret is already set; nil for a first one.
    let verifyCurrent: ((String) async -> Bool)?
    let onSave: (AppLockSecret.Kind, String) async -> Void
    let onCancel: () -> Void

    @State private var kind: AppLockSecret.Kind = .pin
    @State private var current = ""
    @State private var secret = ""
    @State private var confirmation = ""
    @State private var problem: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                if verifyCurrent != nil {
                    Section {
                        SecureField(String(localized: .lockCurrent), text: $current)
                            .plainTextEntry()
                            .accessibilityIdentifier("lock-current-field")
                    }
                }

                Section {
                    Picker(selection: $kind) {
                        Text(.lockKindPin).tag(AppLockSecret.Kind.pin)
                        Text(.lockKindPassphrase).tag(AppLockSecret.Kind.passphrase)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    // A PIN typed as a passphrase and then switched would keep
                    // letters a PIN cannot have.
                    .onValueChange(of: kind) { _ in
                        secret = ""
                        confirmation = ""
                        problem = nil
                    }

                    SecureField(
                        String(localized: kind == .pin ? .lockKindPin : .lockKindPassphrase),
                        text: $secret
                    )
                    .keyboardType(kind == .pin ? .numberPad : .default)
                    .plainTextEntry()
                    .accessibilityIdentifier("lock-new-field")

                    SecureField(String(localized: .lockConfirm), text: $confirmation)
                        .keyboardType(kind == .pin ? .numberPad : .default)
                        .plainTextEntry()
                        .accessibilityIdentifier("lock-confirm-field")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(String(localized: .lockSetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: .actionCancel), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: .actionSave), action: save)
                        .disabled(isWorking || secret.isEmpty || confirmation.isEmpty)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func save() {
        guard AppLockSecret.isAcceptable(secret, as: kind) else {
            problem = String(localized: .lockTooShort)
            return
        }
        guard secret == confirmation else {
            problem = String(localized: .lockMismatch)
            return
        }
        isWorking = true
        Task {
            if let verifyCurrent, await verifyCurrent(current) == false {
                problem = String(localized: .lockIncorrect)
                isWorking = false
                return
            }
            await onSave(kind, secret)
            isWorking = false
        }
    }
}

/// Asks for the current secret before the lock is changed to something else.
///
/// Without it anyone holding the phone unlocked could turn the lock off in two
/// taps, which would make the lock decorative.
struct ConfirmSecretSheet: View {

    let verify: (String) async -> Bool
    let onVerified: () -> Void
    let onCancel: () -> Void

    @State private var typed = ""
    @State private var problem: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(String(localized: .lockCurrent), text: $typed)
                        .plainTextEntry()
                        .onSubmit(confirm)
                        .accessibilityIdentifier("lock-current-field")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Color.red)
                    }
                }
            }
            .navigationTitle(String(localized: .lockConfirmCurrentTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: .actionCancel), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: .lockConfirm), action: confirm)
                        .disabled(isWorking || typed.isEmpty)
                }
            }
        }
    }

    private func confirm() {
        guard !typed.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            if await verify(typed) {
                onVerified()
            } else {
                problem = String(localized: .lockIncorrect)
                typed = ""
            }
            isWorking = false
        }
    }
}
