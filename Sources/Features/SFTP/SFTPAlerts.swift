// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The prompts the connection itself can raise: a missing password, and a host
/// key that is unknown or has changed.
///
/// Kept apart from the browser's own alerts so neither chain grows long enough
/// to defeat the type-checker.
struct ConnectionAlerts: ViewModifier {

    @Bindable var model: SFTPModel
    @Binding var passwordInput: String
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Password", isPresented: needsPassword) {
                SecureField("Password", text: $passwordInput)
                    .plainTextEntry()
                Button(String(localized: .actionCancel), role: .cancel, action: onCancel)
                Button("Connect") {
                    let password = passwordInput
                    passwordInput = ""
                    Task { await model.connect(password: password) }
                }
            } message: {
                Text("Enter the password for \(model.host.username)@\(model.host.hostname).")
            }
            .alert(
                isChange ? "Host key changed" : "Unknown host key",
                isPresented: needsHostKey,
                presenting: hostKeyInfo
            ) { _ in
                Button(String(localized: .actionCancel), role: .cancel, action: onCancel)
                Button("Accept", role: isChange ? .destructive : nil) {
                    Task { await model.connect(acceptHostKey: true) }
                }
            } message: { info in
                Text(hostKeyMessage(info))
            }
    }

    // SwiftUI wants Bool bindings while the truth lives in the model's phase.
    // The setter is deliberately inert: dismissal always goes through a button,
    // so a stray write cannot leave the connection in limbo.
    private var needsPassword: Binding<Bool> {
        Binding(get: { model.phase == .needsPassword }, set: { _ in })
    }

    private var needsHostKey: Binding<Bool> {
        Binding(get: { hostKeyInfo != nil }, set: { _ in })
    }

    private var hostKeyInfo: HostKeyInfo? {
        guard case .needsHostKeyApproval(let info, _) = model.phase else { return nil }
        return info
    }

    private var isChange: Bool {
        guard case .needsHostKeyApproval(_, let changed) = model.phase else { return false }
        return changed
    }

    private func hostKeyMessage(_ info: HostKeyInfo) -> String {
        let fingerprint = "\(info.algorithm)\n\(info.fingerprint)"

        if isChange {
            return """
            The key presented by \(model.host.hostname) does not match the one stored for it.

            \(fingerprint)

            This happens when a server is rebuilt, but it is also what an intercepted connection looks like. Only accept if you know the server changed.
            """
        }
        return """
        \(model.host.hostname) has not been seen before. Check that this fingerprint matches the server.

        \(fingerprint)
        """
    }
}

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
