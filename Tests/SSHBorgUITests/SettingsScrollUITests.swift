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

        // Measure whether the content moved, which is the actual question.
        //
        // The first version of this looked for the last row and asked whether it
        // was `isHittable`. That reported a screen that does not scroll while the
        // attached screenshot plainly showed it scrolling: the row is a
        // `LabeledContent`, whose label is not exposed as a hittable element of
        // its own. The test was wrong, not the app — so it now watches a control
        // it can actually see move.
        let topRow = app.switches.firstMatch
        XCTAssertTrue(topRow.exists, "expected a control at the top of the form")
        let before = topRow.frame.origin.y

        app.swipeUp()
        app.swipeUp()
        attach("03-settings-after-swipe")

        // Scrolled far enough and the first row is gone from the tree entirely,
        // which is as good an answer as a smaller y.
        let moved = !topRow.exists || topRow.frame.origin.y < before - 50

        XCTAssertTrue(
            moved,
            """
            The settings form did not move under two swipes. First control was \
            at y=\(before) and is now \
            \(topRow.exists ? "at y=\(topRow.frame.origin.y)" : "gone").
            """
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
