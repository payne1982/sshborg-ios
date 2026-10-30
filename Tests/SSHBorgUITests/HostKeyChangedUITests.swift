// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// What a host whose key is not the saved one looks like.
///
/// Since 30/10/2026 it is not the calm question a new host gets: a red, bold
/// line that this is not the saved key, what that can mean, and an accept
/// button that says it will replace the key — Android's wording, which arrived
/// the same day after a user reported a changed key looking like nothing at all.
///
/// Needs a host labelled `test-host-changed` that points at the live test server
/// with a key saved that the server does not have; BUILD-MAC.md has the one-line
/// update that makes it. It answers **Reject**, so the wrong key stays saved and
/// the fixture is still a fixture next time.
final class HostKeyChangedUITests: XCTestCase {

    func testAChangedKeySaysSoBeforeAnythingElse() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let row = app.staticTexts["test-host-changed"].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled 'test-host-changed' — seed one with a key the server does not have")
        }
        row.tap()

        let title = app.staticTexts["Host key changed"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "a changed key did not say so:\n\(app.debugDescription)")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not the key saved for this host'"))
                .firstMatch.exists,
            "the warning line is missing"
        )
        XCTAssertTrue(app.buttons["Replace key"].firstMatch.exists, "the accept button does not say what it does")
        // A fingerprint is not an error, whatever colour the panel is.
        XCTAssertFalse(app.buttons["Copy error"].firstMatch.exists, "the fingerprint is offered as an error to copy")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "hostkey-changed"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Reject"].firstMatch.tap()
    }
}
