// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Photographs the host list order (#16): the setting that chooses it, and the
/// two entries it adds to the row menus.
///
/// The unit tests pin the arithmetic and can say nothing about whether the
/// picker's value fits the row it shares with the title, or whether "Move up"
/// reads as disabled at the top of a section rather than merely pale. Those
/// need eyes, and this is how eyes get pointed at them from here.
///
/// It has already earned its keep: the row first carried a two-line label, and
/// the value had nowhere to go — it wrapped onto a third line on the left.
/// Nothing in the code said so.
///
/// Neither test leaves anything behind on the simulator. The one that needs the
/// manual order passes it as a launch argument rather than committing it
/// through Settings, and the one that opens the picker comes back out without
/// choosing.
final class HostOrderUITests: XCTestCase {

    private var app: XCUIApplication!

    private func launch(extraArguments: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No finger can answer Face ID; see AppLock.shouldLock.
        app.launchArguments += ["-SSHBorgDisableLock"]
        // Plain preference overrides, not test hooks: both panels otherwise sit
        // over the screens these tests are looking at.
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launchArguments += extraArguments
        app.launch()
    }

    /// A row built from a title and a subtitle is one element labelled with the
    /// two joined, so an exact match finds nothing. This is the lesson the
    /// extra-bar suite paid for once already.
    private func button(startingWith text: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", text))
            .firstMatch
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTheOrderSettingIsLegible() throws {
        launch()

        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "no Settings button in the toolbar")
        gear.tap()

        // Swiping until it arrives rather than a fixed number of times: how far
        // a swipe carries depends on the momentum the simulator gives it.
        let row = button(startingWith: "Host list order")
        var swipes = 0
        while !row.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.isHittable, "the order row never came on screen:\n\(app.debugDescription)")
        attach("40-settings-order-row")

        row.tap()
        let manual = app.buttons["Manual"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "the options did not open:\n\(app.debugDescription)")
        // Existing is not the same as finished moving, hence the wait.
        //
        // The shot is still worth less than it looks: a menu lives in a window
        // of its own and `XCUIScreen.screenshot()` does not composite its
        // panel, so the four labels come out floating over the settings behind
        // them. That is the camera, not the layout — the same artifact
        // ContextMenuLookUITests was written about. Read this attachment for
        // the labels and their order, and nothing else.
        Thread.sleep(forTimeInterval: 1.5)
        attach("41-order-options")

        for expected in ["Alphabetical", "Recently used", "Most used", "Manual"] {
            XCTAssertTrue(app.buttons[expected].exists, "no \"\(expected)\" among the options")
        }

        // Leave without choosing: this simulator is shared, and a test has no
        // business rearranging somebody's host list. Tapping the navigation bar
        // dismisses the menu rather than picking from it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func testTheMoveEntriesAppearOnlyInTheManualOrder() throws {
        // Set through the argument domain, so it lives as long as the launch
        // and no longer.
        launch(extraArguments: ["-host_sort_mode", "3"])

        if app.staticTexts["No hosts yet."].waitForExistence(timeout: 15) {
            throw XCTSkip("no host in the list to long-press")
        }
        let row = app.staticTexts.matching(NSPredicate(format: "label != %@", "SSHBorg")).firstMatch
        guard row.waitForExistence(timeout: 5) else {
            throw XCTSkip("no host in the list to long-press")
        }

        row.press(forDuration: 1.5)
        Thread.sleep(forTimeInterval: 2)
        attach("42-host-menu-manual-order")

        XCTAssertTrue(app.buttons["Move up"].exists, "no Move up in the menu:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Move down"].exists, "no Move down in the menu")
        // Still the whole menu, not a replacement for it.
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    /// The other half of the rule. In every mode but manual the arrows would
    /// appear to do nothing, because the next redraw sorts the list back — so
    /// they are not offered at all.
    func testTheMoveEntriesAreAbsentInEveryOtherOrder() throws {
        launch(extraArguments: ["-host_sort_mode", "0"])

        if app.staticTexts["No hosts yet."].waitForExistence(timeout: 15) {
            throw XCTSkip("no host in the list to long-press")
        }
        let row = app.staticTexts.matching(NSPredicate(format: "label != %@", "SSHBorg")).firstMatch
        guard row.waitForExistence(timeout: 5) else {
            throw XCTSkip("no host in the list to long-press")
        }

        row.press(forDuration: 1.5)
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(app.buttons["Edit"].exists, "the menu did not open:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Move up"].exists, "Move up is offered outside the manual order")
        XCTAssertFalse(app.buttons["Move down"].exists, "Move down is offered outside the manual order")
    }
}
