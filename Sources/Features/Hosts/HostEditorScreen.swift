// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

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
    @State private var jumpMode: Host.JumpMode = .simple
    @State private var jumpHostsText = ""
    @State private var jumpHostIds: [Int64] = []
    @State private var portForwardingsText = ""
    @State private var sftpStartMode: Host.SFTPStartMode = .last
    @State private var sftpStartDir = ""
    @State private var resetHostKeys = false

    // Loaded lists
    @State private var availableKeys: [SSHKey] = []
    @State private var availableGroups: [HostGroup] = []
    @State private var jumpCandidates: [Host] = []
    @State private var unusableJumpCandidateCount = 0

    @State private var isCreatingGroup = false
    @State private var saveError: String?
    @State private var isLoaded = false

    private enum AuthMode: String, CaseIterable {
        case password = "Password"
        case key = "SSH key"
    }

    private var isValid: Bool {
        !label.trimmed.isEmpty && !hostname.trimmed.isEmpty && !username.trimmed.isEmpty
    }

    private var hasStoredHostKeys: Bool {
        guard let host else { return false }
        return host.knownHostsEntry != nil || host.jumpHostKeys != nil
    }

    var body: some View {
        Form {
            basicsSection
            groupSection
            colourSection
            authenticationSection
            optionsSection
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
        .alert("Could not save", isPresented: .init(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(String(localized: .actionDone), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Sections

    private var basicsSection: some View {
        Section {
            TextField(String(localized: .hostFieldLabel), text: $label)
            TextField(String(localized: .hostFieldHostname), text: $hostname)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField(String(localized: .hostFieldUsername), text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField(String(localized: .hostFieldPort), text: $port)
                .keyboardType(.numberPad)
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
            Text("Without a colour of its own, a host takes its group's.")
        }
    }

    @ViewBuilder
    private var authenticationSection: some View {
        Section(String(localized: .hostSectionAuthentication)) {
            Picker(String(localized: .hostAuthPassword), selection: $authMode) {
                ForEach(AuthMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch authMode {
            case .password:
                SecureField(String(localized: .hostFieldPassword), text: $password)

            case .key:
                if availableKeys.isEmpty {
                    Text(.hostKeyNoKeys)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: .hostAuthSshKey), selection: $keyId) {
                        Text(.hostGroupNone).tag(Int64?.none)
                        ForEach(availableKeys) { key in
                            Text(key.label).tag(Int64?.some(key.id ?? -1))
                        }
                    }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(String(localized: .hostAgentForwarding), isOn: $agentForwarding)
            Toggle(String(localized: .hostAllowLegacyCiphers), isOn: $allowLegacyCiphers)
        } header: {
            Text("Options")
        } footer: {
            Text("Legacy ciphers let you reach old servers, at the cost of weaker cryptography. Leave off unless a server refuses to connect.")
        }
    }

    @ViewBuilder
    private var jumpHostsSection: some View {
        Section {
            Picker(String(localized: .hostJumpModeSimple), selection: $jumpMode) {
                Text(.hostJumpModeSimple).tag(Host.JumpMode.simple)
                Text(.hostJumpModeHostList).tag(Host.JumpMode.hostList)
            }
            .pickerStyle(.segmented)

            switch jumpMode {
            case .simple:
                TextField(String(localized: .hostJumpHostsPlaceholder), text: $jumpHostsText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

            case .hostList:
                if jumpCandidates.isEmpty {
                    Text("No other host has a saved credential to use as a hop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(jumpHostIds.enumerated()), id: \.offset) { index, selected in
                        HStack {
                            Picker("Hop \(index + 1)", selection: binding(forHopAt: index)) {
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
        } header: {
            Text(.hostSectionJumpHosts)
        } footer: {
            jumpHostsFooter
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
                    Text("\(unusableJumpCandidateCount) host(s) are not listed because they have no saved password or key, which a hop cannot prompt for.")
                }
            }
            Text("Tunnelling itself arrives in a later version; the setting is stored now.")
                .foregroundStyle(.secondary)
        }
    }

    private var portForwardingSection: some View {
        Section {
            TextField(
                "8080:localhost:8080",
                text: $portForwardingsText,
                axis: .vertical
            )
            .lineLimit(2...6)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text(.hostSectionPortForwarding)
        } footer: {
            Text("One rule per line: [bindAddr:]localPort:remoteHost:remotePort. An -L prefix is accepted. Forwarding starts working in a later version.")
        }
    }

    private var startDirectorySection: some View {
        Section {
            Picker(String(localized: .hostSectionStartDirectory), selection: $sftpStartMode) {
                Text(.hostStartModeLast).tag(Host.SFTPStartMode.last)
                Text(.hostStartModeFixed).tag(Host.SFTPStartMode.fixed)
                Text(.hostStartModeHome).tag(Host.SFTPStartMode.home)
            }

            // Editable only for a fixed path: the other two modes are computed,
            // so an editable field would imply a choice that is not there.
            TextField(String(localized: .hostFieldStartDirectory), text: sftpStartMode == .home ? .constant("~") : $sftpStartDir)
                .disabled(sftpStartMode != .fixed)
                .foregroundStyle(sftpStartMode == .fixed ? .primary : .secondary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
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
        jumpMode = host.parsedJumpMode
        jumpHostsText = host.jumpHosts ?? ""
        jumpHostIds = host.jumpHostIDs
        portForwardingsText = host.portForwardings ?? ""
        sftpStartMode = host.parsedSFTPStartMode
        sftpStartDir = host.sftpStartDir ?? ""
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
        updated.jumpMode = jumpMode.rawValue
        updated.jumpHosts = jumpHostsText.trimmed.nilIfEmpty
        // Drops unfilled rows rather than storing a hop with no host.
        updated.jumpHostIdList = Host.formatIDList(jumpHostIds)
        updated.portForwardings = portForwardingsText.trimmed.nilIfEmpty
        updated.sftpStartMode = sftpStartMode.rawValue
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
