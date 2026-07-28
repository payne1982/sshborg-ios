// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UniformTypeIdentifiers

/// Manages the stored key pairs. Ported from the Android `KeysScreen`.
struct KeysScreen: View {

    @Environment(\.appEnvironment) private var environment
    @State private var model: KeysModel?
    @State private var isGenerating = false
    @State private var isImporting = false
    @State private var inspecting: SSHKey?
    @State private var pendingDeletion: PendingDeletion?

    /// A delete waiting on confirmation, carrying how many hosts it affects.
    private struct PendingDeletion: Identifiable {
        let key: SSHKey
        let hostCount: Int
        var id: Int64 { key.id ?? -1 }
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("SSH keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Generate…", systemImage: "wand.and.stars") { isGenerating = true }
                    Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .task {
            let model = model ?? KeysModel(
                repository: environment.keys,
                preferences: environment.preferences
            )
            self.model = model
            await model.observe()
        }
        .sheet(isPresented: $isGenerating) {
            if let model {
                NavigationStack { KeyGeneratorSheet(model: model) }
            }
        }
        .sheet(isPresented: $isImporting) {
            if let model {
                NavigationStack { KeyImportSheet(model: model) }
            }
        }
        .sheet(item: $inspecting) { key in
            NavigationStack { KeyDetailSheet(key: key) }
        }
        .alert(
            "Delete key?",
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { pending in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                let key = pending.key
                pendingDeletion = nil
                Task { await model?.delete(key) }
            }
        } message: { pending in
            if pending.hostCount > 0 {
                Text("\(pending.key.label) is used by \(pending.hostCount) host(s). They will be kept but fall back to password authentication. The private key cannot be recovered.")
            } else {
                Text("The private key cannot be recovered once deleted.")
            }
        }
    }

    @ViewBuilder
    private func content(_ model: KeysModel) -> some View {
        if model.keys.isEmpty {
            ContentUnavailableView {
                Label("No keys", systemImage: "key")
            } description: {
                Text("Generate a key, or import one you already use.")
            } actions: {
                Button("Generate a key") { isGenerating = true }
                    .buttonStyle(.borderedProminent)
                Button("Import") { isImporting = true }
            }
        } else {
            List {
                ForEach(model.keys) { key in
                    Button { inspecting = key } label: { KeyRow(key: key) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy public key", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = key.publicKey
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task {
                                    pendingDeletion = PendingDeletion(
                                        key: key,
                                        hostCount: await model.hostCount(using: key)
                                    )
                                }
                            }
                        }
                }
            }
        }
    }
}

private struct KeyRow: View {
    let key: SSHKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: key.isEncrypted ? "key.fill" : "key")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                Text(key.parsedKeyType?.displayName ?? key.keyType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fingerprint = key.fingerprint {
                    Text(fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Generate

private struct KeyGeneratorSheet: View {

    @Environment(\.dismiss) private var dismiss
    let model: KeysModel

    @State private var label = ""
    @State private var type: SSHKey.KeyType = .ed25519
    @State private var bits = 0
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $label)
            } footer: {
                Text("Also stored as the key's comment, which is what a server shows in its logs.")
            }

            Section {
                Picker("Type", selection: $type) {
                    ForEach(SSHKey.KeyType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                let sizes = SSHKeyGenerator.supportedSizes(for: type)
                if !sizes.isEmpty {
                    Picker(type == .ecdsa ? "Curve" : "Size", selection: $bits) {
                        ForEach(sizes, id: \.self) { size in
                            Text(type == .ecdsa ? "nistp\(size)" : "\(size) bits").tag(size)
                        }
                    }
                }
            } header: {
                Text("Type")
            } footer: {
                if type == .ed25519 {
                    Text("Ed25519 is the recommended choice: short, fast, and secure. It has one size.")
                }
            }
        }
        .navigationTitle("Generate key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Generate") { generate() }
                    .disabled(label.trimmed.isEmpty || isWorking)
            }
        }
        .onChange(of: type, initial: true) {
            bits = SSHKeyGenerator.defaultSize(for: type) ?? 0
        }
        .alert("Could not generate", isPresented: .init(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func generate() {
        isWorking = true
        Task {
            do {
                // RSA at 4096 bits takes a noticeable moment; off the main actor
                // so the sheet does not freeze mid-tap.
                try await model.generate(
                    type: type,
                    bits: bits == 0 ? nil : bits,
                    label: label
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Import

private struct KeyImportSheet: View {

    @Environment(\.dismiss) private var dismiss
    let model: KeysModel

    @State private var label = ""
    @State private var text = ""
    @State private var isChoosingFile = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $label)
            } footer: {
                Text("Left blank, the key's own comment is used.")
            }

            Section {
                Button("Choose a file…", systemImage: "folder") { isChoosingFile = true }
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .frame(minHeight: 160)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Private key")
            } footer: {
                Text("Paste the private key file — the one without the .pub extension. Keys protected by a passphrase are not supported yet.")
            }
        }
        .navigationTitle("Import key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { performImport() }
                    .disabled(text.trimmed.isEmpty)
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.data, .text]) { result in
            guard case .success(let url) = result else { return }

            // A file outside the sandbox needs its access explicitly opened.
            guard url.startAccessingSecurityScopedResource() else {
                error = "That file could not be opened."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                self.error = "That file could not be read as text."
            }
        }
        .alert("Could not import", isPresented: .init(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func performImport() {
        Task {
            do {
                try await model.importKey(text: text, label: label)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Detail

private struct KeyDetailSheet: View {

    @Environment(\.dismiss) private var dismiss
    let key: SSHKey
    @State private var didCopy = false

    var body: some View {
        Form {
            Section("Public key") {
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = key.publicKey
                    withAnimation { didCopy = true }
                }
                .disabled(didCopy)
            }

            Section("Details") {
                LabeledContent("Type", value: key.parsedKeyType?.displayName ?? key.keyType)
                if let fingerprint = key.fingerprint {
                    LabeledContent("Fingerprint") {
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Created", value: key.createdAtDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Stored", value: key.isEncrypted ? "Encrypted" : "Plain text")
            }

            Section {
                Text("Add the public key above to ~/.ssh/authorized_keys on the server to log in with this key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(key.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
