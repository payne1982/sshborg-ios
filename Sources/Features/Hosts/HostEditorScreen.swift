// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Creates or edits a host. Ported from the Android `AddEditHostScreen`.
///
/// Only the core fields are here so far; jump hosts, port forwarding and the
/// SFTP start directory arrive with phase 4c. Editing therefore starts from the
/// stored record and changes only what is on screen — otherwise saving would
/// quietly erase settings this form cannot yet show.
struct HostEditorScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates a new host.
    let host: Host?

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMode: AuthMode = .password
    @State private var password = ""
    @State private var keyId: Int64?
    @State private var color: Int?

    @State private var groupId: Int64?
    @State private var availableKeys: [SSHKey] = []
    @State private var availableGroups: [HostGroup] = []
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

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $label)
                TextField("Hostname", text: $hostname)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
            }

            Section("Group") {
                Picker("Group", selection: $groupId) {
                    Text("None").tag(Int64?.none)
                    ForEach(availableGroups) { group in
                        Text(group.name).tag(Int64?.some(group.id ?? -1))
                    }
                }
                Button("New group…") { isCreatingGroup = true }
            }

            Section {
                ColorSwatchPicker(selection: $color)
            } header: {
                Text("Colour")
            } footer: {
                Text("Without a colour of its own, a host takes its group's.")
            }

            Section("Authentication") {
                Picker("Method", selection: $authMode) {
                    ForEach(AuthMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch authMode {
                case .password:
                    SecureField("Password", text: $password)

                case .key:
                    if availableKeys.isEmpty {
                        Text("No keys yet. Key management arrives in a later version.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Key", selection: $keyId) {
                            Text("None").tag(Int64?.none)
                            ForEach(availableKeys) { key in
                                Text(key.label).tag(Int64?.some(key.id ?? -1))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host == nil ? "New host" : "Edit host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .task {
            guard !isLoaded else { return }
            isLoaded = true
            availableKeys = (try? await environment.keys.fetchAll()) ?? []
            availableGroups = (try? await environment.groups.fetchAll()) ?? []
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
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Loading and saving

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
    }

    private func save() {
        // Start from the stored record so fields this form does not show yet
        // survive the edit.
        var updated = host ?? Host(label: "", hostname: "", username: "")

        updated.label = label.trimmed
        updated.hostname = hostname.trimmed
        updated.username = username.trimmed
        updated.port = Int(port) ?? 22
        updated.color = color
        updated.groupId = groupId

        switch authMode {
        case .password:
            updated.keyId = nil
        case .key:
            updated.keyId = keyId
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
}
