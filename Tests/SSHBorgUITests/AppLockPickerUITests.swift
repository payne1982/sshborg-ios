// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// A trip to a system file picker does not take the app out of the foreground.
///
/// Android needs a three-minute grace for exactly that: opening a picker stops
/// the activity, so with a short lock timeout every file chosen for an upload, a
/// backup or a key import asked for the PIN on the way back. Whether UIKit does
/// the same is a question about the platform rather than about our code, and a
/// hole in a lock is not something to open — or leave open — on an assumption.
///
/// Measured on 24/09/2026, iOS 26.3 simulator: with the picker up, and its
/// "Recents" chrome in the screenshot to prove it, the log carried one
/// `didBecomeActive` from the launch and no `willResignActive` at all. So that
/// grace is not needed here, and this is what will say so again if some future
/// iOS changes its mind.
///
/// Two of the three things it asserts are what a test can see from outside: the
/// picker covers the app's own elements, and the app stays in the foreground
/// throughout. The third is in the log, which `AppLock` writes one line at a
/// time in debug builds:
///
///     xcrun simctl spawn booted log show --last 3m \
///         --predicate 'process == "SSHBorg"' | grep AppLock
///
/// The lock itself is off here (`-SSHBorgDisableLock`), because no finger can
/// answer Face ID. What is being watched is the notification, which arrives
/// regardless — the trace line sits before the guard that reads the setting.
final class AppLockPickerUITests: XCTestCase {

    func testTheFilePickerDoesNotSendTheAppToTheBackground() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        app.launch()

        // The key list is in the host list's toolbar, then Add → Import key →
        // Load from file, which is the shortest way to a system picker.
        let keys = app.buttons["SSH Keys"].firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 15), "no SSH Keys button in the toolbar:\n\(app.debugDescription)")
        keys.tap()

        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no add button on the keys screen:\n\(app.debugDescription)")
        add.tap()

        let importKey = app.buttons["Import key"].firstMatch
        XCTAssertTrue(importKey.waitForExistence(timeout: 5), "no Import item in the menu:\n\(app.debugDescription)")
        importKey.tap()

        let fromFile = app.buttons["Load from file"].firstMatch
        XCTAssertTrue(fromFile.waitForExistence(timeout: 10), "no load-from-file button:\n\(app.debugDescription)")

        NSLog("AppLock-probe: opening the picker")
        fromFile.tap()
        Thread.sleep(forTimeInterval: 5)
        attach("10-picker")

        // The picker is a view service in another process, so the app's own
        // elements go behind it: something covering them is how this test knows
        // the picker really opened, without querying a process it does not own.
        XCTAssertFalse(fromFile.isHittable, "the picker did not open over the app")
        XCTAssertEqual(app.state, .runningForeground, "the picker put the app in the background")
        NSLog("AppLock-probe: the picker is up")

        // Out again, whichever way this iOS version offers.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 5) {
            cancel.tap()
        } else {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            app.activate()
        }
        Thread.sleep(forTimeInterval: 3)
        NSLog("AppLock-probe: the picker is closed")
        attach("11-back")
        XCTAssertEqual(app.state, .runningForeground, "the app did not come back to the foreground")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
