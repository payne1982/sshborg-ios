// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Photographs the cut bar, which is the one part of a move that has to be
/// looked at rather than reasoned about: it is a mode the user is in, and the
/// question is whether the screen says so.
///
/// It cuts and then cancels. Nothing is pasted and nothing on the server moves —
/// the move itself is measured in `SFTPIntegrationTests`, inside a scratch
/// directory it makes and removes, which is where an automated test may rearrange
/// somebody's files and a UI test pointed at a real home directory may not.
///
/// Needs a seeded host, like the other live tests here, and skips without one.
final class SFTPMoveUITests: XCTestCase {

    func testTheCutBarSaysWhatIsWaitingAndHowToLeave() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let environment = ProcessInfo.processInfo.environment
        let label = environment["SSHBORG_UITEST_EDITOR_HOST"] ?? "editor-target"

        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one with scripts/dev/seed-live-host.py")
        }

        row.press(forDuration: 1.2)
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no Files item in the host menu")
        files.tap()

        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 8) { trust.tap() }

        // A row's label is its name joined to its size and date, so the year is
        // what identifies one — the handle `EditorUITests` uses, for the same
        // reason. The first button on screen would be a toolbar item.
        let entry = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "202"))
            .firstMatch
        guard entry.waitForExistence(timeout: 45) else {
            throw XCTSkip("the listing never arrived, or holds nothing datable")
        }

        // Through selection mode rather than a row's long-press menu. Both offer
        // Cut and the one under test is the bar that follows, but a context menu
        // opens in a window of its own that comes back empty to a query here —
        // seen in the tree, with the dimming overlay present and not one of the
        // items in it. Selection mode is ordinary buttons, and it exercises the
        // more interesting of the two paths: several entries at once.
        app.buttons["Actions"].firstMatch.tap()
        let select = app.buttons["Select items"].firstMatch
        guard select.waitForExistence(timeout: 10) else {
            throw XCTSkip("no Select items in the browser menu")
        }
        select.tap()

        // Re-found, because selection mode changed what it is: outside it a row
        // is a Button, inside it the row is plain content so that the list can
        // take the tap and tick it. That is the fix this test paid for, and
        // querying for a Button here is how it announces itself.
        let selectable = app.cells.firstMatch
        XCTAssertTrue(selectable.waitForExistence(timeout: 10), "no rows in selection mode")
        selectable.tap()
        shot("39-selected")
        // Whether the tap selected the row is asserted through the toolbar
        // rather than from the row: the toolbar's "1 selected" is a principal
        // item that a phone this narrow does not draw, and `isSelected` on the
        // cell reads from a snapshot taken before the tap. Cut being live says
        // the same thing and says it about the thing under test — it is
        // disabled on an empty selection, so this fails if the tap selected
        // nothing, which is exactly what it did before the row stopped being a
        // button in selection mode.
        let cut = app.buttons["Cut"].firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 10), "no Cut in the selection toolbar")
        XCTAssertTrue(cut.isEnabled, "the row tap selected nothing: Cut is still disabled")
        cut.tap()

        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "no cut bar after Cut")
        shot("40-cut-bar")

        // Pasting into the folder it came from would do nothing, and the button
        // says so rather than pretending otherwise.
        XCTAssertFalse(paste.isEnabled, "Paste offered in the folder the entries were cut from")

        // Cutting also leaves selection mode, as it does on Android: the
        // selection has been spent.
        XCTAssertFalse(app.buttons["Done"].exists, "still in selection mode after Cut")

        // And the way out of the mode the bar announces.
        app.buttons["Cancel the move"].firstMatch.tap()
        XCTAssertFalse(paste.waitForExistence(timeout: 3), "the cut bar outlived the cancel")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
