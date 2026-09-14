// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Guards "a long press opens the copy and paste menu, but nothing can be
/// selected — outside tmux too" (reported from the phone on 14/09/2026).
///
/// It needs no server, only one of the fictional hosts the screenshot tooling
/// seeds: a host with no stored password raises its prompt as a card at the top
/// and leaves the rest of the terminal free to press on.
///
/// What it asserts is the part a screenshot cannot hide: after the long press
/// alone, the menu offers Copy, which it only does with something selected.
/// The drag that extends the selection is recorded as a screenshot — on
/// 14/09/2026 it showed the highlight growing over several rows.
///
/// Two lessons from building it. A plain `press(forDuration:thenDragTo:)` is
/// too fast: the pan is noticed only near the far end. And SwiftTerm extends
/// only when the drag starts within three columns of the selection's end, so a
/// diagonal drag leaves that window before it is recognised.
final class TerminalSelectionUITests: XCTestCase {

    func testLongPressThenSelect() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No finger can answer Face ID; see AppLock.shouldLock.
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        let label = ProcessInfo.processInfo.environment["SSHBORG_UITEST_SELECTION_HOST"] ?? "old-switch"
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one to run this")
        }
        row.tap()
        Thread.sleep(forTimeInterval: 8)
        shot("20-terminal")

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "no terminal view on screen")
        // The lower part: a host with no stored password raises its prompt as a
        // card across the top of the terminal, and a press there lands in the
        // card's password field (its AutoFill menu, on the first run).
        let spot = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))

        // The long press alone should select, handles and Copy included.
        spot.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 2)
        shot("21-after-long-press")
        tree("21-tree")
        XCTAssertTrue(
            app.menuItems["Copy"].firstMatch.waitForExistence(timeout: 5),
            "the long press opened the menu without selecting anything"
        )

        // The word under an empty row is the whole row, so its end handle sits
        // at the right edge. Dragging it down has to extend the selection
        // rather than scroll the terminal.
        //
        // Straight down, from the very edge. SwiftTerm extends only when the
        // drag starts within three columns of the selection's end, and the pan
        // is recognised some ten points into the movement: a diagonal drag had
        // already left that window when it was noticed (column 47 of 50).
        let endHandle = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.7))
        let below = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.85))
        // Slowly, so the drag arrives as many small moves the way a finger's
        // does, rather than a jump the recogniser first notices at the far end.
        endHandle.press(forDuration: 0.3, thenDragTo: below, withVelocity: 60, thenHoldForDuration: 0.5)
        Thread.sleep(forTimeInterval: 2)
        shot("22-after-dragging-the-handle")
        tree("22-tree")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tree(_ name: String) {
        let attachment = XCTAttachment(string: XCUIApplication().debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
