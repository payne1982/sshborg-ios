// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Walks the new extra-key-bar screens and photographs each one.
///
/// The unit tests pin every index the editor moves, and none of them can say
/// whether the thing is *legible*: whether nine stretched keys fit a phone
/// without the labels turning to dots, whether the selection toolbar reads as
/// seven buttons rather than a grey stripe. Those questions need eyes, and this
/// is how eyes get pointed at them without a device in hand.
final class ExtraBarEditorUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()
    }

    /// Matches on a label that *starts with* the text, because a row built from
    /// a title and a subtitle is exposed as one element whose label is the two
    /// joined — "Extra key bar layout, In use: Standard". Querying for the
    /// title alone finds nothing, which is how this test failed first.
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

    /// Settings → Extra key bar layout → duplicate `preset` → the editor.
    private func openEditor(duplicating preset: String) {
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button in the toolbar")
        gear.tap()

        let layoutRow = button(startingWith: "Extra key bar layout")
        var swipes = 0
        while !layoutRow.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        layoutRow.tap()

        let row = button(startingWith: preset)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(preset) is not listed:\n\(app.debugDescription)")
        row.press(forDuration: 1.2)
        let duplicate = app.buttons["Duplicate"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "the row menu has no Duplicate")
        duplicate.tap()
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10), "the editor did not open")
    }

    /// A drag that starts on a key scrolls the row and presses nothing.
    ///
    /// Reported from the phone on 14/09/2026: every key fired the moment a finger
    /// landed and held on to the touch, so the scrolling bar only moved when the
    /// drag began in the one-point gap between two keys. The editor's preview is
    /// the very same bar, and there a press selects the key — which the toolbar's
    /// Remove button makes visible — so it can be asked without a live session.
    func testDraggingAcrossTheKeysScrollsInsteadOfPressing() throws {
        openEditor(duplicating: "Standard")

        let esc = app.buttons["ESC"].firstMatch
        XCTAssertTrue(esc.waitForExistence(timeout: 5), "no ESC key in the preview:\n\(app.debugDescription)")
        let remove = app.buttons["Remove key"].firstMatch
        XCTAssertFalse(remove.isEnabled, "a key is selected before anything was touched")

        let before = esc.frame.minX
        let start = esc.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        attach("10-preview-after-drag")

        XCTAssertLessThan(esc.frame.minX, before - 60, "the row did not scroll under a drag that began on a key")
        XCTAssertFalse(remove.isEnabled, "the drag pressed the key it started on")

        // And a plain tap still presses: a key that did nothing at all would pass
        // the two assertions above just as well.
        let candidates = ["F1", "F2", "F3", "F4", "F5", "Del", "PgDn", "PgUp", "End", "Home"]
        guard let visible = candidates.map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) else {
            XCTFail("no key on screen to tap after the scroll:\n\(app.debugDescription)")
            return
        }
        visible.tap()
        XCTAssertTrue(remove.waitForEnabled(timeout: 3), "a tap on \(visible.label) did not select it")
    }

    func testTheBarListAndTheEditorAreLegible() throws {
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "no Settings button in the toolbar")
        gear.tap()

        // The row sits at the bottom of the Terminal section, so it needs
        // scrolling to. Swiping until it arrives rather than a fixed number of
        // times: how far a swipe carries depends on the momentum the simulator
        // gives it, which is a lesson this suite already paid for once.
        let layoutRow = button(startingWith: "Extra key bar layout")
        var swipes = 0
        while !layoutRow.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(layoutRow.isHittable, "the extra-bar row never came on screen:\n\(app.debugDescription)")
        attach("01-settings-row")

        layoutRow.tap()
        XCTAssertTrue(
            app.navigationBars["Extra key bars"].firstMatch.waitForExistence(timeout: 10),
            "the bar list did not open"
        )

        // "Your bars" comes first, and every run of this suite duplicates a
        // preset and leaves the copy behind. On 14/09/2026 a dozen of them had
        // piled up on the VM simulator, pushing the Presets header off the
        // screen, where the list does not build it — and the assertion read
        // "the bar list did not open" over a list that was plainly open.
        let presets = app.staticTexts["Presets"].firstMatch
        swipes = 0
        while !(presets.exists && presets.isHittable) && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(presets.exists, "no Presets section in the bar list:\n\(app.debugDescription)")
        attach("02-bar-list")

        // Duplicating a preset is the documented way to start a bar of your
        // own, so it is also the way into the editor with something in it.
        let twoRow = button(startingWith: "Natural ×2")
        XCTAssertTrue(twoRow.waitForExistence(timeout: 5), "the two-row preset is not listed:\n\(app.debugDescription)")
        twoRow.press(forDuration: 1.2)

        let duplicate = app.buttons["Duplicate"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "the row menu has no Duplicate")
        attach("03-row-menu")
        duplicate.tap()

        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "the editor did not open:\n\(app.debugDescription)")
        attach("04-editor")

        // A key selected, so the toolbar is in the state it spends its life in:
        // the highlight has to be visible against the accent colour, and the
        // seven buttons have to look enabled or disabled accordingly.
        let escKey = app.buttons["ESC"].firstMatch
        if escKey.waitForExistence(timeout: 5) {
            escKey.tap()
            attach("05-editor-key-selected")
        }

        // And the catalogue, which is the screen with the most in it.
        let addKey = app.buttons["Add key"].firstMatch
        XCTAssertTrue(addKey.waitForExistence(timeout: 5), "no Add key button:\n\(app.debugDescription)")
        addKey.tap()

        let picker = app.staticTexts["Navigation"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the key catalogue did not open")
        attach("06-key-catalogue")

        app.swipeUp()
        attach("07-key-catalogue-custom-text")
    }
}

private extension XCUIElement {

    /// `isEnabled` read once is a snapshot; a selection lands a moment after the
    /// tap that made it.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return isEnabled
    }
}
