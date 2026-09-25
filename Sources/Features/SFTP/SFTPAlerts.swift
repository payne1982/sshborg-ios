// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

// The connection's own prompts — a missing password and an unknown host key —
// used to live here as system alerts. They are now `ConnectionPrompt` panels
// drawn in the layout, the same ones the terminal shows, so one question does
// not look like two different things depending on which screen asked it.

/// The prompts the browser raises: creating a folder, renaming, deleting, and
/// reporting what failed without losing the connection.
struct FileAlerts: ViewModifier {

    @Perception.Bindable var model: SFTPModel
    @Binding var isCreatingFolder: Bool
    @Binding var newFolderName: String
    @Binding var renaming: SFTPEntry?
    @Binding var renameInput: String
    @Binding var deleting: SFTPEntry?

    /// Android names what is being deleted in the title, and it is the one
    /// place the two kinds have to be told apart: the same question about a
    /// folder is a much bigger one.
    ///
    /// Built here rather than inline, because a ternary of two implicit member
    /// expressions inside `String(localized:)` leaves the overload to be guessed
    /// from the branches, and there is more than one to guess between.
    private var deleteTitle: String {
        deleting?.isDirectory == true
            ? String(localized: .sftpDeleteFolderTitle)
            : String(localized: .sftpDeleteFileTitle)
    }

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .alert(String(localized: .sftpMkdirTitle), isPresented: $isCreatingFolder) {
                    TextField(String(localized: .sftpMkdirFolderName), text: $newFolderName)
                        .plainTextEntry()
                    Button(String(localized: .actionCancel), role: .cancel) {}
                    Button(String(localized: .actionCreate)) {
                        let name = newFolderName.trimmed
                        guard !name.isEmpty else { return }
                        Task { await model.createDirectory(named: name) }
                    }
                }
                .alert(String(localized: .sftpRenameTitle), isPresented: isRenaming) {
                    TextField(String(localized: .sftpRenameNewName), text: $renameInput)
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
                .alert(deleteTitle, isPresented: isDeleting, presenting: deleting) { entry in
                    Button(String(localized: .actionCancel), role: .cancel) { deleting = nil }
                    Button(String(localized: .actionDelete), role: .destructive) {
                        let target = entry
                        deleting = nil
                        Task { await model.delete(target) }
                    }
                } message: { entry in
                    // It used to say a folder had to be empty to be removed. That
                    // stopped being true when the delete grew its recursive walk,
                    // and the warning stayed — telling the user to do by hand a job
                    // the app had started doing for them.
                    Text(
                        String(localized: .sftpDeleteMessage)
                            .replacingOccurrences(of: "%1$@", with: entry.name)
                    )
                }
                // A sheet that stays, not a message that goes: an operation
                // over several files has several things to say, and the one line
                // that used to appear here said the first of them and vanished.
                .sheet(item: $model.report) { report in
                    ErrorReportSheet(report: report) { model.report = nil }
                }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

}
