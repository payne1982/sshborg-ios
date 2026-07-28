// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

final class AppPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var preferences: AppPreferences!

    override func setUpWithError() throws {
        suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences = AppPreferences(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// These defaults are part of the cross-platform contract: a fresh install
    /// must behave identically on both platforms.
    func testDefaultsMatchAndroid() {
        XCTAssertFalse(preferences.biometricLock)
        XCTAssertFalse(preferences.keychainEncryption)
        XCTAssertFalse(preferences.confirmExit)
        XCTAssertEqual(preferences.lockTimeoutSeconds, 60)
        XCTAssertFalse(preferences.jailbreakWarningAcknowledged)
        XCTAssertFalse(preferences.invertTerminalScroll)
        XCTAssertEqual(preferences.nightMode, .followSystem)
        XCTAssertFalse(preferences.allowScreenshots)
        XCTAssertEqual(preferences.scrollbackLines, 2000)
        XCTAssertEqual(preferences.terminalFontSize, 13)
        XCTAssertFalse(preferences.keepScreenOn)
        XCTAssertEqual(preferences.terminalColorScheme, .dark)
        XCTAssertEqual(preferences.doubleTapAction, .none)
        XCTAssertTrue(preferences.historySuggestions)
        XCTAssertFalse(preferences.suggestionsBarSticky)
        XCTAssertFalse(preferences.securityReminderDismissed)
        XCTAssertFalse(preferences.privacyPolicyAccepted)
    }

    /// The raw values are written verbatim into the shared backup, so they must
    /// stay pinned to Android's `AppCompatDelegate` constants.
    func testNightModeRawValuesMatchAppCompat() {
        XCTAssertEqual(AppPreferences.NightMode.followSystem.rawValue, -1)
        XCTAssertEqual(AppPreferences.NightMode.light.rawValue, 1)
        XCTAssertEqual(AppPreferences.NightMode.dark.rawValue, 2)
    }

    func testValuesPersistToUserDefaults() {
        preferences.terminalFontSize = 18
        preferences.nightMode = .dark

        // A second instance over the same store must see the written values.
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.terminalFontSize, 18)
        XCTAssertEqual(reloaded.nightMode, .dark)
    }

    // MARK: - Clamping

    func testFontSizeIsClamped() {
        preferences.terminalFontSize = 1
        XCTAssertEqual(preferences.terminalFontSize, AppPreferences.Limits.minTerminalFontSize)

        preferences.terminalFontSize = 999
        XCTAssertEqual(preferences.terminalFontSize, AppPreferences.Limits.maxTerminalFontSize)
    }

    func testScrollbackAndTimeoutAreClamped() {
        preferences.scrollbackLines = 0
        XCTAssertEqual(preferences.scrollbackLines, 1)

        preferences.lockTimeoutSeconds = -5
        XCTAssertEqual(preferences.lockTimeoutSeconds, 0)
    }

    // MARK: - Backup

    func testExportContainsExactlyTheAndroidKeys() {
        let exported = preferences.exportSettings()
        XCTAssertEqual(
            Set(exported.keys),
            [
                "confirm_exit",
                "lock_timeout_seconds",
                "invert_terminal_scroll",
                "night_mode",
                "allow_screenshots",
                "scrollback_lines",
                "terminal_font_size",
                "keep_screen_on",
                "terminal_color_scheme",
                "history_suggestions",
                "suggestions_bar_sticky",
                "double_tap_action",
            ]
        )
    }

    /// Security gates and one-time acknowledgements must never travel in a backup.
    func testExportExcludesSecurityGates() {
        let keys = Set(preferences.exportSettings().keys)
        XCTAssertFalse(keys.contains("biometric_lock"))
        XCTAssertFalse(keys.contains("keystore_encryption"))
        XCTAssertFalse(keys.contains("root_warning_acknowledged"))
        XCTAssertFalse(keys.contains("security_reminder_dismissed"))
        XCTAssertFalse(keys.contains("privacy_policy_accepted"))
    }

    func testExportImportRoundTrip() throws {
        preferences.confirmExit = true
        preferences.lockTimeoutSeconds = 300
        preferences.invertTerminalScroll = true
        preferences.nightMode = .light
        preferences.scrollbackLines = 5000
        preferences.terminalFontSize = 20
        preferences.keepScreenOn = true
        preferences.terminalColorScheme = .followApp
        preferences.historySuggestions = false
        preferences.suggestionsBarSticky = true
        preferences.doubleTapAction = .tabTwice

        let exported = preferences.exportSettings()

        let fresh = try makeScratchPreferences(suffix: "fresh")
        fresh.importSettings(exported)

        XCTAssertTrue(fresh.confirmExit)
        XCTAssertEqual(fresh.lockTimeoutSeconds, 300)
        XCTAssertTrue(fresh.invertTerminalScroll)
        XCTAssertEqual(fresh.nightMode, .light)
        XCTAssertEqual(fresh.scrollbackLines, 5000)
        XCTAssertEqual(fresh.terminalFontSize, 20)
        XCTAssertTrue(fresh.keepScreenOn)
        XCTAssertEqual(fresh.terminalColorScheme, .followApp)
        XCTAssertFalse(fresh.historySuggestions)
        XCTAssertTrue(fresh.suggestionsBarSticky)
        XCTAssertEqual(fresh.doubleTapAction, .tabTwice)
    }

    /// The export must survive a trip through real JSON, which is how it reaches
    /// the other platform.
    func testExportIsJSONSerialisable() throws {
        let exported = preferences.exportSettings()
        XCTAssertTrue(JSONSerialization.isValidJSONObject(exported))

        let data = try JSONSerialization.data(withJSONObject: exported)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let fresh = try makeScratchPreferences(suffix: "json")
        fresh.importSettings(decoded)
        XCTAssertEqual(fresh.terminalFontSize, preferences.terminalFontSize)
    }

    /// A second, independent preference store, torn down with the test.
    private func makeScratchPreferences(suffix: String) throws -> AppPreferences {
        let name = "\(suiteName!).\(suffix)"
        let scratch = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { scratch.removePersistentDomain(forName: name) }
        return AppPreferences(defaults: scratch)
    }

    /// A hand-edited backup must not be able to push values out of range or set
    /// an enum to a value the app does not understand.
    func testImportSanitisesHostileValues() {
        preferences.importSettings([
            "terminal_font_size": 10_000,
            "scrollback_lines": -1,
            "lock_timeout_seconds": -60,
            "night_mode": 77,
            "terminal_color_scheme": 99,
            "double_tap_action": -3,
        ])

        XCTAssertEqual(preferences.terminalFontSize, AppPreferences.Limits.maxTerminalFontSize)
        XCTAssertEqual(preferences.scrollbackLines, 1)
        XCTAssertEqual(preferences.lockTimeoutSeconds, 0)
        XCTAssertEqual(preferences.nightMode, .followSystem)
        XCTAssertEqual(preferences.terminalColorScheme, .dark)
        XCTAssertEqual(preferences.doubleTapAction, .none)
    }

    func testImportIgnoresMissingKeys() {
        preferences.terminalFontSize = 20
        preferences.importSettings(["confirm_exit": true])

        XCTAssertTrue(preferences.confirmExit)
        XCTAssertEqual(preferences.terminalFontSize, 20, "an absent key must leave the setting untouched")
    }
}
