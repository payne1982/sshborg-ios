// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Guards the password prompt, reported as "not visible — only a cursor in the
/// middle of the screen".
///
/// A screenshot alone could not say whether the panel was missing or merely
/// invisible, and those need opposite fixes; the accessibility tree could. It
/// showed a complete system alert — panel, title, message, field, both buttons —
/// at sensible coordinates, while 99.6% of the pixels inside its frame were pure
/// black. The same alert raised over the host list rendered normally (504
/// colours, light grey panel, black text), which ruled out the renderer and left
/// the backdrop: a system alert's panel is a translucent material, so over a
/// black terminal it goes black while its labels stay light-scheme black.
///
/// The prompt is now an in-layout `StatusOverlay` with an opaque background, so
/// what this test really watches is that the field and both buttons are on screen
/// and reachable without a system alert in the tree.
final class PasswordPromptUITests: XCTestCase {

    func testWhatThePasswordPromptActuallyIs() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let label = ProcessInfo.processInfo.environment["SSHBORG_UITEST_HOST_LABEL"] ?? "test-host-password"
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one to run this")
        }
        row.tap()

        // Long enough for the TCP connection and the auth negotiation to reach
        // the point where the server asks for a password.
        Thread.sleep(forTimeInterval: 15)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "20-password-prompt"
        shot.lifetime = .keepAlways
        add(shot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "21-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        // Printed as well as attached: the log is far quicker to read from a
        // remote shell than an .xcresult bundle.
        print("=== ALERTS: \(app.alerts.count) ===")
        print("=== SECURE FIELDS: \(app.secureTextFields.count) ===")
        print("=== BUTTONS: \(app.buttons.allElementsBoundByIndex.map(\.label)) ===")

        XCTAssertTrue(app.secureTextFields.firstMatch.exists, "no password field on screen")
        XCTAssertTrue(app.buttons["Connect"].exists, "no Connect button")
        XCTAssertTrue(app.buttons["Cancel"].exists, "no Cancel button")
        XCTAssertEqual(app.alerts.count, 0, "back on a system alert, which is invisible over the terminal")

        // The field has to take focus off the terminal by itself, or the prompt
        // is a dead end: a caret and no keyboard.
        XCTAssertGreaterThan(app.keyboards.count, 0, "the keyboard never came up for the password field")

        // Not asserted: the absence of the AutoFill "Passwords" key. It comes
        // with every SecureField and no supported API refuses it — see
        // `plainTextEntry()` for the three configurations that were measured.
    }

}
