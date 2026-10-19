// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// What the lock covers, and what it does not.
///
/// The cover is a SwiftUI view drawn over everything else, and drawing over a
/// view does not take its keyboard away: the terminal underneath stays first
/// responder, so the keyboard it raised can come straight back up on top of the
/// lock. Android had exactly this and fixed it in `a967af2` — "it appeared over
/// the lock screen" — which is why it is worth measuring here rather than
/// assuming iOS differs.
///
/// Needs the lock to be able to engage at all, which on a simulator means a
/// face enrolled and the match sent from outside; `BUILD-MAC.md` has the two
/// `notifyutil` lines. Without them this skips rather than passes quietly.
final class LockCoverUITests: XCTestCase {

    private var hostLabel: String {
        ProcessInfo.processInfo.environment["SSHBORG_UITEST_HOST_LABEL"] ?? "test-host"
    }

    func testTheKeyboardDoesNotComeBackOverTheLock() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // The lock on, and deliberately *without* `-SSHBorgDisableLock`: this is
        // the one test that wants the gate.
        app.launchArguments += ["-lock_mode", "1"]
        // And no grace period. The default is a minute away before the gate
        // comes back, which is right for a glance at a notification and useless
        // here: this test leaves for two seconds on purpose.
        app.launchArguments += ["-lock_timeout_seconds", "0"]
        app.launch()

        // The app starts locked; the face is matched from the host side.
        let row = app.staticTexts[hostLabel].firstMatch
        guard row.waitForExistence(timeout: 60) else {
            throw XCTSkip("the lock never opened — is a face enrolled and matched on this simulator?")
        }
        row.tap()

        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 15) { trust.tap() }

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the terminal screen did not open")

        // The keyboard comes up by itself once a session is up. If it does not,
        // there is nothing here to measure.
        guard app.keyboards.firstMatch.waitForExistence(timeout: 40) else {
            throw XCTSkip("no keyboard in the terminal — did the session come up?")
        }
        attach(named: "40-keyboard-in-the-terminal")

        // Away and back, which is what raises the cover.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        Thread.sleep(forTimeInterval: 5)

        attach(named: "41-back-to-the-lock")

        let unlock = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Unlock'")
        ).firstMatch
        guard unlock.waitForExistence(timeout: 10) else {
            throw XCTSkip("the lock did not come up on returning:\n\(app.debugDescription)")
        }

        XCTAssertEqual(
            app.keyboards.count, 0,
            "the keyboard is up over the lock screen:\n\(app.debugDescription)"
        )
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
