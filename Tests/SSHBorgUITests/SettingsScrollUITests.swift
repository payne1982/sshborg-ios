// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Drives the app the way a finger does, to answer questions no unit test can.
///
/// This exists because of a report that the settings screen does not scroll on
/// the simulator. Reading the code did not explain it — a `Form` scrolls by
/// itself — and "it looks fine to me" is not an answer when someone has the app
/// in front of them and it does not work. So this asks the running app.
///
/// It also captures the screens as attachments, which is the only way anyone has
/// seen most of this app: the unit tests never render a view.
final class SettingsScrollUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // English regardless of the machine, so the queries below can name
        // buttons in one language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No finger can answer Face ID; see AppLock.shouldLock.
        app.launchArguments += ["-SSHBorgDisableLock"]
        // Plain preference overrides, not test hooks: the privacy notice sits
        // over the app until it is accepted, and the security reminder arrives
        // a second and a half in. Every test here is looking at what is
        // underneath them.
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSettingsScreenScrolls() throws {
        attach("01-hosts")

        // The gear is a navigation link labelled with the settings title.
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button in the toolbar")
        gear.tap()

        let firstRow = app.staticTexts["Confirm exit"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "the settings screen did not open")
        attach("02-settings-top")

        // Whether the content moved is the question, and this test has answered
        // it wrongly three times. Each way is worth keeping, because each one
        // reported "the screen does not scroll" while its own attached
        // screenshot showed it scrolling.
        //
        // 1. It asked `isHittable` of the last row. That row is a
        //    `LabeledContent`, whose label is not exposed as a hittable element,
        //    so the answer was always no.
        // 2. It took `app.switches.firstMatch` before scrolling and measured
        //    *it* again after. The query is re-resolved on every read, so
        //    afterwards it answered with whichever switch was first in the tree
        //    *then* — a different row, at a coincidentally similar height.
        // 3. It swiped a fixed two times. How far a swipe carries depends on the
        //    momentum the simulator gives it: enough on one machine, just short
        //    on another.
        //
        // Hence: a **named** element, one that is genuinely tappable — a
        // `Button`, not a label — and swiping until it arrives rather than a
        // fixed number of times. Import sits in the Backup section, far enough
        // down to be off screen at the top.
        let bottomRow = app.buttons["Import"].firstMatch
        XCTAssertFalse(bottomRow.isHittable, "the form was already at the bottom before scrolling")

        // The bound keeps a screen that genuinely cannot scroll from spinning.
        var swipes = 0
        while !bottomRow.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        attach("03-settings-after-swipe")

        XCTAssertTrue(
            bottomRow.isHittable,
            """
            The settings form did not move under \(swipes) swipes: the Import \
            button in the Backup section never came on screen.
            """
        )
        XCTAssertFalse(
            firstRow.isHittable,
            "the first row is still on screen, so nothing scrolled"
        )
    }

    /// The host list with no hosts shows a centred message and has nothing to
    /// scroll, which is correct and can look like a broken screen. This records
    /// the distinction so the two are not confused again.
    func testEmptyHostListHasNothingToScroll() throws {
        // Depends on device state, which is a weakness of the test rather than
        // of the app: anything that adds a host — including a seeded one used to
        // reproduce a report — makes the list non-empty and this meaningless.
        // Skipped rather than failed, so a red line always means a real defect.
        let empty = app.staticTexts["No hosts yet."].firstMatch
        try XCTSkipUnless(
            empty.waitForExistence(timeout: 10),
            "the host list is not empty on this simulator; nothing to assert about the empty state"
        )

        app.swipeUp()
        attach("04-hosts-after-swipe")

        XCTAssertTrue(
            empty.exists,
            "the empty-state message vanished on a swipe, which it should not"
        )
    }
}
