// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Photographs the host context menu, reported as "transparent and not very
/// pretty".
///
/// Appearance cannot be settled by reading code — the last two of these turned
/// out to be a translucent panel taking its colour from what was behind it — so
/// this opens the menu and attaches the screenshot.
final class ContextMenuLookUITests: XCTestCase {

    func testWhatTheHostContextMenuLooksLike() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No finger can answer Face ID; see AppLock.shouldLock.
        app.launchArguments += ["-SSHBorgDisableLock"]
        // Plain preference overrides, not test hooks: the privacy notice sits
        // over the app until it is accepted, and the security reminder arrives
        // a second and a half in. Every test here is looking at what is
        // underneath them.
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        // An empty list is not an empty screen: it draws "No hosts yet." and
        // "Tap + to add one.", and both are static text whose label is not the
        // title. Asking for "the first label that is not SSHBorg" therefore
        // found the placeholder, long-pressed it, and failed three assertions
        // about a menu that was never going to open — which is what happened
        // the moment the app's data was wiped. Rule out the empty state by
        // name first, so the test skips where it has nothing to look at.
        //
        // English is safe to hardcode here: the launch arguments above pin the
        // language, and the button labels below are matched the same way.
        if app.staticTexts["No hosts yet."].waitForExistence(timeout: 15) {
            throw XCTSkip("no host in the list to long-press")
        }

        let row = app.staticTexts.matching(NSPredicate(format: "label != %@", "SSHBorg")).firstMatch
        guard row.waitForExistence(timeout: 5) else {
            throw XCTSkip("no host in the list to long-press")
        }
        row.press(forDuration: 1.5)
        Thread.sleep(forTimeInterval: 2)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "30-host-context-menu"
        shot.lifetime = .keepAlways
        add(shot)

        print("=== MENU BUTTONS: \(app.buttons.allElementsBoundByIndex.map(\.label)) ===")

        // Ported from Android's host menu, in Android's order.
        XCTAssertTrue(app.buttons["Duplicate"].exists, "no Duplicate in the host menu")
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
    }
}
