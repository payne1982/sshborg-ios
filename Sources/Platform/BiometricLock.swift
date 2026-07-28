// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate for the app, mirroring the Android `BiometricHelper`.
///
/// The Android version is biometric-only by design, and only falls back to the
/// device credential when no usable biometric is enrolled — so a user who
/// enabled the lock and later removed every fingerprint is not shut out of their
/// own hosts forever. The same rule is applied here by choosing between
/// `deviceOwnerAuthenticationWithBiometrics` and `deviceOwnerAuthentication`.
enum BiometricLock {

    enum Availability: Equatable {
        case biometrics(LABiometryType)
        case passcodeOnly
        case unavailable
    }

    /// What this device can actually do right now. Re-evaluate on each use:
    /// biometrics can be removed or locked out between launches.
    static func availability() -> Availability {
        let context = LAContext()

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            return .biometrics(context.biometryType)
        }
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            return .passcodeOnly
        }
        return .unavailable
    }

    /// True when the lock can be offered at all, i.e. the device has either a
    /// biometric enrolled or a passcode set.
    static func canAuthenticate() -> Bool {
        availability() != .unavailable
    }

    /// Prompts the user. Returns `true` on success, `false` on cancellation or
    /// permanent failure — never throws, so callers can treat it as a gate.
    ///
    /// A wrong-but-retryable attempt does not resolve this call: `LAContext`
    /// keeps its own retry loop and only returns once the outcome is final.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")

        let policy: LAPolicy
        switch availability() {
        case .biometrics:
            policy = .deviceOwnerAuthenticationWithBiometrics
        case .passcodeOnly:
            policy = .deviceOwnerAuthentication
        case .unavailable:
            return false
        }

        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}
