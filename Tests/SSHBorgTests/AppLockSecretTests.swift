// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The app's own PIN or passphrase: what it accepts, how it is kept, and how it
/// throttles — Android's `AppLockManager` number for number.
final class AppLockSecretTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeSecret(_ clock: Clock = Clock()) -> AppLockSecret {
        AppLockSecret(defaults: UserDefaults(suiteName: "secret.\(UUID().uuidString)")!, now: { clock.now })
    }

    // MARK: - The derivation

    /// PBKDF2-HMAC-SHA256 against the standard vectors, computed independently
    /// with Python's `hashlib.pbkdf2_hmac` rather than remembered.
    func testTheDerivationIsStandardPBKDF2() async {
        let salt = Data("salt".utf8)
        let one = await AppLockSecret.derive("password", salt: salt, iterations: 1)
        let two = await AppLockSecret.derive("password", salt: salt, iterations: 2)
        XCTAssertEqual(one.hex, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(two.hex, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    func testTheComparisonLooksAtEveryByteAndNothingElse() {
        XCTAssertTrue(AppLockSecret.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(AppLockSecret.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(AppLockSecret.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
        XCTAssertFalse(AppLockSecret.constantTimeEqual(Data(), Data()), "two empty hashes matched")
    }

    // MARK: - What a secret may be

    func testAPinIsFourToTwelveDigits() {
        XCTAssertFalse(AppLockSecret.isAcceptable("123", as: .pin))
        XCTAssertTrue(AppLockSecret.isAcceptable("1234", as: .pin))
        XCTAssertTrue(AppLockSecret.isAcceptable("123456789012", as: .pin))
        XCTAssertFalse(AppLockSecret.isAcceptable("1234567890123", as: .pin))
        XCTAssertFalse(AppLockSecret.isAcceptable("12a4", as: .pin))
        XCTAssertFalse(AppLockSecret.isAcceptable("١٢٣٤", as: .pin), "Arabic-Indic digits are not what the pad types")
        XCTAssertTrue(AppLockSecret.isAcceptable("abcd", as: .passphrase))
        XCTAssertFalse(AppLockSecret.isAcceptable("abc", as: .passphrase))
    }

    // MARK: - Keeping it

    /// Only the salt, the hash and the rounds are kept, never the secret.
    func testTheSecretItselfIsNeverStored() async {
        let suite = "secret.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secret = AppLockSecret(defaults: defaults)
        await secret.set("4711", as: .pin)

        XCTAssertEqual(secret.record?.kind, .pin)
        XCTAssertEqual(secret.record?.iterations, AppLockSecret.iterations)
        for (_, value) in defaults.persistentDomain(forName: suite) ?? [:] {
            XCTAssertNotEqual(value as? String, "4711", "the PIN was stored as itself")
            if let data = value as? Data {
                XCTAssertNil(data.range(of: Data("4711".utf8)), "the PIN was stored inside something")
            }
        }

        secret.clear()
        XCTAssertFalse(secret.isConfigured)
    }

    // MARK: - Throttling

    /// Five wrong, then thirty seconds; five more, a minute. A right answer
    /// resets the count. During a lockout nothing is even looked at.
    func testWrongAnswersLockOutOnAndroidsSchedule() async {
        let clock = Clock()
        let secret = makeSecret(clock)
        await secret.set("4711", as: .pin)

        for left in stride(from: 4, through: 1, by: -1) {
            let verdict = await secret.verify("0000")
            XCTAssertEqual(verdict, .refused(attemptsLeft: left))
        }
        var verdict = await secret.verify("0000")
        XCTAssertEqual(verdict, .lockedOut(seconds: 30))

        // Even the right answer is not looked at during a lockout.
        verdict = await secret.verify("4711")
        XCTAssertEqual(verdict, .lockedOut(seconds: 30))

        clock.now += 31
        for _ in 0..<4 { _ = await secret.verify("0000") }
        verdict = await secret.verify("0000")
        XCTAssertEqual(verdict, .lockedOut(seconds: 60), "the second lockout did not double")

        clock.now += 61
        verdict = await secret.verify("4711")
        XCTAssertEqual(verdict, .accepted)
        verdict = await secret.verify("0000")
        XCTAssertEqual(verdict, .refused(attemptsLeft: 4), "a right answer did not reset the count")
    }

    /// Confirming the current secret in Settings counts nothing: the app is
    /// already unlocked there, and the attempts guard the unlock screen.
    func testConfirmingInSettingsDoesNotSpendAttempts() async {
        let secret = makeSecret()
        await secret.set("correct horse", as: .passphrase)

        for _ in 0..<10 {
            let matched = await secret.check("wrong")
            XCTAssertFalse(matched)
        }
        let verdict = await secret.verify("wrong")
        XCTAssertEqual(verdict, .refused(attemptsLeft: 4), "the checks in Settings were counted")
        let right = await secret.check("correct horse")
        XCTAssertTrue(right)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
