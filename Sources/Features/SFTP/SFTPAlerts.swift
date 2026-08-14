// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The connection's own prompts — a missing password and an unknown host key —
// used to live here as system alerts. They are now `ConnectionPrompt` panels
// drawn in the layout, the same ones the terminal shows, so one question does
// not look like two different things depending on which screen asked it.

/// The prompts the browser raises: creating a folder, renaming, deleting, and
/// reporting an action that failed without losing the connection.
struct FileAlerts: ViewModifier {

    @Bindable var model: SFTPModel
    @Binding var isCreatingFolder: Bool
    @Binding var newFolderName: String
    @Binding var renaming: SFTPEntry?
    @Binding var renameInput: String
    @Binding var deleting: SFTPEntry?

    func body(content: Content) -> some View {
        content
            .alert("New folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                    .plainTextEntry()
                Button(String(localized: .actionCancel), role: .cancel) {}
                Button("Create") {
                    let name = newFolderName.trimmed
                    guard !name.isEmpty else { return }
                    Task { await model.createDirectory(named: name) }
                }
            }
            .alert("Rename", isPresented: isRenaming) {
                TextField("Name", text: $renameInput)
                    .plainTextEntry()
                Button(String(localized: .actionCancel), role: .cancel) { renaming = nil }
                Button(String(localized: .sftpMenuRename)) {
                    guard let entry = renaming else { return }
                    let name = renameInput.trimmed
                    renaming = nil
                    // Renaming to the same name is a no-op, not an error.
                    guard !name.isEmpty, name != entry.name else { return }
                    Task { await model.rename(entry, to: name) }
                }
            }
            .alert("Delete?", isPresented: isDeleting, presenting: deleting) { entry in
                Button(String(localized: .actionCancel), role: .cancel) { deleting = nil }
                Button(String(localized: .actionDelete), role: .destructive) {
                    let target = entry
                    deleting = nil
                    Task { await model.delete(target) }
                }
            } message: { entry in
                Text(entry.isDirectory
                     ? "\(entry.name) must be empty to be removed."
                     : "\(entry.name) will be deleted on the server. This cannot be undone.")
            }
            .alert(String(localized: .errorUnknown), isPresented: hasActionError) {
                Button(String(localized: .actionDone), role: .cancel) { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var hasActionError: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}
