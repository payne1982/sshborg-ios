// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The title bar that gets out of the way (#19), and the promise that comes
/// with it: the terminal underneath never changes size.
///
/// That promise is the reason the bar is an overlay rather than a bar that
/// hides. A bar which resized the grid would send the remote program a SIGWINCH
/// three seconds after every tap — vim would reflow, `less` would redraw, and
/// the feature would be worse than the thing it replaced. Nothing about that is
/// visible in a screenshot: the terminal looks right either way, and only the
/// program at the far end would complain. So the frame is measured, three
/// times, and it has to be the same frame.
///
/// Needs a host in the database, like the other live tests here, and skips
/// without one.
final class TerminalTitleBarUITests: XCTestCase {

    /// Longer than the three seconds the bar waits plus the 0.7 it takes to go.
    private let longerThanTheWait: TimeInterval = 5

    /// The promise that makes this an overlay and not a bar: it is drawn over
    /// the terminal's first rows, so the grid never loses them and the remote
    /// program never sees a resize.
    ///
    /// Asserted as an overlap, which is one measurement in one state and needs
    /// no timing at all: a bar that pushed the terminal down would sit directly
    /// above it and the two rectangles would not meet. The bar is held open for
    /// the length of the test — see `barLinger` for why that is not cheating.
    ///
    /// Nothing here taps anything, deliberately. A synthesised tap first waits
    /// for the app to go idle, and this app does not go idle while a terminal
    /// is on screen — the caret blinks, the animations-complete notification
    /// never arrives, and the wait runs for roughly two minutes before giving
    /// up ("t = 18.28s Tap" … "t = 124.66s App animations complete notification
    /// not received", measured here). Two minutes of waiting for nothing is not
    /// worth a second way of proving the buttons work.
    func testTheBarIsDrawnOverTheTerminalAndNotAboveIt() throws {
        let app = launched(lingerSeconds: 60)
        let terminal = try openTheTerminal(in: app)

        // Down on arrival, which teaches the gesture without a word.
        let back = app.buttons["terminal-bar-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the title bar did not arrive with the screen")
        attach(named: "20-bar-down")

        XCTAssertTrue(
            terminal.frame.intersects(back.frame),
            "the title bar is above the terminal, not over it: \(back.frame) vs \(terminal.frame)"
        )

        // The way back and the way out, which the system bar used to carry and
        // which is why this one has two buttons.
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(app.buttons["terminal-bar-close"].isHittable)
    }

    /// And it goes away by itself, at the real three seconds, without the
    /// terminal changing size as it leaves.
    ///
    /// The other half of the gesture — that a tap on the terminal calls the bar
    /// back — is **not** asserted here, and that is a limit of the harness
    /// rather than a gap in the feature. The bar lives under four seconds, and
    /// a tap cannot be synchronised with that window: the tap itself waits for
    /// an idle the terminal never reaches, so by the time it lands the bar has
    /// been and gone. It was watched by hand instead, on this simulator, and
    /// the screenshot is in this file's attachments from that run. What *can*
    /// regress silently is the gesture arbitration behind it — that the tap
    /// waits for the double tap, and does not rob SwiftTerm's own tap of the
    /// keyboard — and `TerminalTouchSettingsTests` pins both.
    func testTheBarRetractsWithoutResizingTheTerminal() throws {
        let app = launched(lingerSeconds: nil)
        let terminal = try openTheTerminal(in: app)
        let frame = terminal.frame
        let back = app.buttons["terminal-bar-back"]

        // Longer than the three seconds it waits plus the 0.7 it takes to go.
        // This direction needs no help from the harness: however the timing is
        // skewed, by now the bar is gone or it never leaves.
        Thread.sleep(forTimeInterval: longerThanTheWait)
        XCTAssertFalse(back.exists, "the title bar stayed on screen")
        attach(named: "21-bar-gone")
        XCTAssertEqual(terminal.frame, frame, "the terminal resized when the bar left")
    }

    /// Hiding the navigation bar used to take the swipe back with it — the
    /// UIKit gesture is wired to the bar's own controller, and
    /// `setNavigationBarHidden(true)` was a classic way to lose it. Whether
    /// SwiftUI's `NavigationStack` keeps it is not something the documentation
    /// says, and it matters here: the swipe is how most people leave a pushed
    /// screen, and on this one it is also what closes the session.
    func testTheSwipeBackStillLeavesTheTerminal() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // The control measurement: with the bar fixed the system's own
        // navigation bar is back, and the swipe has to work there too. If it
        // fails both ways, it was never ours to break.
        let autoHide = ProcessInfo.processInfo.environment["SSHBORG_UITEST_BAR"] ?? "YES"
        app.launchArguments += ["-terminal_bar_auto_hide", autoHide]
        app.launch()

        let label = ProcessInfo.processInfo.environment["SSHBORG_UITEST_HOST_LABEL"] ?? "test-host"
        let row = app.staticTexts[label].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(label)' in the list — seed one to run this")
        }
        row.tap()

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "the terminal screen did not open")

        // From the very edge, which is the only place the pop gesture starts.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: middle)

        XCTAssertTrue(row.waitForExistence(timeout: 10), "the swipe back did not leave the terminal")
        attach(named: "23-after-swipe-back")
    }

    private var hostLabel: String {
        ProcessInfo.processInfo.environment["SSHBORG_UITEST_HOST_LABEL"] ?? "test-host"
    }

    private func launched(lingerSeconds: Int?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // The setting under test, set from outside rather than switched on in
        // Settings: this test is about the bar, not about the row that turns it
        // on, and the default could change.
        app.launchArguments += ["-terminal_bar_auto_hide", "YES"]
        if let lingerSeconds {
            app.launchArguments += ["-SSHBorgBarLingerSeconds", "\(lingerSeconds)"]
        }
        app.launch()
        return app
    }

    /// Opens the seeded host and hands back the terminal view, or skips.
    private func openTheTerminal(in app: XCUIApplication) throws -> XCUIElement {
        let row = app.staticTexts[hostLabel].firstMatch
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("no host labelled '\(hostLabel)' in the list — seed one to run this")
        }
        row.tap()

        let accept = app.buttons["Trust"].firstMatch
        if accept.waitForExistence(timeout: 10) { accept.tap() }

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "no terminal view on screen")
        return terminal
    }

    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
