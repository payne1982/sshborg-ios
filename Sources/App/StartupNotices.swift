// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The three things the app says to the user unprompted, ported from the
/// sequence Android runs in `AppNavigation`: the privacy notice, a one-time
/// warning on a compromised device, and a reminder that the app's own
/// protections are switched off.
///
/// All three were half-here already — the preferences that remember them, the
/// strings that word them, and for the second a whole `JailbreakDetector` — with
/// nothing that ever showed them. That is the same shape as the app lock and the
/// encryption switch before them: a stored flag reads exactly like a finished
/// feature from anywhere except the place that was supposed to read it.
///
/// One deliberate divergence. Android's privacy dialog has a Reject button that
/// calls `finishAffinity()`; an iOS app cannot close itself, so there is only
/// Accept. A button that claimed to refuse and then left you in the app would be
/// worse than not offering one — refusing here means deleting the app, which is
/// the user's to do and not ours to mime.
///
/// They are raised in order from one task rather than by three independent
/// conditions, because SwiftUI alerts that become true in the same frame do not
/// queue — all but one simply never appear.
@MainActor
struct StartupNotices: ViewModifier {

    let preferences: AppPreferences
    let lock: AppLock

    @Environment(\.openURL) private var openURL

    @State private var showsPrivacyNotice = false
    @State private var showsJailbreakWarning = false
    @State private var showsSecurityReminder = false

    func body(content: Content) -> some View {
        content
            .alert(Text(.privacyPolicyDialogTitle), isPresented: $showsPrivacyNotice) {
                // A `Button` rather than a `Link`: an alert's actions are built
                // from buttons, and anything else is not guaranteed to appear.
                Button(String(localized: .actionReadPolicy)) {
                    openURL(Self.privacyPolicyURL)
                }
                Button(String(localized: .actionAccept)) {
                    preferences.privacyPolicyAccepted = true
                }
            } message: {
                Text(.privacyPolicyDialogBody)
            }
            .alert(Text(.rootWarningTitle), isPresented: $showsJailbreakWarning) {
                // Acknowledging is the only way out, as on Android. There is
                // nothing to decide: the app cannot make the device safer, it
                // can only make sure the user knows.
                Button(String(localized: .actionIUnderstand)) {
                    preferences.jailbreakWarningAcknowledged = true
                }
            } message: {
                // Not Android's `root_warning_body`, which names rooting and the
                // Android Keystore. The concern is the same, the words are not.
                Text(.iosJailbreakWarningBody)
            }
            .alert(Text(.securityReminderTitle), isPresented: $showsSecurityReminder) {
                Button(String(localized: .actionDontShowAgain)) {
                    preferences.securityReminderDismissed = true
                }
                Button(String(localized: .actionRemindLater), role: .cancel) {}
            } message: {
                Text(.securityReminderBody)
            }
            .task { await raiseNotices() }
    }

    /// The same page the Android app links to.
    private static let privacyPolicyURL = URL(string: "https://sshborg.com/privacy_policy.html")!

    private func raiseNotices() async {
        // Every button in an alert dismisses it, including the one that only
        // opens the policy in a browser. So the notice is raised again until the
        // flag is actually set: reading the policy has to leave you back where
        // you were, not past the question.
        while !preferences.privacyPolicyAccepted {
            showsPrivacyNotice = true
            await Self.tick()
        }

        if !preferences.jailbreakWarningAcknowledged, JailbreakDetector.isJailbroken() {
            showsJailbreakWarning = true
            while showsJailbreakWarning { await Self.tick() }
        }

        // Android's delay, and its reason: arriving with the first frame this
        // would read as part of launching, and be dismissed as one.
        try? await Task.sleep(for: .seconds(1.5))

        // Never over the lock cover. Waiting rather than giving up means the
        // reminder still arrives on a launch that began behind the gate, which
        // is every launch once someone has set one.
        while lock.isLocked { await Self.tick() }

        guard !preferences.securityReminderDismissed else { return }
        // Exactly Android's condition: shown while either protection is off.
        guard preferences.lockMode == .none || !preferences.keychainEncryption else { return }
        showsSecurityReminder = true
    }

    private static func tick() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}

extension View {
    func startupNotices(preferences: AppPreferences, lock: AppLock) -> some View {
        modifier(StartupNotices(preferences: preferences, lock: lock))
    }
}
