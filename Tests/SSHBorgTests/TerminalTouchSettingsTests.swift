// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftTerm
import UIKit

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

    // MARK: - The tap that calls the title bar back (#19)

    /// The tap has to be a *confirmed* single one: with the double tap bound to
    /// Tab, a handler that ran on the first half of one would flash the title
    /// bar on every completion. The failure requirement is what buys that, and
    /// it is the part a finger on a phone cannot tell you is missing.
    func testTheTapWaitsForTheDoubleTapToFail() throws {
        let gestures = try XCTUnwrap(session.tapGesturesForTesting)
        let doubleTap = try XCTUnwrap(TerminalTouchHandling.doubleTapRecognizer(on: session.terminalView))

        XCTAssertEqual(gestures.tap.numberOfTapsRequired, 1)
        XCTAssertTrue(gestures.tap.view === session.terminalView)
        XCTAssertTrue(gestures.waitsFor === doubleTap, "the single tap no longer waits for the double tap")
    }

    /// And it must not be the recogniser that wins: SwiftTerm's own tap is what
    /// raises the keyboard, and two rivals wanting one tap cancel each other.
    func testTheTapLetsSwiftTermsOwnTapThrough() throws {
        let tap = try XCTUnwrap(session.tapGesturesForTesting).tap
        let delegate = try XCTUnwrap(tap.delegate)
        let swiftTermTap = try XCTUnwrap(
            session.terminalView.gestureRecognizers?
                .compactMap { $0 as? UITapGestureRecognizer }
                .first { $0 !== tap && $0.numberOfTapsRequired == 1 },
            "SwiftTerm no longer installs a single tap of its own"
        )

        XCTAssertFalse(tap.cancelsTouchesInView)
        XCTAssertTrue(
            delegate.gestureRecognizer?(tap, shouldRecognizeSimultaneouslyWith: swiftTermTap) ?? false
        )
    }

    // MARK: - The rows the title bar lies over (#19)

    /// Rounded up, because a row half covered is a row that cannot be read.
    /// Android's `rowsCovering` does the same with the same `ceil`.
    func testTheBarCoversWholeRowsRoundedUp() {
        // 24 rows in 480 points is a cell 20 points tall, so the 44-point bar
        // lies over two whole rows and part of a third.
        XCTAssertEqual(TerminalSession.rowsCovered(by: 44, viewHeight: 480, rows: 24), 3)
        XCTAssertEqual(TerminalSession.rowsCovered(by: 40, viewHeight: 480, rows: 24), 2)
        XCTAssertEqual(TerminalSession.rowsCovered(by: 0.5, viewHeight: 480, rows: 24), 1)
    }

    /// The fixed bar covers nothing, and neither does a grid that has not been
    /// laid out yet — there is no cell height to divide by, so there is no
    /// answer, and a guess would push the login down for nothing.
    func testNothingIsCoveredWithoutABarOrALayout() {
        XCTAssertEqual(TerminalSession.rowsCovered(by: 0, viewHeight: 480, rows: 24), 0)
        XCTAssertEqual(TerminalSession.rowsCovered(by: 44, viewHeight: 0, rows: 24), 0)
        XCTAssertEqual(TerminalSession.rowsCovered(by: 44, viewHeight: 480, rows: 0), 0)
    }

    /// And never the whole grid: a terminal squeezed shorter than the bar —
    /// Split View dragged almost shut — must keep a row to write the prompt on,
    /// or the padding would scroll the login away as it wrote it.
    func testTheGridKeepsARowToWriteOn() {
        XCTAssertEqual(TerminalSession.rowsCovered(by: 10_000, viewHeight: 480, rows: 24), 23)
        XCTAssertEqual(TerminalSession.rowsCovered(by: 44, viewHeight: 20, rows: 1), 0)
    }

    /// A tab is created with the bar covering nothing: the screen is what knows
    /// whether the bar is ours, and it says so before the first connection.
    func testATabStartsAssumingNoBar() {
        XCTAssertEqual(session.titleBarOverlap, 0)
    }

    /// The login begins below the bar: the cursor is as many rows down as the
    /// bar covers before the first byte of the banner arrives.
    ///
    /// The expected row is computed from the view's own geometry rather than
    /// written down, because the cell height belongs to the font and the layout
    /// — what this pins is that the rows are really written, that they are the
    /// number the bar covers, and that the cursor moved rather than the grid
    /// scrolling.
    func testTheFirstLoginStartsBelowTheBar() {
        let terminal = session.terminalView
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        terminal.layoutSubviews()

        let expected = TerminalSession.rowsCovered(
            by: 44,
            viewHeight: terminal.bounds.height,
            rows: terminal.getTerminal().rows
        )
        XCTAssertGreaterThan(expected, 0, "a 44-point bar over a 600-point grid covers no row")
        XCTAssertEqual(terminal.getTerminal().getCursorLocation().y, 0)

        session.titleBarOverlap = 44
        session.startBelowTheTitleBar()
        XCTAssertEqual(terminal.getTerminal().getCursorLocation().y, expected)
    }

    /// And only at the first login. A reconnect arrives with the previous
    /// session's output on screen, where blank rows would be noise.
    func testAReconnectIsNotPushedDownAgain() {
        let terminal = session.terminalView
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        terminal.layoutSubviews()

        session.titleBarOverlap = 44
        session.startBelowTheTitleBar()
        let afterLogin = terminal.getTerminal().getCursorLocation().y

        session.startBelowTheTitleBar()
        XCTAssertEqual(terminal.getTerminal().getCursorLocation().y, afterLogin)
    }

    /// With the system's bar nothing is written at all: the terminal starts
    /// below it, so there is nothing to make room for.
    func testTheFixedBarWritesNothing() {
        let terminal = session.terminalView
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        terminal.layoutSubviews()

        session.startBelowTheTitleBar()
        XCTAssertEqual(terminal.getTerminal().getCursorLocation().y, 0)
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

    /// The blue flash of 26/09/2026: SwiftTerm tells UIKit that any range of
    /// text covers the whole view, so the keyboard highlighting the word it is
    /// composing painted the entire terminal. Nothing UIKit draws here belongs
    /// on screen — the selection the user sees is the terminal's own.
    ///
    /// Called through the protocol, which is how UIKit calls it: a direct Swift
    /// call would be dispatched straight to SwiftTerm's own method and would
    /// pass whether or not the replacement took.
    func testUIKitIsGivenNothingToPaintOverTheTerminal() throws {
        let input: UITextInput = session.terminalView
        session.terminalView.insertText("ls -la")

        let range = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        XCTAssertTrue(input.selectionRects(for: range).isEmpty, "UIKit was handed a rectangle to fill")
    }

    /// The other two thirds of the same stub. `caretRect` is what the space
    /// bar's floating cursor draws, `firstRect` is what places anything UIKit
    /// wants beside the text; both answered `bounds`, the whole screen.
    ///
    /// `firstRect` was left alone in the first attempt because it only
    /// positions popovers. The flash survived build 5 because of it.
    func testTheTextRectsAreOneCell() throws {
        let input: UITextInput = session.terminalView
        let emulator = session.terminalView.getTerminal()
        let bounds = session.terminalView.bounds
        let cell = CGSize(
            width: bounds.width / CGFloat(emulator.cols),
            height: bounds.height / CGFloat(emulator.rows)
        )

        let whole = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        for rect in [input.caretRect(for: input.endOfDocument), input.firstRect(for: whole)] {
            XCTAssertEqual(rect.width, cell.width, accuracy: 0.01)
            XCTAssertEqual(rect.height, cell.height, accuracy: 0.01)
            XCTAssertNotEqual(rect, bounds, "UIKit was told the text fills the terminal")
        }
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
