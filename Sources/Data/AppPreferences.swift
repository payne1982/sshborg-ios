// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// User settings, backed by `UserDefaults`.
///
/// This is the iOS counterpart of the Android `AppPreferences` (DataStore).
/// Storage keys, default values and the exported JSON shape are kept identical
/// so a settings backup restores correctly across platforms — see
/// ``exportSettings()``.
///
/// Properties are computed rather than stored so that `UserDefaults` stays the
/// single source of truth; `access` and `withMutation` are what make them
/// observable by SwiftUI.
@Observable
final class AppPreferences {

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredDefaults)
    }

    // MARK: - Keys

    private enum Key {
        static let biometricLock = "biometric_lock"
        static let lockMode = "lock_mode"
        static let extraKeysBarPinned = "extra_keys_bar_pinned"
        static let keychainEncryption = "keystore_encryption"
        static let confirmExit = "confirm_exit"
        static let lockTimeoutSeconds = "lock_timeout_seconds"
        static let jailbreakWarningAcknowledged = "root_warning_acknowledged"
        static let invertTerminalScroll = "invert_terminal_scroll"
        static let nightMode = "night_mode"
        static let allowScreenshots = "allow_screenshots"
        static let scrollbackLines = "scrollback_lines"
        static let terminalFontSize = "terminal_font_size"
        static let keepScreenOn = "keep_screen_on"
        static let terminalColorScheme = "terminal_color_scheme"
        static let doubleTapAction = "double_tap_action"
        static let historySuggestions = "history_suggestions"
        static let suggestionsBarSticky = "suggestions_bar_sticky"
        static let securityReminderDismissed = "security_reminder_dismissed"
        static let privacyPolicyAccepted = "privacy_policy_accepted"
    }

    /// Registered so that an untouched key reads back its Android default rather
    /// than `UserDefaults`' zero/false.
    private static let registeredDefaults: [String: Any] = [
        Key.lockTimeoutSeconds: 60,
        Key.nightMode: NightMode.followSystem.rawValue,
        Key.scrollbackLines: 2000,
        Key.terminalFontSize: Limits.defaultTerminalFontSize,
        Key.terminalColorScheme: TerminalColorScheme.dark.rawValue,
        Key.doubleTapAction: DoubleTapAction.none.rawValue,
        Key.historySuggestions: true,
    ]

    // MARK: - Security

    /// How the app asks to be unlocked.
    ///
    /// Replaces the old `biometric_lock` boolean and reads it when the new key
    /// has never been written, so a user who had biometrics on keeps it after an
    /// update rather than silently losing the lock. That fallback is the whole
    /// reason the old key is still here.
    ///
    /// Deliberately **not** in the settings backup, along with keychain
    /// encryption: both are gates tied to what this device can do, and restoring
    /// one blindly could lock the user out of the app or claim a protection that
    /// is not actually in place.
    var lockMode: LockMode {
        get {
            access(keyPath: \.lockMode)
            if defaults.object(forKey: Key.lockMode) == nil {
                return defaults.bool(forKey: Key.biometricLock) ? .biometric : .none
            }
            return LockMode(rawValue: defaults.integer(forKey: Key.lockMode)) ?? .none
        }
        set { write(newValue.rawValue, Key.lockMode, keyPath: \.lockMode) }
    }

    /// Keeps the extra key row on screen when the keyboard is closed.
    var extraKeysBarPinned: Bool {
        get { read(Key.extraKeysBarPinned, keyPath: \.extraKeysBarPinned) }
        set { write(newValue, Key.extraKeysBarPinned, keyPath: \.extraKeysBarPinned) }
    }

    /// Whether private keys and passwords are stored encrypted. Named
    /// `keystore_encryption` on disk, matching Android.
    var keychainEncryption: Bool {
        get { read(Key.keychainEncryption, keyPath: \.keychainEncryption) }
        set { write(newValue, Key.keychainEncryption, keyPath: \.keychainEncryption) }
    }

    /// Seconds of backgrounding before the app locks. `0` locks immediately.
    var lockTimeoutSeconds: Int {
        get { read(Key.lockTimeoutSeconds, keyPath: \.lockTimeoutSeconds) }
        set { write(max(0, newValue), Key.lockTimeoutSeconds, keyPath: \.lockTimeoutSeconds) }
    }

    var jailbreakWarningAcknowledged: Bool {
        get { read(Key.jailbreakWarningAcknowledged, keyPath: \.jailbreakWarningAcknowledged) }
        set { write(newValue, Key.jailbreakWarningAcknowledged, keyPath: \.jailbreakWarningAcknowledged) }
    }

    var securityReminderDismissed: Bool {
        get { read(Key.securityReminderDismissed, keyPath: \.securityReminderDismissed) }
        set { write(newValue, Key.securityReminderDismissed, keyPath: \.securityReminderDismissed) }
    }

    var privacyPolicyAccepted: Bool {
        get { read(Key.privacyPolicyAccepted, keyPath: \.privacyPolicyAccepted) }
        set { write(newValue, Key.privacyPolicyAccepted, keyPath: \.privacyPolicyAccepted) }
    }

    // MARK: - Appearance and behaviour

    var confirmExit: Bool {
        get { read(Key.confirmExit, keyPath: \.confirmExit) }
        set { write(newValue, Key.confirmExit, keyPath: \.confirmExit) }
    }

    var invertTerminalScroll: Bool {
        get { read(Key.invertTerminalScroll, keyPath: \.invertTerminalScroll) }
        set { write(newValue, Key.invertTerminalScroll, keyPath: \.invertTerminalScroll) }
    }

    var nightMode: NightMode {
        get { NightMode(rawValue: read(Key.nightMode, keyPath: \.nightMode)) ?? .followSystem }
        set { write(newValue.rawValue, Key.nightMode, keyPath: \.nightMode) }
    }

    /// Kept only so that a settings backup round-trips without losing the value.
    ///
    /// iOS has no equivalent of Android's `FLAG_SECURE`: an app cannot prevent
    /// screenshots. There is deliberately no setting for this in the iOS UI —
    /// exposing a toggle that does nothing would be worse than omitting it.
    var allowScreenshots: Bool {
        get { read(Key.allowScreenshots, keyPath: \.allowScreenshots) }
        set { write(newValue, Key.allowScreenshots, keyPath: \.allowScreenshots) }
    }

    var scrollbackLines: Int {
        get { read(Key.scrollbackLines, keyPath: \.scrollbackLines) }
        set { write(max(1, newValue), Key.scrollbackLines, keyPath: \.scrollbackLines) }
    }

    var terminalFontSize: Int {
        get { read(Key.terminalFontSize, keyPath: \.terminalFontSize) }
        set {
            let clamped = min(max(newValue, Limits.minTerminalFontSize), Limits.maxTerminalFontSize)
            write(clamped, Key.terminalFontSize, keyPath: \.terminalFontSize)
        }
    }

    var keepScreenOn: Bool {
        get { read(Key.keepScreenOn, keyPath: \.keepScreenOn) }
        set { write(newValue, Key.keepScreenOn, keyPath: \.keepScreenOn) }
    }

    var terminalColorScheme: TerminalColorScheme {
        get { TerminalColorScheme(rawValue: read(Key.terminalColorScheme, keyPath: \.terminalColorScheme)) ?? .dark }
        set { write(newValue.rawValue, Key.terminalColorScheme, keyPath: \.terminalColorScheme) }
    }

    var doubleTapAction: DoubleTapAction {
        get { DoubleTapAction(rawValue: read(Key.doubleTapAction, keyPath: \.doubleTapAction)) ?? .none }
        set { write(newValue.rawValue, Key.doubleTapAction, keyPath: \.doubleTapAction) }
    }

    var historySuggestions: Bool {
        get { read(Key.historySuggestions, keyPath: \.historySuggestions) }
        set { write(newValue, Key.historySuggestions, keyPath: \.historySuggestions) }
    }

    var suggestionsBarSticky: Bool {
        get { read(Key.suggestionsBarSticky, keyPath: \.suggestionsBarSticky) }
        set { write(newValue, Key.suggestionsBarSticky, keyPath: \.suggestionsBarSticky) }
    }

    // MARK: - Observable plumbing

    // `bool(forKey:)` and `integer(forKey:)` honour the registered defaults, so
    // an untouched key already reads back the Android default. The key path is
    // only there to drive observation; it is generic over the property type
    // because several properties are enums rather than raw integers.

    private func read<V>(_ key: String, keyPath: KeyPath<AppPreferences, V>) -> Bool {
        access(keyPath: keyPath)
        return defaults.bool(forKey: key)
    }

    private func read<V>(_ key: String, keyPath: KeyPath<AppPreferences, V>) -> Int {
        access(keyPath: keyPath)
        return defaults.integer(forKey: key)
    }

    private func write<T, V>(_ value: T, _ key: String, keyPath: KeyPath<AppPreferences, V>) {
        withMutation(keyPath: keyPath) {
            defaults.set(value, forKey: key)
        }
    }
}

// MARK: - Enumerations

extension AppPreferences {

    /// Raw values match Android's `AppCompatDelegate` constants, because they are
    /// written verbatim into the shared JSON backup.
    /// Matching the Android constants exactly, because the value is stored and
    /// compared across platforms in every other preference.
    enum LockMode: Int, CaseIterable {
        case none = 0
        /// Biometrics, falling back to the device passcode when none is enrolled.
        case biometric = 1
        /// Passcode or biometrics, whichever the user prefers.
        case device = 2
    }

    enum NightMode: Int, CaseIterable {
        case followSystem = -1
        case light = 1
        case dark = 2
    }

    enum TerminalColorScheme: Int, CaseIterable {
        case dark = 0
        case light = 1
        case followApp = 2
    }

    enum DoubleTapAction: Int, CaseIterable {
        case none = 0
        case tab = 1
        case tabTwice = 2
    }

    enum Limits {
        static let defaultTerminalFontSize = 13
        static let minTerminalFontSize = 8
        static let maxTerminalFontSize = 32
    }
}

// MARK: - Settings backup

extension AppPreferences {

    /// Snapshot of the backup-eligible settings.
    ///
    /// Deliberately excluded, matching Android: ``biometricLock`` and
    /// ``keychainEncryption`` (security gates tied to this device's actual
    /// capabilities — restoring them blindly could lock the user out or claim
    /// data is encrypted when it is not), and the one-time acknowledgement flags,
    /// which should reappear on a fresh install.
    ///
    /// Every key is always written, using the same default the getters fall back
    /// to. Otherwise a restore could only ever affect settings the user had
    /// already changed.
    func exportSettings() -> [String: Any] {
        [
            "confirm_exit": confirmExit,
            "lock_timeout_seconds": lockTimeoutSeconds,
            "invert_terminal_scroll": invertTerminalScroll,
            "night_mode": nightMode.rawValue,
            "allow_screenshots": allowScreenshots,
            "scrollback_lines": scrollbackLines,
            "terminal_font_size": terminalFontSize,
            "keep_screen_on": keepScreenOn,
            "terminal_color_scheme": terminalColorScheme.rawValue,
            "history_suggestions": historySuggestions,
            "suggestions_bar_sticky": suggestionsBarSticky,
            "double_tap_action": doubleTapAction.rawValue,
        ]
    }

    /// Applies a snapshot produced by ``exportSettings()``, on either platform.
    /// Missing keys are left untouched; bounded values are clamped by the
    /// setters, which guards against hand-edited backups.
    func importSettings(_ object: [String: Any]) {
        if let value = object["confirm_exit"] as? Bool { confirmExit = value }
        if let value = object["lock_timeout_seconds"] as? Int { lockTimeoutSeconds = value }
        if let value = object["invert_terminal_scroll"] as? Bool { invertTerminalScroll = value }
        if let value = object["night_mode"] as? Int { nightMode = NightMode(rawValue: value) ?? .followSystem }
        if let value = object["allow_screenshots"] as? Bool { allowScreenshots = value }
        if let value = object["scrollback_lines"] as? Int { scrollbackLines = value }
        if let value = object["terminal_font_size"] as? Int { terminalFontSize = value }
        if let value = object["keep_screen_on"] as? Bool { keepScreenOn = value }
        if let value = object["terminal_color_scheme"] as? Int {
            terminalColorScheme = TerminalColorScheme(rawValue: value) ?? .dark
        }
        if let value = object["history_suggestions"] as? Bool { historySuggestions = value }
        if let value = object["suggestions_bar_sticky"] as? Bool { suggestionsBarSticky = value }
        if let value = object["double_tap_action"] as? Int {
            doubleTapAction = DoubleTapAction(rawValue: value) ?? .none
        }
    }
}
