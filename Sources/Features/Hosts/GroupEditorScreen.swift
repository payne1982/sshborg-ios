// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Creates or renames a group and picks its colour. Ported from the Android
/// `GroupDialog`.
///
/// A group always has a colour — it is what identifies its hosts at a glance in
/// the list — so unlike the host editor there is no "none" option.
struct GroupEditorScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    /// `nil` creates a new group.
    let group: HostGroup?

    /// Called with the saved group, so a caller that opened this to create a
    /// group for a host can select it straight away.
    var onSaved: ((HostGroup) -> Void)?

    @State private var name = ""
    @State private var color = HostGroup.swatches[0]
    @State private var saveError: String?
    @State private var isLoaded = false

    private var isValid: Bool { !name.trimmed.isEmpty }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: .groupDialogName), text: $name)
            }

            Section("Colour") {
                ColorSwatchPicker(
                    selection: Binding(
                        get: { color },
                        set: { color = $0 ?? HostGroup.swatches[0] }
                    ),
                    allowsNone: false
                )
            }
        }
        .navigationTitle(group == nil ? "New group" : "Edit group")
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
            if let group {
                name = group.name
                color = group.color
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

    private func save() {
        var updated = group ?? HostGroup(name: "", color: color)
        updated.name = name.trimmed
        updated.color = color

        let record = updated
        Task {
            do {
                let saved = try await environment.groups.save(record)
                onSaved?(saved)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}
