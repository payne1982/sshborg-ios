// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The app's own PIN, the whole way round, as somebody would do it: set it in
/// Settings, come back to a locked app and open it with the PIN, then take the
/// lock off again — which asks for the PIN first.
///
/// The only test of these screens: the unit tests cover what the PIN is and how
/// it throttles, and nothing there ever builds a view.
///
/// No `-SSHBorgDisableLock`, on purpose — this one wants the gate. Every other UI
/// test passes it, so a PIN left behind by a failed run cannot lock them; and
/// this one starts with `-SSHBorgResetLockSecret`, so it cannot lock itself.
final class AppLockSecretUITests: XCTestCase {

    private let pin = "4711"

    private func launch(resetting: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // No grace: the point is to come back locked.
        app.launchArguments += ["-lock_timeout_seconds", "0"]
        if resetting { app.launchArguments += ["-SSHBorgResetLockSecret"] }
        app.launch()
        return app
    }

    func testAPinIsSetUnlocksTheAppAndIsAskedForBeforeItIsRemoved() throws {
        var app = launch(resetting: true)

        // Settings, the lock picker, the fourth choice.
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button")
        gear.tap()

        let picker = lockPicker(in: app)
        XCTAssertTrue(picker.exists, "no App lock picker")
        picker.tap()
        let choice = app.buttons["PIN or passphrase"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "PIN is not among the lock modes")
        choice.tap()

        // The disclaimer comes first, because there is no recovering a forgotten one.
        let understood = app.buttons["I understand"].firstMatch
        XCTAssertTrue(understood.waitForExistence(timeout: 5), "no disclaimer before setting a PIN")
        attach(named: "10-disclaimer", app)
        understood.tap()

        let field = app.secureTextFields["lock-new-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the PIN sheet did not open")
        field.tap()
        field.typeText(pin)
        let confirm = app.secureTextFields["lock-confirm-field"].firstMatch
        confirm.tap()
        confirm.typeText(pin)
        attach(named: "20-set-pin", app)
        app.buttons["Save"].firstMatch.tap()

        let change = app.buttons["Change PIN or passphrase"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the PIN was not set")
        attach(named: "30-pin-set", app)

        // Away and back: locked, and the cover asks for the PIN rather than Face ID.
        app.terminate()
        app = launch(resetting: false)
        let entry = app.secureTextFields["lock-secret-field"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the app came back without asking for the PIN")
        attach(named: "40-locked", app)

        entry.tap()
        entry.typeText("0000")
        app.buttons["Unlock"].firstMatch.tap()
        let wrong = app.staticTexts["Incorrect — try again"].firstMatch
        XCTAssertTrue(wrong.waitForExistence(timeout: 10), "a wrong PIN was not refused out loud")

        entry.tap()
        entry.typeText(pin)
        app.buttons["Unlock"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10), "the right PIN did not open the app")

        // Taking the lock off asks for the PIN first, or the picker is the way round the lock.
        app.buttons["Settings"].firstMatch.tap()
        let picker2 = lockPicker(in: app)
        XCTAssertTrue(picker2.exists, "no App lock picker the second time")
        picker2.tap()
        app.buttons["None"].firstMatch.tap()

        let current = app.secureTextFields["lock-current-field"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "the lock came off without the PIN")
        current.tap()
        current.typeText(pin)
        app.buttons["Confirm"].firstMatch.tap()

        XCTAssertTrue(
            app.buttons["Change PIN or passphrase"].firstMatch.waitForNonExistence(timeout: 10),
            "the PIN mode is still on after confirming"
        )
        attach(named: "50-pin-removed", app)
    }

    /// The lock picker, scrolled to: Settings is a list, and a row that has
    /// never been on screen does not exist yet. Matched by the start of its
    /// label, because a menu picker reads as "App lock" followed by its value.
    ///
    /// The screen is waited for first: swiping before the push has landed
    /// scrolls the host list instead, which is how this lookup failed once and
    /// passed the next time.
    private func lockPicker(in app: XCUIApplication) -> XCUIElement {
        _ = app.staticTexts["Theme"].firstMatch.waitForExistence(timeout: 10)
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'App lock'")).firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<15 where !picker.exists {
            list.swipeUp(velocity: .slow)
        }
        return picker
    }

    private func attach(named name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
