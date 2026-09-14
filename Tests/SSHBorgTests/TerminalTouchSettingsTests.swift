// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftTerm

@testable import SSHBorg

/// The terminal settings that act on the view: double tap, inverted scrolling,
/// scrollback and pinch-to-zoom.
///
/// Until 13/09/2026 the first three were offered in Settings and read by
/// nothing. These tests check what a unit test can: that the values reach the
/// terminal, and that the arithmetic behind the gestures is right. Whether the
/// gestures *feel* right needs a finger on a phone.
@MainActor
final class TerminalTouchSettingsTests: XCTestCase {

    private var database: AppDatabase!
    private var session: TerminalSession!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        session = TerminalSession(
            host: Host(label: "somewhere", hostname: "example.invalid", username: "someone"),
            hosts: HostRepository(database),
            keys: SSHKeyRepository(database)
        )
    }

    // MARK: - Double tap

    func testTheDoubleTapSendsWhatAndroidSends() {
        XCTAssertNil(AppPreferences.DoubleTapAction.none.bytes)
        XCTAssertEqual(AppPreferences.DoubleTapAction.tab.bytes, Data([0x09]))
        XCTAssertEqual(AppPreferences.DoubleTapAction.tabTwice.bytes, Data([0x09, 0x09]))
    }

    /// The setting reuses SwiftTerm's own two-tap recogniser and its handler,
    /// which is internal to SwiftTerm and named by string. If an update renames
    /// either, this fails — instead of the double tap silently doing nothing.
    func testSwiftTermStillHasTheDoubleTapThisReplaces() {
        XCTAssertNotNil(TerminalTouchHandling.doubleTapRecognizer(on: session.terminalView))
        XCTAssertTrue(session.terminalView.responds(to: TerminalTouchHandling.swiftTermDoubleTap))
    }

    // MARK: - Scrollback

    func testTheScrollbackSettingReachesTheTerminal() {
        session.applyViewSettings(doubleTap: .none, invertedScroll: false, scrollback: 5000)
        XCTAssertEqual(session.terminalView.getTerminal().options.scrollback, 5000)

        session.applyViewSettings(doubleTap: .none, invertedScroll: false, scrollback: 500)
        XCTAssertEqual(session.terminalView.getTerminal().options.scrollback, 500)
    }

    // MARK: - Inverted scrolling

    func testInvertingHandsTheDragToTheInvertedGesture() {
        session.applyViewSettings(doubleTap: .none, invertedScroll: true, scrollback: 2000)
        XCTAssertFalse(session.terminalView.isScrollEnabled, "the scroll view still drags the natural way")

        session.applyViewSettings(doubleTap: .none, invertedScroll: false, scrollback: 2000)
        XCTAssertTrue(session.terminalView.isScrollEnabled, "turning it off did not give the drag back")
    }

    /// A finger moving down is a positive drag, and inverted that means newer
    /// output — so swiping up shows older, as the setting's subtitle promises.
    func testADragBecomesWholeLinesAndKeepsTheRest() {
        let down = TerminalTouchHandling.wholeLines(accumulated: 50, cellHeight: 20)
        XCTAssertEqual(down.lines, 2)
        XCTAssertEqual(down.remainder, 10, accuracy: 0.001)

        let up = TerminalTouchHandling.wholeLines(accumulated: -50, cellHeight: 20)
        XCTAssertEqual(up.lines, -2)
        XCTAssertEqual(up.remainder, -10, accuracy: 0.001)
    }

    /// Less than a line is not lost, only carried — or a slow drag never moves.
    func testASlowDragAccumulatesInsteadOfVanishing() {
        var remainder: CGFloat = 0
        var moved = 0
        for _ in 0..<10 {
            let step = TerminalTouchHandling.wholeLines(accumulated: remainder + 5, cellHeight: 20)
            remainder = step.remainder
            moved += step.lines
        }
        XCTAssertEqual(moved, 2)
    }

    func testMomentumSlowsDownAndStops() {
        let later = TerminalTouchHandling.decayed(1000, over: 0.1)
        XCTAssertLessThan(later, 1000)
        XCTAssertGreaterThan(later, 0)
        XCTAssertLessThan(
            TerminalTouchHandling.decayed(1000, over: 5),
            TerminalTouchHandling.minimumCoastSpeed,
            "a flick is still coasting five seconds later"
        )
    }

    // MARK: - Scrolling inside full-screen apps

    /// tmux turns on the mouse; SwiftTerm would answer by installing a pan that
    /// reports every swipe as a drag with the button held, which tmux takes for
    /// a selection. Plain `TerminalView` adds that recogniser here.
    func testTurningOnTheMouseDoesNotTurnASwipeIntoADrag() {
        let before = session.terminalView.gestureRecognizers?.count
        session.terminalView.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(session.terminalView.gestureRecognizers?.count, before)
    }

    func testASwipeReachesTheAppOnlyInAFullScreenAppThatAskedForTheMouse() {
        let terminal = session.terminalView.getTerminal()
        XCTAssertFalse(TerminalTouchHandling.reportsWheel(terminal))

        session.terminalView.feed(text: "\u{1b}[?1000h")
        XCTAssertFalse(TerminalTouchHandling.reportsWheel(terminal), "the main screen has history to scroll")

        session.terminalView.feed(text: "\u{1b}[?1049h")
        XCTAssertTrue(TerminalTouchHandling.reportsWheel(terminal))

        session.terminalView.feed(text: "\u{1b}[?1000l")
        XCTAssertFalse(TerminalTouchHandling.reportsWheel(terminal), "the app gave the mouse back")
    }

    /// A finger moving down reads older output, as it does on the main screen:
    /// wheel up. Inverted, the other way.
    func testTheWheelFollowsTheScrollDirection() {
        XCTAssertEqual(TerminalTouchHandling.wheelButton(lines: 2, inverted: false), 4)
        XCTAssertEqual(TerminalTouchHandling.wheelButton(lines: -2, inverted: false), 5)
        XCTAssertEqual(TerminalTouchHandling.wheelButton(lines: 2, inverted: true), 5)
        XCTAssertEqual(TerminalTouchHandling.wheelButton(lines: -2, inverted: true), 4)
    }

    // MARK: - Selection

    /// The immediate selection hangs off SwiftTerm's own long-press recogniser.
    /// If an update drops or replaces it, this fails rather than the long press
    /// quietly going back to a menu with nothing selected.
    func testSwiftTermStillHasTheLongPressThisExtends() {
        XCTAssertFalse(TerminalTouchHandling.longPressRecognizers(on: session.terminalView).isEmpty)
    }

    /// SwiftTerm clears the selection on every chunk of output; a shell
    /// repainting its prompt was enough to make copying impossible.
    func testOutputArrivingDoesNotClearTheSelection() {
        let terminal = session.terminalView
        terminal.feed(text: "hello world\r\n")
        terminal.selectAll(nil)
        XCTAssertTrue(terminal.selectionActive)

        terminal.feed(text: "more output\r\n")
        XCTAssertTrue(terminal.selectionActive, "the output took the selection away")

        terminal.selectNone()
        XCTAssertTrue(terminal.allowMouseReporting, "a tap is no longer a click for tmux")
    }

    // MARK: - Pinch to zoom

    func testAPinchStaysInsideTheSettingsBounds() {
        XCTAssertEqual(TerminalTouchHandling.zoomedSize(from: 13, scale: 2), 26)
        XCTAssertEqual(TerminalTouchHandling.zoomedSize(from: 13, scale: 10), 32)
        XCTAssertEqual(TerminalTouchHandling.zoomedSize(from: 13, scale: 0.1), 8)
        XCTAssertEqual(TerminalTouchHandling.zoomedSize(from: 13, scale: 1.02), 13, "a tremor re-measures the grid")
    }

    func testAPinchedSizeBelongsToTheTab() {
        XCTAssertNil(session.zoomedFontSize)

        session.zoom(to: 20)

        XCTAssertEqual(session.zoomedFontSize, 20)
        XCTAssertEqual(session.terminalView.font.pointSize, 20)
    }
}
