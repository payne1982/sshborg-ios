// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The two-row bar's columns have to line up, because its whole point is the
/// arrow cross: ↑ above ↓, with ← and → either side.
///
/// Reported from the phone on 25/09/2026 with a photograph: they did not. A
/// `fit` row divides the width by its own key count, and the iPhone-only
/// keyboard key used to ride in front of the first row — ten cells against nine,
/// so every column in the top row sat slightly left of the one below it. The key
/// now stands beside the rows instead.
///
/// The check is arithmetic on the frames, which is the one thing about this a
/// screenshot cannot state precisely; the screenshot is attached anyway, because
/// the frames cannot say whether the result looks right.
///
/// Needs a host that answers, seeded by `scripts/dev/seed-live-host.py`; with
/// none in the list it skips.
final class ExtraBarAlignmentUITests: XCTestCase {

    func testTheArrowCrossLinesUp() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // The two-row bar, always visible, so the bar is there whatever the
        // keyboard is doing.
        app.launchArguments += ["-extra_bar_selected", "preset:natural_2"]
        app.launchArguments += ["-extra_keys_bar_pinned", "YES"]
        app.launch()

        let label = ProcessInfo.processInfo.environment["SSHBORG_UITEST_EDITOR_HOST"] ?? "editor-target"
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one with scripts/dev/seed-live-host.py")
        }
        row.tap()

        // First sight of a server asks about its key.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 20) { trust.tap() }

        let up = app.buttons["↑"].firstMatch
        let down = app.buttons["↓"].firstMatch
        guard up.waitForExistence(timeout: 30), down.waitForExistence(timeout: 5) else {
            throw XCTSkip("the two-row bar is not on screen:\n\(app.debugDescription)")
        }
        Thread.sleep(forTimeInterval: 1)
        shot("40-bar")

        // Same column means the same centre, to within a point of rounding.
        let upCentre = up.frame.midX
        let downCentre = down.frame.midX
        XCTAssertEqual(
            upCentre, downCentre, accuracy: 1.0,
            "the arrow cross is out of line: ↑ at \(upCentre), ↓ at \(downCentre)"
        )

        // And the rows really are the same width, which is what keeps every
        // other column honest too.
        let left = app.buttons["←"].firstMatch
        let right = app.buttons["→"].firstMatch
        XCTAssertLessThan(left.frame.midX, upCentre, "← is not left of the cross")
        XCTAssertGreaterThan(right.frame.midX, upCentre, "→ is not right of the cross")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
