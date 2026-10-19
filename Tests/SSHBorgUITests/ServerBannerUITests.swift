// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The server's message, on screen, above the field the password goes into.
///
/// `ServerBannerTests` proves the banner reaches the prompt; this is the half
/// that no assertion about a string can make — that it is actually drawn, that
/// it is above the field and not below it, and that sixty lines of policy
/// cannot push the field off the screen.
///
/// Needs a host seeded with **no password** whose server sends a banner, and
/// skips without one.
final class ServerBannerUITests: XCTestCase {

    private var hostLabel: String {
        ProcessInfo.processInfo.environment["SSHBORG_UITEST_BANNER_HOST"] ?? "test-host-banner"
    }

    func testTheBannerIsDrawnAboveThePasswordField() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let row = app.staticTexts[hostLabel].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(hostLabel)' — seed one with no password, on a server that sends a banner")
        }
        row.tap()

        // The key comes first now, and the banner only after it: nothing is read
        // from a server whose key has not been accepted.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 15) { trust.tap() }

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 30), "no password prompt:\n\(app.debugDescription)")

        let banner = app.scrollViews["server-banner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the banner was not drawn:\n\(app.debugDescription)")

        attach(named: "30-banner-above-the-password")

        XCTAssertLessThan(
            banner.frame.maxY, password.frame.minY,
            "the banner is below the field it is meant to be read before: \(banner.frame) vs \(password.frame)"
        )
        // A banner is a box and not the whole screen: the field, and the button
        // under it, have to stay reachable however much the server has to say.
        XCTAssertTrue(password.isHittable, "the banner pushed the password field out of reach")
        XCTAssertTrue(app.buttons["Connect"].firstMatch.isHittable, "the Connect button is not reachable")
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
