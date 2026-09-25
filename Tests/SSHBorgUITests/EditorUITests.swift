// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Opens a real remote file in the editor and photographs it.
///
/// The editor cannot be checked by reasoning: whether the colours read against
/// the background, whether a monospaced line of `sshd_config` fits a phone
/// without wrapping into nonsense, whether the status line and the keyboard
/// leave the text any room — those are questions for eyes, and this is how eyes
/// get pointed at them.
///
/// It needs a host that answers, seeded by `scripts/dev/seed-live-host.py`, and
/// a file on it to open. Both are named by environment variables so nothing
/// about anybody's network is written down here; with no such host in the list
/// the test skips.
final class EditorUITests: XCTestCase {

    func testOpeningAFileInTheEditor() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let environment = ProcessInfo.processInfo.environment
        let label = environment["SSHBORG_UITEST_EDITOR_HOST"] ?? "editor-target"
        let file = environment["SSHBORG_UITEST_EDITOR_FILE"] ?? "sshborg-editor-sample.conf"

        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one with scripts/dev/seed-live-host.py")
        }

        // The row's own menu opens the file browser. The folder badge beside the
        // name is not it: that appears only once a browser is already open.
        row.press(forDuration: 1.2)
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), "no Files item in the host menu:\n\(app.debugDescription)")
        files.tap()

        // First sight of a server asks about its key, and a seeded host has
        // never been connected to.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 20) {
            shot("29-host-key")
            trust.tap()
        }

        // A row is one element whose label is the name joined to its size and
        // date — the same lesson the extra-bar tests paid for — so the name is
        // matched as a prefix rather than looked up whole.
        let entry = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", file))
            .firstMatch
        // Wait for the listing to arrive at all, then scroll to the file: a
        // List builds only the rows on screen, so a name further down the home
        // directory than the fold simply does not exist to a query yet.
        let anyRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "20")).firstMatch
        _ = anyRow.waitForExistence(timeout: 45)

        var swipes = 0
        while !(entry.exists && entry.isHittable) && swipes < 15 {
            app.swipeUp()
            swipes += 1
        }
        guard entry.exists else {
            tree("30-tree")
            shot("30-listing")
            throw XCTSkip("'\(file)' is not in the home directory of that host")
        }
        shot("30-listing")

        entry.press(forDuration: 1.2)
        let edit = app.buttons["Open in editor"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "no editor item in the menu:\n\(app.debugDescription)")
        edit.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "the editor did not open:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 2)
        shot("31-editor")

        // The status line says what the file is made of, and Save is off until
        // something changes — the two things a screenshot can also confirm.
        XCTAssertTrue(app.buttons["Save"].firstMatch.exists, "no save button")
        XCTAssertFalse(app.buttons["Save"].firstMatch.isEnabled, "save is offered before anything was typed")

        editor.tap()
        editor.typeText("# edited by the UI test\n")
        Thread.sleep(forTimeInterval: 1)
        shot("32-edited")
        XCTAssertTrue(app.buttons["Save"].firstMatch.isEnabled, "typing did not arm the save button")

        // Out without saving: the file on the server is left exactly as it was,
        // and the prompt that asks about it is itself worth a picture.
        app.buttons["Back"].firstMatch.tap()
        let discard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "leaving with changes asked nothing")
        shot("33-unsaved-prompt")
        discard.tap()
    }

    private func tree(_ name: String) {
        let attachment = XCTAttachment(string: XCUIApplication().debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
