// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// Creates or edits a host. Ported from the Android `AddEditHostScreen`.
///
/// Jump hosts and port forwarding are stored here but only acted on from phase
/// 7, when the SSH layer learns to build a chain. They are editable now so that
/// a configuration restored from an Android backup survives a round trip
/// through this form instead of being silently dropped.
struct HostEditorScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates a new host.
    let host: Host?

    // Core
    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMode: AuthMode = .password
    @State private var password = ""
    @State private var keyId: Int64?
    @State private var color: Int?
    @State private var groupId: Int64?

    // Advanced
    @State private var agentForwarding = false
    @State private var allowLegacyCiphers = false
    @State private var mosh = false
    @State private var moshFamily: SSHSocket.AddressPreference = .auto
    @State private var moshPorts = ""
    @State private var moshCommand = ""
    // The default for a host being created; `load(from:)` overwrites it for one
    // being edited. It follows the column's own default — see `Host.jumpMode`.
    @State private var jumpMode: Host.JumpMode = .hostList
    @State private var jumpHostsText = ""
    @State private var jumpHostIds: [Int64] = []
    @State private var portForwardingsText = ""
    @State private var sftpStartMode: Host.SFTPStartMode = .last
    @State private var sftpStartDir = ""
    @State private var sftpShowHidden = false
    @State private var resetHostKeys = false

    // Loaded lists
    @State private var availableKeys: [SSHKey] = []
    @State private var availableGroups: [HostGroup] = []
    @State private var jumpCandidates: [Host] = []
    @State private var unusableJumpCandidateCount = 0

    @State private var isCreatingGroup = false
    @State private var saveError: String?
    @State private var isLoaded = false

    /// No raw values: they were being shown on screen, untranslated. The names
    /// the user reads come from the catalog at the picker.
    private enum AuthMode {
        case password
        case key
    }

    private var isValid: Bool {
        !label.trimmed.isEmpty && !hostname.trimmed.isEmpty && !username.trimmed.isEmpty
    }

    private var hasStoredHostKeys: Bool {
        guard let host else { return false }
        return host.knownHostsEntry != nil || host.jumpHostKeys != nil
    }

    var body: some View {
        WithPerceptionTracking {
            Form {
                basicsSection
                groupSection
                colourSection
                authenticationSection
                optionsSection
                moshSection
                jumpHostsSection
                portForwardingSection
                startDirectorySection
                if hasStoredHostKeys { hostKeysSection }
            }
            .navigationTitle(host == nil ? "New host" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: .actionCancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: .actionSave)) { save() }
                        .disabled(!isValid)
                }
            }
            .task {
                guard !isLoaded else { return }
                isLoaded = true
                await loadLists()
                load()
            }
            .sheet(isPresented: $isCreatingGroup) {
                NavigationStack {
                    GroupEditorScreen(group: nil) { created in
                        // Select it straight away: creating a group from here means
                        // the user wants this host in it.
                        availableGroups.append(created)
                        groupId = created.id
                    }
                }
            }
            .alert(String(localized: .iosErrorSaveFailed), isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button(String(localized: .actionDone), role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: - Sections

    /// The four fields the keyboard's Next key walks through, in order.
    private enum CoreField: Hashable {
        case label, hostname, username, port
    }

    @FocusState private var focusedField: CoreField?

    private var basicsSection: some View {
        Section {
            TextField(String(localized: .hostFieldLabel), text: $label)
                .plainTextEntry()
                .focused($focusedField, equals: .label)
                .submitLabel(.next)
                .onSubmit { focusedField = .hostname }
            TextField(String(localized: .hostFieldHostname), text: $hostname)
                .keyboardType(.URL)
                .plainTextEntry()
                .focused($focusedField, equals: .hostname)
                .submitLabel(.next)
                .onSubmit { focusedField = .username }
            TextField(String(localized: .hostFieldUsername), text: $username)
                .plainTextEntry()
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .port }
            // The chain ends here rather than at Done: the number pad has no
            // return key to press, so a submit label on it would be a promise
            // the keyboard cannot keep.
            TextField(String(localized: .hostFieldPort), text: $port)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .port)
        }
    }

    private var groupSection: some View {
        Section(String(localized: .hostGroupLabel)) {
            Picker(String(localized: .hostGroupLabel), selection: $groupId) {
                Text(.hostGroupNone).tag(Int64?.none)
                ForEach(availableGroups) { group in
                    Text(group.name).tag(Int64?.some(group.id ?? -1))
                }
            }
            Button(String(localized: .hostGroupNew)) { isCreatingGroup = true }
        }
    }

    private var colourSection: some View {
        Section {
            ColorSwatchPicker(selection: $color)
        } header: {
            Text(.hostColorLabel)
        } footer: {
            Text(.iosHostColourFooter)
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section(String(localized: .hostSectionAuthentication)) {
            // No label, and the two choices named from the catalog: the raw enum
            // values were English text on screen in every language, and labelling
            // the picker "Password" made one of its own options its title.
            Picker(selection: $authMode) {
                Text(.hostAuthPassword).tag(AuthMode.password)
                Text(.hostAuthSshKey).tag(AuthMode.key)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            switch authMode {
            case .password:
                SecureField(String(localized: .hostFieldPassword), text: $password)
                    .plainTextEntry()

            case .key:
                if availableKeys.isEmpty {
                    Text(.hostKeyNoKeys)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: .hostAuthSshKey), selection: $keyId) {
                        // Was `host_group_none` — "No group" — in a list of keys.
                        // Android's own placeholder, already translated.
                        Text(.hostKeySelectPlaceholder).tag(Int64?.none)
                        ForEach(availableKeys) { key in
                            Text(key.label).tag(Int64?.some(key.id ?? -1))
                        }
                    }
                    // A pushed list, not the default pull-down menu: key labels
                    // are long, and a menu crushed them into a strip that was
                    // hard to read and harder to aim at.
                    .pickerStyle(.navigationLink)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(String(localized: .hostAgentForwarding), isOn: $agentForwarding)
            Toggle(String(localized: .hostAllowLegacyCiphers), isOn: $allowLegacyCiphers)
        } footer: {
            // No header: these belong to the authentication block above, which
            // is how Android groups them. Repeating "Authentication" made the
            // form look like it asked the same thing twice.
            Text(.iosHostLegacyFooter)
        }
    }

    /// The switch, and the three settings it reveals.
    ///
    /// Immediately above the jump-host section, as on Android, and for the same
    /// two reasons: the settings it opens are the next thing you see, and the
    /// section whose first hop can change what mosh does is the one after.
    ///
    /// The three settings are about somebody else's network and somebody else's
    /// server, so none of them can be decided here — they belong to the machine
    /// that runs `mosh-server`. They are hidden with the chain rather than
    /// disabled, because three settings for a session that will not happen read
    /// as a promise, and their values are kept, so clearing the chain brings
    /// them back as they were.
    @ViewBuilder
    private var moshSection: some View {
        Section {
            // Off and immovable while a chain exists, and the footer says why.
            // An exclusion enforced from one side only is not one: Android's
            // `dfd57ff` is the commit that found that out.
            Toggle(isOn: $mosh) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(.hostMoshLabel)
                    Text(.hostMoshExperimental)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(jumpConfigured)

            if mosh, !jumpConfigured {
                Picker(String(localized: .hostMoshFamilyLabel), selection: $moshFamily) {
                    Text(.hostMoshFamilyAuto).tag(SSHSocket.AddressPreference.auto)
                    Text(.hostMoshFamilyIpv4).tag(SSHSocket.AddressPreference.ipv4)
                    Text(.hostMoshFamilyIpv6).tag(SSHSocket.AddressPreference.ipv6)
                }

                TextField(
                    String(localized: .hostMoshPortsLabel),
                    text: $moshPorts,
                    prompt: Text(.hostMoshPortsPlaceholder)
                )
                .keyboardType(.URL)
                .plainTextEntry()

                TextField(
                    String(localized: .hostMoshCommandLabel),
                    text: $moshCommand,
                    prompt: Text(.hostMoshCommandPlaceholder)
                )
                .keyboardType(.URL)
                .plainTextEntry()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if jumpConfigured {
                    // Why the switch will not move, and nothing else. What
                    // happens *instead* depends on the first hop, so it is said
                    // where the first hop is chosen.
                    Text(.hostMoshDisabledWithJump)
                } else if mosh {
                    Text(.hostMoshFamilySupporting)
                    Text(.hostMoshPortsSupporting)
                    Text(.hostMoshCommandSupporting)
                }
            }
        }
    }

    /// Whether this host already has a chain for SSH to walk, in whichever of
    /// the two ways the form offers.
    ///
    /// A row can arrive with both this and mosh set — an older database, a
    /// backup edited by hand — and that is why it is a question about the fields
    /// rather than about the switch.
    private var jumpConfigured: Bool {
        Host.jumpConfigured(mode: jumpMode, text: jumpHostsText, hostIDs: jumpHostIds)
    }

    @ViewBuilder
    private var jumpHostsSection: some View {
        Section {
            // No label: the section header already says what this chooses, and
            // labelling it repeated a word that was also one of the options —
            // the row read "Simple: Simple" when that option was still called
            // Simple. Android has the same shape, a group of choices under the
            // section title.
            //
            // The host list first, because it is the default: the selected one
            // on the left, and the one on the left is the one that can carry a
            // hop's own key or password. The text field keeps its place as the
            // fallback, for a hop that is not a host of yours.
            // Mosh and a chain exclude each other, so while mosh is on there is
            // nothing here to build one with. What stays is the line that says
            // how to reach a host *through* a mosh bastion, which is what
            // somebody who has arrived in this corner is usually after.
            //
            // `jumpConfigured` is in the condition because a row can arrive with
            // both set. The switch above already shows off in that case, so the
            // section stays usable: a chain that exists can be seen and removed
            // rather than hidden behind a switch the form says is off.
            if mosh, !jumpConfigured {
                Text(.hostJumpMoshChain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                jumpHostsPicker
            }
        } header: {
            Text(.hostSectionJumpHosts)
        } footer: {
            if !(mosh && !jumpConfigured) { jumpHostsFooter }
        }
    }

    @ViewBuilder
    private var jumpHostsPicker: some View {
        Group {
            Picker(selection: $jumpMode) {
                Text(.hostJumpModeHostList).tag(Host.JumpMode.hostList)
                Text(.hostJumpModeSimple).tag(Host.JumpMode.simple)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            switch jumpMode {
            case .simple:
                TextField(String(localized: .hostJumpHostsPlaceholder), text: $jumpHostsText)
                    .keyboardType(.URL)
                    .plainTextEntry()

            case .hostList:
                if jumpCandidates.isEmpty {
                    Text(.iosHostNoJumpCandidates)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(jumpHostIds.enumerated()), id: \.offset) { index, selected in
                        HStack {
                            Picker(String(localized: .iosHostHopNumber).replacingOccurrences(of: "%1$d", with: "\(index + 1)"), selection: binding(forHopAt: index)) {
                                Text(.hostJumpSelectPlaceholder).tag(Int64(0))
                                ForEach(jumpCandidates) { candidate in
                                    Text(candidate.label).tag(candidate.id ?? -1)
                                }
                            }
                            Button(String(localized: .hostColorRemove), systemImage: "minus.circle.fill") {
                                jumpHostIds.remove(at: index)
                            }
                            .labelStyle(.iconOnly)
                            .tint(.red)
                            .buttonStyle(.plain)
                        }
                        .id(selected)
                    }

                    Button(String(localized: .hostJumpAdd), systemImage: "plus") {
                        jumpHostIds.append(0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var jumpHostsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch jumpMode {
            case .simple:
                Text(.hostJumpHostsSupporting)
            case .hostList:
                Text(.hostJumpModeHostList)
                if unusableJumpCandidateCount > 0 {
                    Text(String(localized: .iosHostHiddenCandidates).replacingOccurrences(of: "%1$d", with: "\(unusableJumpCandidateCount)"))
                }
            }
        }
    }

    private var portForwardingSection: some View {
        Section {
            TextField(
                String(localized: .hostPortForwardingPlaceholder),
                text: $portForwardingsText,
                axis: .vertical
            )
            .lineLimit(2...6)
            .keyboardType(.URL)
            .plainTextEntry()
        } header: {
            Text(.hostSectionPortForwarding)
        } footer: {
            Text(.hostPortForwardingSupporting)
        }
    }

    private var startDirectorySection: some View {
        Section {
            // Unlabelled for the same reason: labelling it with the section
            // title printed "SFTP: Starting Directory" twice, once as the header
            // and once on the row underneath.
            Picker(selection: $sftpStartMode) {
                Text(.hostStartModeLast).tag(Host.SFTPStartMode.last)
                Text(.hostStartModeFixed).tag(Host.SFTPStartMode.fixed)
                Text(.hostStartModeHome).tag(Host.SFTPStartMode.home)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            // Editable only for a fixed path: the other two modes are computed,
            // so an editable field would imply a choice that is not there.
            TextField(String(localized: .hostFieldStartDirectory), text: sftpStartMode == .home ? .constant("~") : $sftpStartDir)
                .disabled(sftpStartMode != .fixed)
                .foregroundStyle(sftpStartMode == .fixed ? .primary : .secondary)
                .plainTextEntry()

            // The same field the browser's own toggle writes, so the two never
            // disagree about a host.
            Toggle(String(localized: .hostSftpShowHidden), isOn: $sftpShowHidden)
        } header: {
            Text(.hostSectionStartDirectory)
        }
    }

    private var hostKeysSection: some View {
        Section {
            Toggle(String(localized: .hostResetHostKeys), isOn: $resetHostKeys)
        } header: {
            Text(.hostResetHostKeys)
        } footer: {
            Text(.hostResetHostKeysHint)
        }
    }

    // MARK: - Hop binding

    /// Reads and writes one row of the hop list.
    private func binding(forHopAt index: Int) -> Binding<Int64> {
        Binding(
            get: { jumpHostIds.indices.contains(index) ? jumpHostIds[index] : 0 },
            set: { newValue in
                guard jumpHostIds.indices.contains(index) else { return }
                jumpHostIds[index] = newValue
            }
        )
    }

    // MARK: - Loading

    private func loadLists() async {
        availableKeys = (try? await environment.keys.fetchAll()) ?? []
        availableGroups = (try? await environment.groups.fetchAll()) ?? []

        let all = (try? await environment.hosts.fetchAll()) ?? []
        // A hop authenticates without anyone at the keyboard, so a host with no
        // saved credential cannot serve as one. Same rule as Android, which
        // greys those entries out.
        let others = all.filter { $0.id != host?.id }
        jumpCandidates = others.filter(\.canBeJumpHost)
        unusableJumpCandidateCount = others.count - jumpCandidates.count
    }

    private func load() {
        guard let host else { return }

        label = host.label
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        color = host.color
        groupId = host.groupId
        keyId = host.keyId
        authMode = host.keyId == nil ? .password : .key
        password = KeychainCrypto.password(for: host) ?? ""

        agentForwarding = host.agentForwarding
        allowLegacyCiphers = host.allowLegacyCiphers
        mosh = host.mosh
        moshFamily = SSHSocket.AddressPreference(column: host.moshFamily)
        moshPorts = host.moshPorts ?? ""
        moshCommand = host.moshCommand ?? ""
        jumpMode = host.parsedJumpMode
        jumpHostsText = host.jumpHosts ?? ""
        jumpHostIds = host.jumpHostIDs
        portForwardingsText = host.portForwardings ?? ""
        sftpStartMode = host.parsedSFTPStartMode
        sftpStartDir = host.sftpStartDir ?? ""
        sftpShowHidden = host.sftpShowHidden
    }

    // MARK: - Saving

    private func save() {
        // Start from the stored record so anything this form does not show
        // survives the edit.
        var updated = host ?? Host(label: "", hostname: "", username: "")

        updated.label = label.trimmed
        updated.hostname = hostname.trimmed
        updated.username = username.trimmed
        updated.port = Int(port) ?? 22
        updated.color = color
        updated.groupId = groupId

        switch authMode {
        case .password: updated.keyId = nil
        case .key: updated.keyId = keyId
        }

        updated.agentForwarding = agentForwarding
        updated.allowLegacyCiphers = allowLegacyCiphers
        // The switch cannot be on together with a chain: the form enforces it
        // from both sides, and a row that arrived with both — an older
        // database, a hand-edited backup — is saved with mosh off, which is what
        // the form was showing.
        updated.mosh = mosh && !jumpConfigured
        updated.moshFamily = moshFamily.rawValue
        updated.moshPorts = moshPorts.trimmed.nilIfEmpty
        updated.moshCommand = moshCommand.trimmed.nilIfEmpty
        updated.jumpMode = jumpMode.rawValue
        updated.jumpHosts = jumpHostsText.trimmed.nilIfEmpty
        // Drops unfilled rows rather than storing a hop with no host.
        updated.jumpHostIdList = Host.formatIDList(jumpHostIds)
        updated.portForwardings = portForwardingsText.trimmed.nilIfEmpty
        updated.sftpStartMode = sftpStartMode.rawValue
        updated.sftpShowHidden = sftpShowHidden
        updated.sftpStartDir = sftpStartMode == .fixed ? sftpStartDir.trimmed.nilIfEmpty : updated.sftpStartDir

        if resetHostKeys {
            updated.knownHostsEntry = nil
            updated.jumpHostKeys = nil
        }

        do {
            try applyPassword(to: &updated)
        } catch {
            saveError = error.localizedDescription
            return
        }

        let record = updated
        Task {
            do {
                try await environment.hosts.save(record)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Writes the password the way the Android app does: encrypted into
    /// `encryptedPassword` when the setting is on, plaintext otherwise, and
    /// never both at once.
    private func applyPassword(to host: inout Host) throws {
        guard authMode == .password, !password.isEmpty else {
            host.password = nil
            host.encryptedPassword = nil
            return
        }

        if environment.preferences.keychainEncryption {
            host.encryptedPassword = try KeychainCrypto.encrypt(password)
            host.password = nil
        } else {
            host.password = password
            host.encryptedPassword = nil
        }
    }
}

extension String {
    /// Whitespace-trimmed, which is what every one of these fields wants: a
    /// hostname with a stray space is a connection failure with a baffling
    /// error message.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` rather than `""`, matching how the schema stores "not set".
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
