// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Ported from the Android `SettingsScreen`, with the entries that cannot mean
/// anything on iOS left out rather than shown as decoration.
///
/// Two are missing on purpose:
///
/// - **Allow screenshots.** Android has `FLAG_SECURE`; iOS has no equivalent and
///   an app cannot stop a screenshot. The stored value is still round-tripped
///   through backups so it survives a trip to an Android device and back, but a
///   switch that changes nothing would be a lie.
/// - **Language.** iOS keeps per-app language in Settings.app, so this offers a
///   link there instead of a picker of its own, which would fight the system.
struct SettingsScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.openURL) private var openURL

    @State private var model: SettingsModel?
    @State private var isChoosingFile = false
    @State private var isConfirmingImport = false
    @State private var pendingImport: URL?

    private var preferences: AppPreferences { environment.preferences }

    var body: some View {
        Form {
            generalSection
            terminalSection
            securitySection
            backupSection
            aboutSection
        }
        .navigationTitle(Text(.settingsTitle))
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

    // MARK: - General

    private var generalSection: some View {
        Section(String(localized: .settingsSectionGeneral)) {
            Toggle(isOn: binding(\.confirmExit)) {
                Text(.settingsConfirmExitTitle)
                Text(.settingsConfirmExitSubtitle)
            }

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

            Toggle(isOn: binding(\.extraKeysBarPinned)) {
                Text(.settingsExtraKeysBarTitle)
                Text(.settingsExtraKeysBarSubtitle)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            // Three modes rather than a switch, matching Android: "none" is a
            // real choice, and "device lock" lets someone with no biometrics
            // enrolled — or who would rather not use them — still lock the app.
            Picker(String(localized: .settingsAppLockTitle), selection: binding(\.lockMode)) {
                Text(.settingsLockModeNone).tag(AppPreferences.LockMode.none)
                Text(.settingsLockModeBiometric).tag(AppPreferences.LockMode.biometric)
                Text(.settingsLockModeDevice).tag(AppPreferences.LockMode.device)
            }
            .disabled(!BiometricLock.canAuthenticate())

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

            Toggle(isOn: binding(\.keychainEncryption)) {
                Text(.settingsEncryptTitle)
                Text(.settingsEncryptSubtitle)
            }
        } header: {
            Text(.settingsSectionSecurity)
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
        Section(String(localized: .aboutSectionTitle)) {
            LabeledContent(String(localized: .aboutVersion), value: Self.version)
            LabeledContent(String(localized: .aboutLicence), value: "GPL-3.0-or-later")
        }
    }

    private static var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
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
