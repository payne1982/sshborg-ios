// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers
import Perception

/// Ported from the Android `SettingsScreen`, with the entries that cannot mean
/// anything on iOS left out rather than shown as decoration.
///
/// Three are missing on purpose:
///
/// - **Allow screenshots.** Android has `FLAG_SECURE`; iOS has no equivalent and
///   an app cannot stop a screenshot. The stored value is still round-tripped
///   through backups so it survives a trip to an Android device and back, but a
///   switch that changes nothing would be a lie.
/// - **Confirm exit.** Android asks before Back closes the app. An iOS app is
///   never closed from inside itself — there is no Back out of it — so there is
///   nothing to confirm. It was shown here until 13/09/2026, doing nothing; the
///   value still travels in backups for the same reason as the one above.
/// - **Language.** iOS keeps per-app language in Settings.app, so this offers a
///   link there instead of a picker of its own, which would fight the system.
struct SettingsScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.openURL) private var openURL

    @State private var model: SettingsModel?

    @State private var secretFlow: SettingsScreenSecretFlow?
    @State private var isShowingLockDisclaimer = false
    /// "I understand" was tapped: the sheet opens once the alert is gone.
    @State private var setsSecretAfterDisclaimer = false
    @State private var isMigratingEncryption = false
    @State private var encryptionError: String?
    @State private var isChoosingFile = false
    @State private var isConfirmingImport = false
    @State private var pendingImport: URL?

    private var preferences: AppPreferences { environment.preferences }

    var body: some View {
        WithPerceptionTracking {
            Form {
                generalSection
                terminalSection
                extraBarSection
                sftpSection
                securitySection
                backupSection
                aboutSection
            }
            .navigationTitle(Text(.settingsTitle))
            // The PIN's alert and sheets hang off the screen and not off the
            // section that holds the picker: a sheet attached to a section of a
            // lazily built list is torn down whenever the list rebuilds that
            // section, which it does as the sheet comes up. Measured by the
            // PIN's UI test on 29/10/2026 — the field was there for one query
            // and gone the next.
            .modifier(LockSecretFlows(
                secretFlow: $secretFlow,
                isShowingDisclaimer: $isShowingLockDisclaimer,
                setsSecretAfterDisclaimer: $setsSecretAfterDisclaimer,
                preferences: preferences,
                lock: environment.lock
            ))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                model = model ?? SettingsModel(
                    service: BackupService(
                        hosts: environment.hosts,
                        groups: environment.groups,
                        keys: environment.keys,
                        preferences: environment.preferences
                    )
                )
            }
            .modifier(BackupFileHandling(
                model: model,
                isChoosingFile: $isChoosingFile,
                isConfirmingImport: $isConfirmingImport,
                pendingImport: $pendingImport
            ))
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Picker(String(localized: .settingsThemeTitle), selection: binding(\.nightMode)) {
                Text(.settingsThemeFollowSystem).tag(AppPreferences.NightMode.followSystem)
                Text(.settingsThemeLight).tag(AppPreferences.NightMode.light)
                Text(.settingsThemeDark).tag(AppPreferences.NightMode.dark)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                LabeledContent(String(localized: .settingsLanguage), value: String(localized: .settingsLanguageSystem))
            }
            .tint(.primary)

            // Host list order (#16), last so the footer below reads as its own.
            //
            // Android draws this as one row with the caveat as a supporting
            // line under the title. A `Form` picker cannot: the value has to
            // share the row with the label, and with a two-line label there is
            // nowhere for it to go — photographed twice, once wrapped onto a
            // third line on the left, once with title and subtitle squeezed
            // into two columns beside each other. So the caveat becomes what
            // iOS uses a caveat for, and the row matches every other picker
            // here.
            Picker(String(localized: .settingsHostSortTitle), selection: binding(\.hostSortMode)) {
                ForEach(HostSort.allCases) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
        } header: {
            Text(.settingsSectionGeneral)
        } footer: {
            // Manual also adds "move up / move down" to the menus in the host
            // list; the other modes leave the groups alphabetical and only
            // rearrange the hosts inside them.
            Text(.settingsHostSortSubtitle)
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section(String(localized: .settingsSectionTerminal)) {
            Picker(String(localized: .settingsTerminalColorsTitle), selection: binding(\.terminalColorScheme)) {
                Text(.settingsThemeDark).tag(AppPreferences.TerminalColorScheme.dark)
                Text(.settingsThemeLight).tag(AppPreferences.TerminalColorScheme.light)
                Text(.settingsTerminalColorsFollowApp).tag(AppPreferences.TerminalColorScheme.followApp)
            }

            Picker(String(localized: .settingsDoubleTapTitle), selection: binding(\.doubleTapAction)) {
                Text(.settingsDoubleTapNone).tag(AppPreferences.DoubleTapAction.none)
                Text(.settingsDoubleTapTab).tag(AppPreferences.DoubleTapAction.tab)
                Text(.settingsDoubleTapTabTwice).tag(AppPreferences.DoubleTapAction.tabTwice)
            }

            Stepper(value: binding(\.terminalFontSize),
                    in: AppPreferences.Limits.minTerminalFontSize...AppPreferences.Limits.maxTerminalFontSize) {
                LabeledContent(String(localized: .settingsFontSizeTitle), value: "\(preferences.terminalFontSize)")
            }

            Picker(String(localized: .settingsScrollbackTitle), selection: binding(\.scrollbackLines)) {
                ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { lines in
                    Text(verbatim: "\(lines)").tag(lines)
                }
            }

            Toggle(isOn: binding(\.invertTerminalScroll)) {
                Text(.settingsInvertScrollTitle)
                Text(.settingsInvertScrollSubtitle)
            }

            Toggle(isOn: binding(\.keepScreenOn)) {
                Text(.settingsKeepScreenOnTitle)
                Text(.settingsKeepScreenOnSubtitle)
            }

            // Android offers a second switch next to this one, for hiding the
            // system status bar as well. Not here, and the reason is the notch:
            // with the status bar hidden the top safe area still stops below the
            // sensor housing, so the terminal would gain nothing in portrait and
            // nothing at all in landscape, where that inset moves to the sides.
            // A switch that frees no rows is a switch that promises what it
            // cannot pay.
            Toggle(isOn: binding(\.terminalBarAutoHide)) {
                Text(.settingsTerminalBarAutohideTitle)
                Text(.settingsTerminalBarAutohideSubtitle)
            }

            Toggle(isOn: binding(\.historySuggestions)) {
                Text(.settingsHistorySuggestionsTitle)
                Text(.settingsHistorySuggestionsSubtitle)
            }

            // Nested under the switch above, because a sticky bar for
            // suggestions that are turned off means nothing.
            if preferences.historySuggestions {
                Toggle(isOn: binding(\.suggestionsBarSticky)) {
                    Text(.settingsSuggestionsBarStickyTitle)
                    Text(.settingsSuggestionsBarStickySubtitle)
                }
            }
        }
    }

    // MARK: - Extra key bar

    /// A section of its own, following Android, where the bar was the last of a
    /// long run of terminal switches and read as a cosmetic option rather than
    /// the way into the editor. Its heading carries the context the two rows
    /// then leave out — "Always visible", not "Always-visible extra keys".
    ///
    /// A section rather than Android's grey in-place heading because that is the
    /// same thing here: every header in a grouped form is grey, and the rows keep
    /// following Terminal in the order they had.
    private var extraBarSection: some View {
        Section(String(localized: .settingsSectionExtraBar)) {
            // Which bar the terminal draws, and the way to the list and the
            // editor behind it. The name is read here so choosing another bar
            // — from this list or from the switch key on the bar itself —
            // updates this row.
            NavigationLink {
                ExtraBarsScreen()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(.settingsExtraBarLayoutTitle)
                    Text(inUseLabel)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }

            // The default for new sessions; the pin on the bar overrides it for
            // the open ones, which is why it stays here and not in the editor.
            Toggle(isOn: binding(\.extraKeysBarPinned)) {
                Text(.settingsExtraKeysBarTitle)
                Text(.settingsExtraKeysBarSubtitle)
            }
        }
    }

    /// "In use: Natural ×2", with the argument substituted before it is shown.
    private var inUseLabel: String {
        String(localized: .settingsExtraBarInUse)
            .replacingOccurrences(of: "%1$@", with: preferences.extraBar.localizedName)
    }

    // MARK: - SFTP

    private var sftpSection: some View {
        Section(String(localized: .settingsSectionSftp)) {
            Toggle(isOn: binding(\.sftpSortDirsFirst)) {
                Text(.settingsSftpDirsFirstTitle)
                Text(.settingsSftpDirsFirstSubtitle)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        securitySectionBody
    }

    /// What choosing a lock mode does, which is not always to choose it.
    ///
    /// The PIN is set before it is switched on, and confirmed before it is
    /// switched off — otherwise the picker would be the way round the lock.
    /// Biometrics and the device passcode are refused where the device has
    /// neither, as the disabled picker used to refuse everything.
    private func requestLockMode(_ mode: AppPreferences.LockMode) {
        let current = preferences.lockMode
        guard mode != current else { return }

        if mode == .biometric || mode == .device, !BiometricLock.canAuthenticate() { return }

        if current == .secret, environment.lock.secret.isConfigured {
            secretFlow = .confirmLeaving(mode)
            return
        }
        if mode == .secret {
            isShowingLockDisclaimer = true
            return
        }
        preferences.lockMode = mode
    }

    private var securitySectionBody: some View {
        Section {
            // Three modes rather than a switch, matching Android: "none" is a
            // real choice, and "device lock" lets someone with no biometrics
            // enrolled — or who would rather not use them — still lock the app.
            //
            // And a fourth, the app's own PIN or passphrase, which is why the
            // picker is no longer disabled without biometrics: that one needs
            // nothing of the device. The other two are still refused there, by
            // ``requestLockMode(_:)``, and the footnote below says why.
            Picker(
                String(localized: .settingsAppLockTitle),
                selection: Binding(get: { preferences.lockMode }, set: requestLockMode)
            ) {
                Text(.settingsLockModeNone).tag(AppPreferences.LockMode.none)
                Text(.settingsLockModeBiometric).tag(AppPreferences.LockMode.biometric)
                Text(.settingsLockModeDevice).tag(AppPreferences.LockMode.device)
                Text(.settingsLockModePin).tag(AppPreferences.LockMode.secret)
            }
            // Switching the lock off has to take effect now, not at the next
            // launch: leaving the app locked behind a setting that says it is
            // not would be a puzzle with no way out.
            .onValueChange(of: preferences.lockMode) { _ in
                environment.lock.lockModeChanged()
            }

            if preferences.lockMode == .secret {
                Button(String(localized: .settingsChangeSecret)) { secretFlow = .change }
            }

            if !BiometricLock.canAuthenticate() {
                Text(.settingsBiometricUnavailable)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }

            if preferences.lockMode != .none {
                Picker(String(localized: .settingsLockAfterTitle), selection: binding(\.lockTimeoutSeconds)) {
                    Text(.timeoutImmediately).tag(0)
                    Text(.timeout30Seconds).tag(30)
                    Text(.timeout1Minute).tag(60)
                    Text(.timeout3Minutes).tag(180)
                    Text(.timeout5Minutes).tag(300)
                    Text(.timeout15Minutes).tag(900)
                    Text(.timeout30Minutes).tag(1800)
                }
            }

            // Not bound straight to the preference: flipping the flag alone
            // left everything already saved in the clear underneath a screen
            // saying it was encrypted. The switch has to move the data first and
            // set the flag afterwards, which is what the migration does.
            //
            // The bare read registers this body's dependency on the preference;
            // a Binding's getter is escaping and cannot do it. The getter itself
            // still reads live state — capturing the value here instead would
            // freeze the switch at whatever it was when the screen was drawn.
            // See RootView for what that costs when it drives navigation.
            let _ = preferences.keychainEncryption
            Toggle(
                isOn: Binding(
                    get: { preferences.keychainEncryption },
                    set: { enabled in migrateEncryption(to: enabled) }
                )
            ) {
                Text(.settingsEncryptTitle)
                Text(.settingsEncryptSubtitle)
            }
            .disabled(isMigratingEncryption)

            if isMigratingEncryption {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(.iosEncryptionMigrating)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let encryptionError {
                Text(encryptionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(.settingsSectionSecurity)
        }
    }

    // MARK: - Encryption

    /// Moves the stored credentials, then records the setting.
    ///
    /// The setting is written by the migration and only on success: a switch
    /// that flips while the data behind it did not move is the failure this
    /// whole thing exists to prevent, and a half-done job that says "encrypted"
    /// is worse than one that says nothing.
    private func migrateEncryption(to enabled: Bool) {
        guard !isMigratingEncryption else { return }
        isMigratingEncryption = true
        encryptionError = nil

        Task {
            do {
                if enabled {
                    try await EncryptionMigration.enable(
                        hosts: environment.hosts,
                        keys: environment.keys,
                        preferences: preferences
                    )
                } else {
                    try await EncryptionMigration.disable(
                        hosts: environment.hosts,
                        keys: environment.keys,
                        preferences: preferences
                    )
                }
            } catch {
                encryptionError = error.localizedDescription
            }
            isMigratingEncryption = false
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            backupRow(
                title: .settingsBackupExportTitle,
                detail: .settingsBackupExportSubtitle,
                action: .settingsBackupExportAction
            ) {
                Task { await model?.prepareExport() }
            }

            backupRow(
                title: .settingsBackupImportTitle,
                detail: .settingsBackupImportSubtitle,
                action: .settingsBackupImportAction
            ) {
                isChoosingFile = true
            }
        } header: {
            Text(.settingsSectionBackup)
        }
        // No footer: it repeated the export row's own subtitle word for word,
        // which is what running the app showed. The rows already say it.
    }

    /// A description with its action beside it, which is the shape the Android
    /// screen uses — `ListItem` plus a trailing button.
    ///
    /// The text sits outside the button on purpose. Inside one, SwiftUI resolves
    /// `.secondary` as a dimmer shade of the *accent* colour rather than grey, so
    /// the explanation came out blue and read as part of the link.
    private func backupRow(
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        action: LocalizedStringResource,
        perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Color.secondary)

            Button(String(localized: action), action: perform)
                .buttonStyle(.bordered)
                .disabled(model?.isWorking ?? true)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(String(localized: .settingsSectionAbout)) {
            // Named per platform rather than just "Version": this row is what
            // leaves the app in the screenshot attached to a bug report, and
            // nothing else in that picture says which of the two editions it
            // is. The platform goes in the product name and not beside the
            // number, where "iOS version 1.0" would read as the OS release.
            LabeledContent(String(localized: .iosAboutApp), value: Self.version)
            LabeledContent(String(localized: .aboutLicence), value: "GPL-3.0-or-later")
        }
    }

    /// The marketing version and the build number, which is the only thing
    /// telling two builds of the same version apart. A debug build says so:
    /// it installs beside a store one and is otherwise identical from here.
    private static var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        #if DEBUG
        return "\(short) (\(build)) · debug"
        #else
        return "\(short) (\(build))"
        #endif
    }

    // MARK: - Bindings

    /// `AppPreferences` is observable but not a source of `Binding`s, so each
    /// control gets one built from the key path.
    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<AppPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}

/// The file pickers and the alerts that report what they did.
///
/// Split out because the type checker gives up on a `Form` this size once four
/// more modifiers are chained onto it — the same problem the SFTP screen hit.
private struct BackupFileHandling: ViewModifier {

    let model: SettingsModel?
    @Binding var isChoosingFile: Bool
    @Binding var isConfirmingImport: Bool
    @Binding var pendingImport: URL?

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .fileExporter(
                    isPresented: .init(
                        get: { model?.exportDocument != nil },
                        set: { if !$0 { model?.finishExport(succeeded: false, message: nil) } }
                    ),
                    document: model?.exportDocument,
                    contentType: .json,
                    defaultFilename: model?.suggestedFileName
                ) { result in
                    switch result {
                    case .success:
                        model?.finishExport(succeeded: true, message: nil)
                    case .failure(let error):
                        model?.finishExport(succeeded: false, message: error.localizedDescription)
                    }
                }
                .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.json, .data]) { result in
                    guard case .success(let url) = result else { return }
                    pendingImport = url
                    isConfirmingImport = true
                }
                // Importing merges into what is already there, so it is worth one
                // question first: it can change every host in the list.
                .confirmationDialog(
                    String(localized: .settingsBackupImportTitle),
                    isPresented: $isConfirmingImport,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: .settingsBackupImportAction)) {
                        guard let url = pendingImport else { return }
                        Task { await model?.importBackup(from: url) }
                        pendingImport = nil
                    }
                    Button(String(localized: .actionCancel), role: .cancel) { pendingImport = nil }
                } message: {
                    Text(.settingsBackupImportSubtitle)
                }
                .alert(
                    alertTitle,
                    isPresented: .init(
                        get: { model?.outcome != nil },
                        set: { if !$0 { model?.dismissOutcome() } }
                    )
                ) {
                    Button(String(localized: .actionDone), role: .cancel) { model?.dismissOutcome() }
                } message: {
                    Text(alertMessage)
                }
        }
    }

    private var alertTitle: String {
        String(localized: model?.outcome?.isFailure == true ? .errorUnknown : .actionDone)
    }

    private var alertMessage: String {
        switch model?.outcome {
        case .exported(let hosts):
            return String(localized: .backupExportSuccess).replacingOccurrences(of: "%1$d", with: "\(hosts)")
        case .imported(let inserted, let updated):
            return String(localized: .backupImportSuccess)
                .replacingOccurrences(of: "%1$d", with: "\(inserted)")
                .replacingOccurrences(of: "%2$d", with: "\(updated)")
        case .failed(let message):
            return message
        case nil:
            return ""
        }
    }
}

/// The PIN's disclaimer and sheets, mounted on the settings screen itself.
///
/// See the note where it is applied for why they are not on the section.
private struct LockSecretFlows: ViewModifier {

    @Binding var secretFlow: SettingsScreenSecretFlow?
    @Binding var isShowingDisclaimer: Bool
    @Binding var setsSecretAfterDisclaimer: Bool
    let preferences: AppPreferences
    let lock: AppLock

    func body(content: Content) -> some View {
        content
            // There is no way back from a forgotten secret, so it is said before
            // one is set and not after. Android's wording.
            .alert(String(localized: .lockDisclaimerTitle), isPresented: $isShowingDisclaimer) {
                Button(String(localized: .lockDisclaimerContinue)) { setsSecretAfterDisclaimer = true }
                Button(String(localized: .actionCancel), role: .cancel) {}
            } message: {
                Text(.lockDisclaimerBody)
            }
            // Not from the alert's own button: a sheet presented while an alert
            // is still on its way out can be taken down with it. The button says
            // what to do, and the sheet waits for the alert to have gone.
            .onValueChange(of: isShowingDisclaimer) { showing in
                guard !showing, setsSecretAfterDisclaimer else { return }
                setsSecretAfterDisclaimer = false
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    secretFlow = .set
                }
            }
            .sheet(item: $secretFlow) { flow in
                switch flow {
                case .set, .change:
                    NewSecretSheet(
                        verifyCurrent: flow == .change ? { await lock.secret.check($0) } : nil,
                        onSave: { kind, secret in
                            await lock.secret.set(secret, as: kind)
                            preferences.lockMode = .secret
                            lock.lockModeChanged()
                            secretFlow = nil
                        },
                        onCancel: { secretFlow = nil }
                    )
                case .confirmLeaving(let mode):
                    ConfirmSecretSheet(
                        verify: { await lock.secret.check($0) },
                        onVerified: {
                            // Forgotten, not left behind: a hash nobody uses is a
                            // hash somebody could still try to match.
                            lock.secret.clear()
                            secretFlow = nil
                            preferences.lockMode = mode
                            lock.lockModeChanged()
                        },
                        onCancel: { secretFlow = nil }
                    )
                }
            }
    }
}

/// Where the PIN or passphrase flow is, when one is running.
enum SettingsScreenSecretFlow: Identifiable, Equatable {
    /// A first one, after the disclaimer.
    case set
    /// A new one in place of the current, which is asked for first.
    case change
    /// Leaving the PIN for another mode: the current one first.
    case confirmLeaving(AppPreferences.LockMode)

    var id: String {
        switch self {
        case .set: "set"
        case .change: "change"
        case .confirmLeaving(let mode): "leave-\(mode.rawValue)"
        }
    }
}
