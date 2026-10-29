// SPDX-License-Identifier: GPL-3.0-or-later

import CommonCrypto
import Foundation
import Security

/// The app's own PIN or passphrase: a lock that needs no biometrics and no
/// device passcode, and is not either of them.
///
/// Android's `AppLockManager`, number for number, so the two apps behave the
/// same in the hand: a salted PBKDF2-HMAC-SHA256 of 210,000 rounds, compared in
/// constant time, five attempts and then a lockout that starts at thirty seconds
/// and doubles to a ceiling of fifteen minutes.
///
/// **The secret is never stored.** Only the salt, the hash and the number of
/// rounds are, in the app's own preferences — not in the Keychain, because the
/// hash is the thing being protected *by* the cost of deriving it, not a secret
/// in itself, and because an unsigned build cannot reach the Keychain at all.
/// And not in a backup: a lock is a property of one device, and a hash carried
/// to another would be a credential travelling without its owner knowing.
///
/// This is a gate on the user interface — the same kind of thing as the
/// biometric lock. It does not encrypt anything, and it says so in the
/// disclaimer the person agrees to before setting one: there is no way to
/// recover a forgotten secret, because there is nothing to recover it from.
struct AppLockSecret {

    enum Kind: String, CaseIterable {
        case pin
        case passphrase
    }

    /// What is kept.
    struct Record: Equatable {
        let kind: Kind
        let salt: Data
        let hash: Data
        let iterations: Int
    }

    enum Verdict: Equatable {
        case accepted
        /// Wrong, with this many tries left before the next lockout.
        case refused(attemptsLeft: Int)
        /// Too many wrong; try again in this many whole seconds.
        case lockedOut(seconds: Int)
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    // MARK: - What a secret may be

    /// Four to twelve digits for a PIN, four characters or more for a
    /// passphrase: Android's limits.
    static func isAcceptable(_ secret: String, as kind: Kind) -> Bool {
        switch kind {
        case .pin:
            return (pinMinimum...pinMaximum).contains(secret.count) && secret.allSatisfy(\.isASCIIDigit)
        case .passphrase:
            return secret.count >= passphraseMinimum
        }
    }

    // MARK: - Setting and clearing

    var record: Record? {
        guard let raw = defaults.string(forKey: Key.kind), let kind = Kind(rawValue: raw),
              let salt = defaults.data(forKey: Key.salt), !salt.isEmpty,
              let hash = defaults.data(forKey: Key.hash), !hash.isEmpty
        else { return nil }
        let iterations = defaults.integer(forKey: Key.iterations)
        guard iterations > 0 else { return nil }
        return Record(kind: kind, salt: salt, hash: hash, iterations: iterations)
    }

    var isConfigured: Bool { record != nil }

    /// Keeps a new secret, which also forgets every failed attempt against the
    /// old one.
    func set(_ secret: String, as kind: Kind) async {
        var salt = Data(count: Self.saltBytes)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.saltBytes, $0.baseAddress!) }
        let hash = await Self.derive(secret, salt: salt, iterations: Self.iterations)

        defaults.set(kind.rawValue, forKey: Key.kind)
        defaults.set(salt, forKey: Key.salt)
        defaults.set(hash, forKey: Key.hash)
        defaults.set(Self.iterations, forKey: Key.iterations)
        resetAttempts()
    }

    func clear() {
        for key in [Key.kind, Key.salt, Key.hash, Key.iterations, Key.failed, Key.lockedUntil] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Checking

    /// The unlock: counts a failure, and refuses to even look while locked out.
    func verify(_ input: String) async -> Verdict {
        guard let record else { return .accepted }

        let waiting = lockoutRemaining
        if waiting > 0 { return .lockedOut(seconds: waiting) }

        if await Self.matches(input, record) {
            resetAttempts()
            return .accepted
        }

        let failed = defaults.integer(forKey: Key.failed) + 1
        guard failed % Self.attemptsPerLockout == 0 else {
            defaults.set(failed, forKey: Key.failed)
            defaults.set(0.0, forKey: Key.lockedUntil)
            return .refused(attemptsLeft: Self.attemptsPerLockout - failed % Self.attemptsPerLockout)
        }

        // 30 s, 60 s, 120 s… up to fifteen minutes, as on Android.
        let lockout = failed / Self.attemptsPerLockout
        let seconds = min(Self.baseLockoutSeconds << min(lockout - 1, 20), Self.maximumLockoutSeconds)
        defaults.set(failed, forKey: Key.failed)
        defaults.set(now().addingTimeInterval(TimeInterval(seconds)).timeIntervalSince1970, forKey: Key.lockedUntil)
        return .lockedOut(seconds: seconds)
    }

    /// A plain match, with no effect on the attempts. For confirming the current
    /// secret before changing it: the app is already unlocked there, so it must
    /// not touch the counters that guard the unlock screen.
    func check(_ input: String) async -> Bool {
        guard let record else { return false }
        return await Self.matches(input, record)
    }

    /// Whole seconds until another attempt is allowed, 0 when one is.
    var lockoutRemaining: Int {
        let until = defaults.double(forKey: Key.lockedUntil)
        let remaining = until - now().timeIntervalSince1970
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    private func resetAttempts() {
        defaults.set(0, forKey: Key.failed)
        defaults.set(0.0, forKey: Key.lockedUntil)
    }

    // MARK: - The one expensive thing

    private static func matches(_ input: String, _ record: Record) async -> Bool {
        let actual = await derive(input, salt: record.salt, iterations: record.iterations)
        return constantTimeEqual(actual, record.hash)
    }

    /// PBKDF2-HMAC-SHA256, 256 bits.
    ///
    /// Off the main thread, always: two hundred thousand rounds is a noticeable
    /// fraction of a second on an old phone, and that is the point of them — it
    /// is what makes guessing a four-digit PIN from a copied hash slow. An audit
    /// on 29/10/2026 found the key import doing its own KDF on the main actor;
    /// this one does not start out that way.
    static func derive(_ secret: String, salt: Data, iterations: Int) async -> Data {
        await Task.detached(priority: .userInitiated) {
            var derived = Data(count: keyBytes)
            let password = Array(secret.utf8)
            let status = derived.withUnsafeMutableBytes { output in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.map { CChar(bitPattern: $0) }, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(clamping: iterations),
                        output.bindMemory(to: UInt8.self).baseAddress, keyBytes
                    )
                }
            }
            // A failure here is a programming error — the arguments are ours —
            // and an empty result can never match a stored hash.
            return Int(status) == kCCSuccess ? derived : Data()
        }.value
    }

    /// Every byte compared, whatever the first difference: how long a refusal
    /// takes must not say how close the guess was.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: - The numbers, all of them Android's

    static let pinMinimum = 4
    static let pinMaximum = 12
    static let passphraseMinimum = 4

    static let iterations = 210_000
    static let attemptsPerLockout = 5
    static let baseLockoutSeconds = 30
    static let maximumLockoutSeconds = 15 * 60

    private static let saltBytes = 16
    private static let keyBytes = 32

    /// Android's key names, though nothing carries them between the apps: the
    /// backup deliberately leaves them out.
    private enum Key {
        static let kind = "lock_secret_kind"
        static let salt = "lock_secret_salt"
        static let hash = "lock_secret_hash"
        static let iterations = "lock_secret_iterations"
        static let failed = "lock_failed_attempts"
        static let lockedUntil = "lock_lockout_until"
    }
}

private extension Character {
    /// `0`–`9` only. `isNumber` would let in Arabic-Indic digits, fractions and
    /// Roman numerals, none of which the number pad types.
    var isASCIIDigit: Bool { isASCII && isNumber }
}
