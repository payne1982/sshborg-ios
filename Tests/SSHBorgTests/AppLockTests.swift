// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The gate that decides whether the app shows its contents.
///
/// It existed as a setting and nothing else until 14/08/2026: the mode and the
/// timeout were both stored, and nothing ever read them to lock anything. These
/// pin the decisions that do not need a face to verify — when the cover goes up,
/// and when the timeout lets someone back in without being asked.
@MainActor
final class AppLockTests: XCTestCase {

    private func preferences(mode: AppPreferences.LockMode, timeout: Int = 60) -> AppPreferences {
        let defaults = UserDefaults(suiteName: "applock.\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        preferences.lockMode = mode
        preferences.lockTimeoutSeconds = timeout
        return preferences
    }

    func testWithoutALockTheAppStartsOpen() {
        let lock = AppLock(preferences: preferences(mode: .none))
        XCTAssertFalse(lock.isLocked)
    }

    /// A cold launch always asks, however long the timeout: there is no earlier
    /// authentication for it to be measured against.
    func testWithALockTheAppStartsLocked() {
        for mode in [AppPreferences.LockMode.biometric, .device] {
            let lock = AppLock(preferences: preferences(mode: mode, timeout: 1800))
            XCTAssertTrue(lock.isLocked, "mode \(mode) started unlocked")
        }
    }

    /// The cover has to be up before the app leaves the screen, or the app
    /// switcher photographs the host list.
    func testLeavingCoversTheApp() {
        let lock = AppLock(preferences: preferences(mode: .biometric))
        lock.willResignActive()
        XCTAssertTrue(lock.isLocked)
    }

    func testWithoutALockLeavingCoversNothing() {
        let lock = AppLock(preferences: preferences(mode: .none))
        lock.willResignActive()
        XCTAssertFalse(lock.isLocked)
    }

    /// Coming back with the lock switched off must open, whatever state the
    /// cover was left in — otherwise turning the lock off leaves the app stuck
    /// behind a gate that no longer exists.
    func testComingBackWithoutALockOpens() async {
        let lock = AppLock(preferences: preferences(mode: .none))
        lock.willResignActive()
        await lock.didBecomeActive()
        XCTAssertFalse(lock.isLocked)
    }

    func testSwitchingTheLockOffUnlocksImmediately() {
        let preferences = preferences(mode: .biometric)
        let lock = AppLock(preferences: preferences)
        XCTAssertTrue(lock.isLocked)

        preferences.lockMode = .none
        lock.lockModeChanged()

        XCTAssertFalse(lock.isLocked, "the app stayed locked behind a setting that says it is not")
    }

    /// Switching it *on* does not lock what is already open. The user is holding
    /// the phone, having just proved who they are by unlocking it — the gate is
    /// for the next time they come back.
    func testSwitchingTheLockOnDoesNotLockTheAppUnderneath() {
        let preferences = preferences(mode: .none)
        let lock = AppLock(preferences: preferences)
        XCTAssertFalse(lock.isLocked)

        preferences.lockMode = .biometric
        lock.lockModeChanged()

        XCTAssertFalse(lock.isLocked)
    }
}
