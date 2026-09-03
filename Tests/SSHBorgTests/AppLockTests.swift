// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import UIKit

@testable import SSHBorg

/// The gate that decides whether the app shows its contents.
///
/// It existed as a setting and nothing else until 14/08/2026: the mode and the
/// timeout were both stored, and nothing ever read them to lock anything. These
/// pin the decisions that do not need a face to verify — when the cover goes up,
/// and when the timeout lets someone back in without being asked.
@MainActor
final class AppLockTests: XCTestCase {

    /// Counts the prompts and answers them without a face.
    private final class Asker {
        var count = 0
        var answer: Bool

        init(answer: Bool) { self.answer = answer }

        func ask(_ mode: AppPreferences.LockMode) async -> Bool {
            count += 1
            return answer
        }
    }

    private func makeLock(
        mode: AppPreferences.LockMode,
        timeout: Int = 60,
        answer: Bool = true,
        possible: Bool = true
    ) -> (AppLock, Asker) {
        let asker = Asker(answer: answer)
        let lock = AppLock(
            preferences: preferences(mode: mode, timeout: timeout),
            ask: { await asker.ask($0) },
            isAuthenticationPossible: { possible },
            center: NotificationCenter()
        )
        return (lock, asker)
    }

    private func preferences(mode: AppPreferences.LockMode, timeout: Int = 60) -> AppPreferences {
        let defaults = UserDefaults(suiteName: "applock.\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        preferences.lockMode = mode
        preferences.lockTimeoutSeconds = timeout
        return preferences
    }

    func testWithoutALockTheAppStartsOpen() {
        let lock = AppLock(preferences: preferences(mode: .none), center: NotificationCenter())
        XCTAssertFalse(lock.isLocked)
    }

    /// A cold launch always asks, however long the timeout: there is no earlier
    /// authentication for it to be measured against.
    func testWithALockTheAppStartsLocked() {
        for mode in [AppPreferences.LockMode.biometric, .device] {
            let lock = AppLock(preferences: preferences(mode: mode, timeout: 1800), center: NotificationCenter())
            XCTAssertTrue(lock.isLocked, "mode \(mode) started unlocked")
        }
    }

    /// UIKit's own notification raises the cover, not just the scene phase.
    ///
    /// Reported from the device on 03/09/2026: leaving the app sometimes showed
    /// the host list for a moment first. SwiftUI's `scenePhase` needs a render
    /// pass that is not guaranteed to land before iOS photographs the app, so
    /// the lock listens for `willResignActiveNotification` too — delivered
    /// synchronously during the transition.
    func testTheSystemNotificationAloneRaisesTheCover() {
        let center = NotificationCenter()
        let lock = AppLock(
            preferences: preferences(mode: .biometric),
            ask: { _ in true },
            isAuthenticationPossible: { true },
            center: center
        )
        // Simulate a cold start that got as far as unlocking.
        lock.willResignActive()
        XCTAssertTrue(lock.isLocked)

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(lock.isLocked, "the notification did not raise the cover")
    }

    /// Both paths lead to the same flag, so arriving twice must be harmless.
    func testBothPathsTogetherAreIdempotent() {
        let center = NotificationCenter()
        let lock = AppLock(
            preferences: preferences(mode: .biometric),
            ask: { _ in true },
            isAuthenticationPossible: { true },
            center: center
        )
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        lock.willResignActive()
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(lock.isLocked)
    }

    /// With no lock configured, the notification must not raise anything —
    /// a cover nobody asked for is a wall with no door behind it.
    func testTheNotificationCoversNothingWithoutALock() {
        let center = NotificationCenter()
        let lock = AppLock(
            preferences: preferences(mode: .none),
            ask: { _ in true },
            isAuthenticationPossible: { true },
            center: center
        )
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(lock.isLocked)
    }

    /// The cover has to be up before the app leaves the screen, or the app
    /// switcher photographs the host list.
    func testLeavingCoversTheApp() {
        let lock = AppLock(preferences: preferences(mode: .biometric), center: NotificationCenter())
        lock.willResignActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testWithoutALockLeavingCoversNothing() {
        let lock = AppLock(preferences: preferences(mode: .none), center: NotificationCenter())
        lock.willResignActive()
        XCTAssertFalse(lock.isLocked)
    }

    /// Coming back with the lock switched off must open, whatever state the
    /// cover was left in — otherwise turning the lock off leaves the app stuck
    /// behind a gate that no longer exists.
    func testComingBackWithoutALockOpens() async {
        let lock = AppLock(preferences: preferences(mode: .none), center: NotificationCenter())
        lock.willResignActive()
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
    }

    func testSwitchingTheLockOffUnlocksImmediately() {
        let preferences = preferences(mode: .biometric)
        let lock = AppLock(preferences: preferences, center: NotificationCenter())
        XCTAssertTrue(lock.isLocked)

        preferences.lockMode = .none
        lock.lockModeChanged()

        XCTAssertFalse(lock.isLocked, "the app stayed locked behind a setting that says it is not")
    }

    /// Coming back active while nothing is locked must not raise a prompt.
    ///
    /// This is the shape of the loop that got reported: the system's prompt
    /// makes the app inactive while it is on screen and active again when it
    /// leaves, and that second transition arrives after the authentication call
    /// has already returned. Treated as a fresh arrival it asked again, over a
    /// host list that was by then fully visible behind it.
    func testComingBackWhileUnlockedAsksNothing() async {
        let (lock, asker) = makeLock(mode: .biometric, timeout: 0)

        // The cold launch, answered.
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(asker.count, 1)

        // The system's prompt leaving the screen makes the app active again.
        await lock.didBecomeActive()

        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(asker.count, 1, "it asked to be let into a room it had opened")
    }

    /// A refusal must not be answered by asking again: every dismissal makes the
    /// app active once more, and the user would never get out of it.
    func testARefusalIsNotFollowedByAnotherPrompt() async {
        let (lock, asker) = makeLock(mode: .biometric, timeout: 0, answer: false)

        await lock.didBecomeActive()
        await lock.didBecomeActive()

        XCTAssertTrue(lock.isLocked, "a refusal let the app through")
        XCTAssertEqual(asker.count, 1, "the prompt came back by itself after a refusal")
    }

    /// The button on the cover, which is the way back after a refusal.
    func testTheRetryButtonAsksAgain() async {
        let (lock, asker) = makeLock(mode: .biometric, timeout: 0, answer: false)
        await lock.didBecomeActive()
        XCTAssertTrue(lock.isLocked)

        asker.answer = true
        await lock.authenticate()

        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(asker.count, 2)
    }

    /// Coming back inside the timeout lets you through without asking.
    func testReturningInsideTheTimeoutDoesNotAsk() async {
        let (lock, asker) = makeLock(mode: .biometric, timeout: 900)
        await lock.didBecomeActive()
        XCTAssertEqual(asker.count, 1)

        lock.willResignActive()
        XCTAssertTrue(lock.isLocked, "the cover did not go up on the way out")
        await lock.didBecomeActive()

        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(asker.count, 1, "it asked again inside its own timeout")
    }

    /// And coming back after it has expired does ask.
    func testReturningAfterTheTimeoutAsks() async {
        let (lock, asker) = makeLock(mode: .biometric, timeout: 0)
        await lock.didBecomeActive()
        XCTAssertEqual(asker.count, 1)

        lock.willResignActive()
        await lock.didBecomeActive()

        XCTAssertEqual(asker.count, 2, "a real absence went unchallenged")
    }

    /// With nothing on the device able to answer, the app must not lock at all:
    /// a cover over a prompt that can only fail shuts the owner out for good.
    func testNothingLocksWhenNothingCanUnlock() async {
        let (lock, asker) = makeLock(mode: .biometric, possible: false)

        XCTAssertFalse(lock.isLocked)
        lock.willResignActive()
        XCTAssertFalse(lock.isLocked)
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(asker.count, 0)
    }

    /// Switching it *on* does not lock what is already open. The user is holding
    /// the phone, having just proved who they are by unlocking it — the gate is
    /// for the next time they come back.
    func testSwitchingTheLockOnDoesNotLockTheAppUnderneath() {
        let preferences = preferences(mode: .none)
        let lock = AppLock(preferences: preferences, center: NotificationCenter())
        XCTAssertFalse(lock.isLocked)

        preferences.lockMode = .biometric
        lock.lockModeChanged()

        XCTAssertFalse(lock.isLocked)
    }
}
