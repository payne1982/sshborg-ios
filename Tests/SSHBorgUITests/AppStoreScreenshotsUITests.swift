// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Takes the App Store screenshots.
///
/// Not a test of anything: it walks the screens a store page shows and attaches
/// a full-resolution capture of each, named for the order they go up in. Run it
/// on an iPhone 6.9" (1320×2868) and an iPad 13" (2064×2752) simulator — the two
/// sizes App Store Connect requires — in dark appearance, with the status bar
/// overridden to 9:41 before launch.
///
/// **Everything on screen ends up public.** The hosts are the fictional ones
/// from scripts/dev/seed-simulator-hosts.py, and the terminal and SFTP shots
/// connect to a throwaway demo server whose prompt and paths are made up.
/// Nothing here may show a real machine, user or address.
///
/// It runs in three passes because the passes need different state, set up
/// from outside between them:
///
/// 1. `test10_…` generates the keys (the app has to be installed first, and a
///    key has to exist before the demo server can authorise it);
/// 2. the harness seeds the host list; `test20_…` to `test40_…` photograph the
///    list, the settings and the extra-key-bar editor;
/// 3. the harness points `web-01` at the demo server; `test50_…` and `test60_…`
///    photograph the terminal and the file browser.
///
/// Opt-in: without SSHBORG_SCREENSHOTS=1 every test skips, so the ordinary
/// suite never touches the keys or the network.
final class AppStoreScreenshotsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SSHBORG_SCREENSHOTS"] == "1" else {
            throw XCTSkip("App Store screenshots are taken only with SSHBORG_SCREENSHOTS=1")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // No finger can answer Face ID; see AppLock.shouldLock.
        app.launchArguments += ["-SSHBorgDisableLock"]
        app.launchArguments += ["-security_reminder_dismissed", "YES", "-privacy_policy_accepted", "YES"]
        // The bar stays on screen with the keyboard down, which is the state the
        // terminal shot wants: the output visible and the keys still there.
        app.launchArguments += ["-extra_keys_bar_pinned", "YES"]
        app.launch()
    }

    // MARK: - Helpers

    private func shoot(_ name: String) {
        // Long enough for transitions and the keyboard to finish moving: a
        // capture that exists is not the same as one that has settled.
        Thread.sleep(forTimeInterval: 1.5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "appstore-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func button(startingWith text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", text)).firstMatch
    }

    private func waitForHostList() {
        XCTAssertTrue(
            app.buttons["Settings"].firstMatch.waitForExistence(timeout: 20),
            "the host list never appeared:\n\(app.debugDescription)"
        )
    }

    private func hideKeyboardIfShown() {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.exists {
            hide.tap()
        } else {
            // On iPhone the extra-key bar carries the keyboard key. It is a
            // view with the button trait rather than a Button, so asking
            // `app.buttons` found nothing and the keyboard stayed over half the
            // first terminal shot.
            let toggle = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "keyboard"))
                .firstMatch
            if toggle.exists { toggle.tap() }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// The "Type English and Italian" card iOS shows the first time a keyboard
    /// with two languages comes up. It sits exactly where the keyboard would,
    /// and it landed in the first key-generator shot.
    private func dismissKeyboardTip() {
        let proceed = app.buttons["Continue"].firstMatch
        if proceed.waitForExistence(timeout: 2) {
            proceed.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The iPad's terminal is wide enough for output an iPhone would wrap.
    private var isWide: Bool {
        app.windows.firstMatch.frame.width >= 700
    }

    // MARK: - Pass 1: keys

    func test10_GenerateKeys() throws {
        waitForHostList()
        app.buttons["SSH Keys"].firstMatch.tap()

        generateKey(label: "deploy@web-01", type: nil, photographAs: nil)
        generateKey(label: "backup@nas", type: "ECDSA", photographAs: nil)

        XCTAssertTrue(app.staticTexts["deploy@web-01"].waitForExistence(timeout: 30), "the first key never appeared")
        XCTAssertTrue(app.staticTexts["backup@nas"].waitForExistence(timeout: 30), "the second key never appeared")
        shoot("07-keys-list")
    }

    private func generateKey(label: String, type: String?, photographAs name: String?) {
        let empty = app.buttons["Generate SSH Key"].firstMatch
        if empty.waitForExistence(timeout: 5) {
            empty.tap()
        } else {
            app.buttons["Add"].firstMatch.tap()
            let generate = app.buttons["Generate key"].firstMatch
            XCTAssertTrue(generate.waitForExistence(timeout: 5), "no Generate key in the add menu")
            generate.tap()
        }

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the generator did not open:\n\(app.debugDescription)")
        field.tap()
        dismissKeyboardTip()
        field.typeText(label)
        if let type { app.buttons[type].firstMatch.tap() }
        hideKeyboardIfShown()
        if let name { shoot(name) }

        app.buttons["Generate"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 60), "\(label) was not generated")
    }

    /// The generator with its choice of key type, photographed and then
    /// cancelled — so it can be retaken without adding keys to the list.
    func test15_KeyGeneratorForm() throws {
        waitForHostList()
        app.buttons["SSH Keys"].firstMatch.tap()
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let generate = app.buttons["Generate key"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 5), "no Generate key in the add menu")
        generate.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        dismissKeyboardTip()
        field.typeText("deploy@web-02")
        hideKeyboardIfShown()
        shoot("04-keys-generate")
        app.buttons["Cancel"].firstMatch.tap()
    }

    // MARK: - Pass 2: the host list, settings and the bar editor

    func test20_HostList() throws {
        waitForHostList()
        XCTAssertTrue(app.staticTexts["web-01"].waitForExistence(timeout: 10), "the seeded hosts are missing")
        shoot("01-hosts")
    }

    func test30_Settings() throws {
        waitForHostList()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 10))
        shoot("06-settings")
    }

    func test40_ExtraKeyBarEditor() throws {
        waitForHostList()
        app.buttons["Settings"].firstMatch.tap()

        let layoutRow = button(startingWith: "Extra key bar layout")
        var swipes = 0
        while !layoutRow.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        layoutRow.tap()

        let twoRow = button(startingWith: "Natural ×2")
        XCTAssertTrue(twoRow.waitForExistence(timeout: 10), "the presets are not listed")
        twoRow.press(forDuration: 1.2)
        let duplicate = app.buttons["Duplicate"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()

        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10), "the editor did not open")
        // A key selected, so the picture shows the editor doing its job.
        let esc = app.buttons["ESC"].firstMatch
        if esc.waitForExistence(timeout: 5) { esc.tap() }
        shoot("05-extra-key-bar-editor")
    }

    // MARK: - Pass 3: a live session against the demo server

    func test50_Terminal() throws {
        waitForHostList()
        app.staticTexts["web-01"].firstMatch.tap()

        // First contact with the demo server raises the fingerprint prompt.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 20) { trust.tap() }

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "no terminal:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 3)
        terminal.tap()
        Thread.sleep(forTimeInterval: 1)

        // Chosen to fit the width: `free -h` and an access log wrap on an
        // iPhone and fill the iPad's screen usefully instead of leaving it black.
        let commands = isWide
            ? ["clear", "uptime -p", "free -h", "df -h /", "ls", "cat docker-compose.yml", "tail -n 8 logs/access.log"]
            : ["clear", "uptime -p", "df -h /", "ls", "cat docker-compose.yml"]
        for command in commands {
            app.typeText(command + "\n")
            Thread.sleep(forTimeInterval: 1.2)
        }
        hideKeyboardIfShown()
        shoot("02-terminal")
    }

    func test60_FileBrowser() throws {
        waitForHostList()
        // Through the row's context menu. The folder button on the row is not
        // reachable as a button inside its cell — XCUITest reports it as a
        // pop-up button from modern attributes and finds nothing — while the
        // menu entry is an ordinary button everywhere.
        let label = app.staticTexts["web-01"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        label.press(forDuration: 1.5)
        let files = app.buttons["Files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), "no Files in the host menu:\n\(app.debugDescription)")
        files.tap()

        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 8) { trust.tap() }

        XCTAssertTrue(
            app.staticTexts["backups"].waitForExistence(timeout: 30),
            "the demo directory never listed:\n\(app.debugDescription)"
        )
        shoot("03-sftp")
    }
}
