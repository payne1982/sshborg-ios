// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Reproduces "I add a host, connect, and see almost nothing".
///
/// Temporary, and pointed at whatever host is already in the app's database —
/// the harness seeds one before running this, so the test does not have to type
/// a form. It captures the screen and the accessibility tree, which together
/// answer the question the screenshot alone cannot: whether the terminal is
/// drawing nothing, or drawing something invisible, or never got past connecting.
final class TerminalConnectUITests: XCTestCase {

    func testConnectingToTheSeededHost() throws {
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

        // Skip rather than fail when the host is not there. This test looks at a
        // live connection, so it needs a host seeded into the database by hand —
        // which only ever happens on the machine someone is debugging on. Every
        // other credential-dependent test in the suite skips itself; this one
        // used to assert instead, and so reported a red failure on any machine
        // but the one it was written on. The label is overridable because the
        // seeded host is not called the same thing everywhere.
        let label = ProcessInfo.processInfo.environment["SSHBORG_UITEST_HOST_LABEL"] ?? "test-host"
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one to run this")
        }

        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "10-before-tap"
        before.lifetime = .keepAlways
        add(before)

        row.tap()
        Thread.sleep(forTimeInterval: 6)

        // First connection to a host raises the fingerprint prompt, which is
        // correct and is also why the terminal behind it is empty. Accept it so
        // the test can see what happens *after*.
        let accept = app.buttons["Trust"].firstMatch
        if accept.waitForExistence(timeout: 8) {
            let prompt = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            prompt.name = "10b-hostkey-prompt"
            prompt.lifetime = .keepAlways
            add(prompt)
            accept.tap()
        }

        // Long enough for the connection, the shell and a prompt to arrive.
        Thread.sleep(forTimeInterval: 12)

        // The terminal has to be first responder before anything can be typed
        // into it; without the tap, typeText fails with "neither element nor any
        // descendant has keyboard focus".
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal view on screen")
        terminal.tap()
        Thread.sleep(forTimeInterval: 2)

        let withKeyboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        withKeyboard.name = "10c-keyboard-up"
        withKeyboard.lifetime = .keepAlways
        add(withKeyboard)

        // Print the glyphs straight into the shell rather than relying on the
        // server having a themed prompt: Powerline separators, a Nerd Font icon,
        // and two of the media triangles the Android build patched in. Anything
        // the font lacks comes back as a tofu box, which a screenshot shows.
        // Octal byte escapes, not \\uXXXX: the login shell may not be running
        // under a UTF-8 locale, and zsh then refuses the codepoint outright with
        // "character not in range" — which looks exactly like a missing glyph
        // and is not. Raw bytes reach the terminal whatever the locale.
        //   E0B0 E0B2 = Powerline, F09B = Nerd, 23F4 23F8 23FA = the media
        //   triangles the Android build patched into this font.
        app.typeText("printf '\\356\\202\\260 \\356\\202\\262 \\357\\202\\233 \\342\\217\\264 \\342\\217\\270 \\342\\217\\272|\\n'\n")
        Thread.sleep(forTimeInterval: 4)

        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "11-terminal"
        after.lifetime = .keepAlways
        add(after)

        // The tree names every element the app exposes: an overlay that is up,
        // a password prompt, or a terminal with no accessible content at all.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "12-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)

        // Not an assertion about the outcome — this test exists to look, and a
        // failure here would hide the attachments behind a red line.
        print("ELEMENT COUNT: \(app.descendants(matching: .any).count)")
    }
}
