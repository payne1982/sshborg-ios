// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// What a tap on a row does (#17).
///
/// It used to start a download, at any size, with no confirmation — the most
/// consequential thing the screen could do by accident, and the editor behind
/// the long press was unfindable. A tap on a file now opens that menu instead,
/// and the download icon at the end of the row is a real button rather than a
/// glyph standing for what the row would do. Android changed both together,
/// from one user's report, and this keeps the two apps answering a finger the
/// same way.
///
/// Needs a seeded host, like the other live tests here, and skips without one.
final class SFTPRowTapUITests: XCTestCase {

    func testATapOnAFileOpensItsMenuInsteadOfDownloadingIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let environment = ProcessInfo.processInfo.environment
        let label = environment["SSHBORG_UITEST_EDITOR_HOST"] ?? "editor-target"

        let host = app.staticTexts[label].firstMatch
        guard host.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one with scripts/dev/seed-live-host.py")
        }
        host.press(forDuration: 1.2)
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no Files item in the host menu")
        files.tap()

        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 8) { trust.tap() }

        // A row's label is its name joined to its size and date, so the year
        // identifies one.
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "202"))
            .firstMatch
        guard row.waitForExistence(timeout: 45) else {
            throw XCTSkip("the listing never arrived, or holds nothing datable")
        }
        shot("50-listing")

        // The download control is a button on a file's row too, not a glyph.
        XCTAssertTrue(
            app.buttons["Download"].firstMatch.exists,
            "no download button on the row:\n\(app.debugDescription)"
        )

        row.tap()

        // The menu, and not a transfer. "Open in editor" is the item that proves
        // which of the two menus this is — the row's, not the browser's — and it
        // is also the feature the reporter could not find at all.
        let edit = app.buttons["Open in editor"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "a tap did not open the row's menu")
        shot("51-row-menu")
        XCTAssertTrue(app.buttons["Rename"].exists)
        XCTAssertTrue(app.buttons["Cut"].exists)

        // Nothing was downloaded by the tap. The transfers bar only exists once
        // something has been queued, so its absence is the assertion.
        XCTAssertFalse(
            app.staticTexts["Transfers"].exists,
            "the tap started a transfer as well as opening the menu"
        )

        // And a folder's row, which is the one that grew on Android when the
        // same button arrived: one line against a file's two, so a control
        // sized for the taller row pushes it past its height. Photographed
        // rather than measured — a row half a line taller than its neighbours
        // is a thing for eyes.
        // Dismissed by tapping the empty space below the listing, rather than by
        // choosing one of its items: every item does something, and the point
        // just made is that nothing has been downloaded.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let up = app.buttons["home"].firstMatch
        guard up.waitForExistence(timeout: 10) else { return }
        up.tap()
        let folder = app.buttons["Download folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20), "no download button on a folder row")
        shot("52-folder-rows")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
