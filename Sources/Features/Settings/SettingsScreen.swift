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
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model = model ?? SettingsModel(
                service: BackupService(
                    hosts: environment.hosts,
                    groups: environment.groups,
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
        Section("General") {
            Toggle(isOn: binding(\.confirmExit)) {
                Text("Confirm before closing a session")
                Text("Ask before disconnecting a terminal.")
            }

            Picker("Appearance", selection: binding(\.nightMode)) {
                Text("Follow system").tag(AppPreferences.NightMode.followSystem)
                Text("Light").tag(AppPreferences.NightMode.light)
                Text("Dark").tag(AppPreferences.NightMode.dark)
            }

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                LabeledContent("Language", value: "System settings")
            }
            .tint(.primary)
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        Section("Terminal") {
            Picker("Colours", selection: binding(\.terminalColorScheme)) {
                Text("Dark").tag(AppPreferences.TerminalColorScheme.dark)
                Text("Light").tag(AppPreferences.TerminalColorScheme.light)
                Text("Follow app").tag(AppPreferences.TerminalColorScheme.followApp)
            }

            Picker("Double tap", selection: binding(\.doubleTapAction)) {
                Text("Nothing").tag(AppPreferences.DoubleTapAction.none)
                Text("Send Tab").tag(AppPreferences.DoubleTapAction.tab)
                Text("Send Tab twice").tag(AppPreferences.DoubleTapAction.tabTwice)
            }

            Stepper(value: binding(\.terminalFontSize),
                    in: AppPreferences.Limits.minTerminalFontSize...AppPreferences.Limits.maxTerminalFontSize) {
                LabeledContent("Font size", value: "\(preferences.terminalFontSize) pt")
            }

            Picker("Scrollback", selection: binding(\.scrollbackLines)) {
                ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { lines in
                    Text("\(lines) lines").tag(lines)
                }
            }

            Toggle(isOn: binding(\.invertTerminalScroll)) {
                Text("Invert scrolling")
                Text("Swipe up to see earlier output.")
            }

            Toggle(isOn: binding(\.keepScreenOn)) {
                Text("Keep the screen on")
                Text("While a terminal is open.")
            }

            Toggle(isOn: binding(\.historySuggestions)) {
                Text("Suggest from shell history")
                Text("Reads the history file on the server over SFTP.")
            }

            // Nested under the switch above, because a sticky bar for
            // suggestions that are turned off means nothing.
            if preferences.historySuggestions {
                Toggle(isOn: binding(\.suggestionsBarSticky)) {
                    Text("Keep the suggestion bar visible")
                }
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        Section {
            Toggle(isOn: binding(\.biometricLock)) {
                Text("Unlock with \(BiometricLock.availability().displayName)")
                Text(BiometricLock.canAuthenticate()
                     ? "Ask to unlock when the app is opened."
                     : "Not set up on this device.")
            }
            .disabled(!BiometricLock.canAuthenticate())

            if preferences.biometricLock {
                Picker("Lock after", selection: binding(\.lockTimeoutSeconds)) {
                    Text("Immediately").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                }
            }

            Toggle(isOn: binding(\.keychainEncryption)) {
                Text("Encrypt saved credentials")
                Text("Passwords and private keys are encrypted with a key held in the keychain.")
            }
        } header: {
            Text("Security")
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            Button {
                Task { await model?.prepareExport() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export hosts")
                    Text("Hosts, groups and settings. No passwords or keys are included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model?.isWorking ?? true)

            Button {
                isChoosingFile = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import hosts")
                    Text("Reads a backup from this app or from SSHBorg for Android.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model?.isWorking ?? true)
        } header: {
            Text("Backup")
        } footer: {
            Text("A backup carries no credentials, so it can be stored and sent like any other file. Existing hosts keep their saved passwords and keys when a backup is imported over them.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.version)
            LabeledContent("Licence", value: "GPL-3.0-or-later")
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
                "Import this backup?",
                isPresented: $isConfirmingImport,
                titleVisibility: .visible
            ) {
                Button("Import") {
                    guard let url = pendingImport else { return }
                    Task { await model?.importBackup(from: url) }
                    pendingImport = nil
                }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: {
                Text("Hosts with the same name are updated, keeping their saved passwords and keys. Other hosts are left alone.")
            }
            .alert(
                alertTitle,
                isPresented: .init(
                    get: { model?.outcome != nil },
                    set: { if !$0 { model?.dismissOutcome() } }
                )
            ) {
                Button("OK", role: .cancel) { model?.dismissOutcome() }
            } message: {
                Text(alertMessage)
            }
    }

    private var alertTitle: String {
        model?.outcome?.isFailure == true ? "Something went wrong" : "Done"
    }

    private var alertMessage: String {
        switch model?.outcome {
        case .exported(let hosts):
            return hosts == 1 ? "Exported 1 host." : "Exported \(hosts) hosts."
        case .imported(let inserted, let updated):
            return "Added \(inserted), updated \(updated)."
        case .failed(let message):
            return message
        case nil:
            return ""
        }
    }
}
