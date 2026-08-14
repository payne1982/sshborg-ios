// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import SwiftUI

/// Whether the app is showing its contents or hiding them behind an
/// authentication gate. Counterpart of what Android's `MainActivity` does in
/// `onStart`/`onStop`.
///
/// The three pieces are the same as there, and each earns its place:
///
/// - **A cover on the way out**, so hosts and open shells are not sitting on
///   screen when the app comes back, nor in the app switcher's snapshot of it.
///   iOS takes that snapshot as the app leaves the foreground, which is why the
///   cover goes up on `inactive` rather than waiting for `background`.
/// - **A timeout**, so glancing at a notification and coming straight back does
///   not mean authenticating again. Android compares against `lastAuthTime`;
///   this compares against ``lastAuthenticated``.
/// - **The prompt itself**, once the timeout has passed.
///
/// One place where the platforms cannot agree: Android calls `finish()` when
/// authentication fails, closing the app. An iOS app cannot close itself — the
/// guidelines forbid it and there is no API — so a refusal leaves the cover up
/// with a button to try again, which is also kinder to someone whose face simply
/// was not recognised.
@MainActor
@Observable
final class AppLock {

    /// True while the contents must not be shown.
    private(set) var isLocked: Bool

    /// True while the system's own authentication UI is up.
    ///
    /// It has to be tracked because that UI makes the app inactive, which would
    /// otherwise raise the cover, come back active, and ask again — the loop
    /// Android guards with its own `isAuthenticating` flag, for the same reason.
    @ObservationIgnored private var isAuthenticating = false

    /// When the user last got in. `nil` means never, so a cold launch always
    /// asks however short the timeout is.
    @ObservationIgnored private var lastAuthenticated: Date?

    /// Whether the prompt has already been raised for the cover currently up.
    ///
    /// A refusal must not be answered by asking again immediately: that is a
    /// loop the user cannot leave, since every dismissal makes the app active
    /// once more. After one refusal the cover stays with its own button, and
    /// asking again is the user's move.
    @ObservationIgnored private var hasAskedSinceLocking = false

    @ObservationIgnored private let preferences: AppPreferences

    /// How to ask, and whether asking is possible at all.
    ///
    /// Injected rather than called directly so the sequencing here — what
    /// happens on a refusal, on a return while already open, on a cold launch —
    /// can be tested. None of that involves a face, and all of it is where the
    /// mistakes have been. Adding test-only hooks to the class instead would put
    /// a way past the lock inside the lock.
    @ObservationIgnored private let ask: (AppPreferences.LockMode) async -> Bool
    @ObservationIgnored private let isAuthenticationPossible: () -> Bool

    init(
        preferences: AppPreferences,
        ask: @escaping (AppPreferences.LockMode) async -> Bool = { mode in
            await BiometricLock.authenticate(
                reason: String(localized: .biometricPromptSubtitle),
                mode: mode
            )
        },
        isAuthenticationPossible: @escaping () -> Bool = BiometricLock.canAuthenticate
    ) {
        self.preferences = preferences
        self.ask = ask
        self.isAuthenticationPossible = isAuthenticationPossible
        // Locked from the very first frame when the lock is on, rather than
        // showing the host list and covering it a moment later.
        self.isLocked = Self.shouldLock(preferences, isAuthenticationPossible)
    }

    /// Whether the gate can be raised at all.
    ///
    /// A lock nobody can open is not security, it is a brick. If the device has
    /// neither a biometric enrolled nor a passcode set — someone removed both
    /// after switching this on, or it is a bare simulator — then a cover would
    /// go up over a prompt that can only ever fail, and the app would be shut
    /// against its owner with no way in. Android reaches the same dead end from
    /// the other side: its `authenticate` fails and it calls `finish()`, so the
    /// app closes every time it is opened.
    ///
    /// The hosts are still protected by the device's own encryption at rest,
    /// which is the protection that was there before this feature existed.
    private static func shouldLock(
        _ preferences: AppPreferences,
        _ isAuthenticationPossible: () -> Bool
    ) -> Bool {
        #if DEBUG
        // UI tests drive the app with a finger, and no finger can answer Face
        // ID. Without this every screen behind the gate is untestable, and
        // leaving the lock off on the test simulator instead only works until
        // someone turns it on to test the lock itself.
        //
        // `#if DEBUG` on purpose: a launch argument that unlocks the app must
        // not exist in anything shipped.
        if ProcessInfo.processInfo.arguments.contains("-SSHBorgDisableLock") { return false }
        #endif

        guard preferences.lockMode != .none else { return false }
        return isAuthenticationPossible()
    }

    private var shouldLock: Bool {
        Self.shouldLock(preferences, isAuthenticationPossible)
    }

    /// The app is going away. Covers up unless the system prompt is what took
    /// the foreground.
    func willResignActive() {
        guard shouldLock, !isAuthenticating else { return }

        // Only re-lock once the timeout has expired... except there is no way to
        // know the future here, so the cover goes up immediately and
        // `didBecomeActive` decides whether it was a real absence. Covering is
        // free; showing credentials to whoever picks the phone up is not.
        isLocked = true
        hasAskedSinceLocking = false
    }

    /// The app is back. Lets it through when the lock is off or the absence was
    /// short, and asks otherwise.
    func didBecomeActive() async {
        guard shouldLock else {
            isLocked = false
            return
        }
        // Nothing to unlock. This is the case that mattered: the system's own
        // prompt makes the app inactive while it is up and active again when it
        // goes, and that second transition arrives *after* `authenticate()` has
        // returned — so `isAuthenticating` is already false and no longer
        // guards it. Asking "is the cover even up?" does, and says what this is
        // for besides: unlocking what is locked.
        //
        // Without it the prompt reappeared endlessly, over a host list that was
        // by then fully visible behind it — the lock asking to be let in to a
        // room whose door it had already opened. Android never meets this
        // because its callbacks arrive while its own call is still suspended.
        guard isLocked, !isAuthenticating else { return }

        if let lastAuthenticated,
           Date().timeIntervalSince(lastAuthenticated) <= Double(preferences.lockTimeoutSeconds) {
            isLocked = false
            return
        }

        guard !hasAskedSinceLocking else { return }
        hasAskedSinceLocking = true
        await authenticate()
    }

    /// Asks, and unlocks on success. Safe to call again after a refusal, which
    /// is what the button on the cover does.
    func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let granted = await ask(preferences.lockMode)
        if granted {
            lastAuthenticated = Date()
            isLocked = false
        }
    }

    /// Turning the lock off in Settings takes effect at once rather than at the
    /// next launch — otherwise the app stays locked behind a setting that says
    /// it is not.
    func lockModeChanged() {
        if !shouldLock {
            isLocked = false
        }
    }
}
