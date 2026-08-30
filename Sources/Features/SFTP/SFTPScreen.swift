// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Perception

/// Browses a host's files. Ported from the Android `SftpScreen`.
///
/// Taps follow Android's rule: a folder opens, a file downloads, a long press
/// opens the menu. There is no double-tap handler here and there is none there
/// either — on Android, tapping a row twice in quick succession used to send the
/// navigation twice and confuse the backend, so "nothing happens" is the fixed
/// behaviour, not a missing one. The model drops taps arriving while a move is
/// in flight, for a related but distinct reason of its own.
///
/// Selection mode is iOS's rather than Android's: `EditMode` and a `List`
/// selection instead of a hand-rolled set of checkboxes, with the same two
/// actions on the result — download and delete.
struct SFTPScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    let host: Host

    @State private var model: SFTPModel?

    /// The shared queue. A download outlives the screen that started it — it
    /// used to be cancelled by tapping the back chevron.
    private var transfers: TransferManager { environment.transfers }
    @State private var passwordInput = ""
    @FocusState private var isPasswordFocused: Bool
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var renaming: SFTPEntry?
    @State private var renameInput = ""
    @State private var deleting: SFTPEntry?
    @State private var isPickingUpload = false
    @State private var uploadConflict: UploadConflict?

    /// Names of the entries ticked in selection mode. `SFTPEntry.id` is the
    /// name, which is unique within one directory and is all a selection has to
    /// survive — it is cleared whenever the listing changes underneath it.
    @State private var selection = Set<SFTPEntry.ID>()
    @State private var editMode: EditMode = .inactive
    @State private var bulkDeleting: [SFTPEntry] = []

    /// A picked file whose name already exists on the server.
    private struct UploadConflict: Identifiable {
        let localURL: URL
        let suggestedName: String
        var id: URL { localURL }
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(host.label)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard model == nil else { return }
                // Re-attaches to a browser already open for this host rather than
                // making a second connection to the same server.
                let model = environment.browsers.browser(
                    for: host,
                    hosts: environment.hosts,
                    keys: environment.keys
                )
                self.model = model
                // Only if it has nothing going on: coming back to a live browser
                // should show what is already there, not reconnect underneath it.
                if case .connecting = model.phase, model.entries.isEmpty {
                    await model.connect()
                }
            }
            // Deliberately no `onDisappear` disconnect. Walking back out of the
            // browser leaves the session alone, as it does for a terminal tab; the
            // close button in the toolbar is what ends it.
        }
    }

    /// Split into small pieces on purpose. Chaining the whole toolbar and all
    /// six alerts onto one expression made the type-checker give up — SwiftUI
    /// modifier chains grow the inference problem faster than they look.
    @ViewBuilder
    private func content(_ model: SFTPModel) -> some View {
        phaseView(model)
            .safeAreaInset(edge: .bottom, spacing: 0) { TransfersBar(manager: transfers) }
            .toolbar { toolbar(model) }
            .alert(
                String(localized: .sftpDeleteSelectedCd),
                isPresented: .init(
                    get: { !bulkDeleting.isEmpty },
                    set: { if !$0 { bulkDeleting = [] } }
                )
            ) {
                Button(String(localized: .actionCancel), role: .cancel) { bulkDeleting = [] }
                Button(String(localized: .actionDelete), role: .destructive) {
                    let doomed = bulkDeleting
                    bulkDeleting = []
                    leaveSelection()
                    Task { await model.delete(doomed) }
                }
            } message: {
                // Named rather than counted when there are few: "Delete 2 items?"
                // tells you less than the two names do, and the mistake this
                // guards against is having ticked the wrong row.
                Text(bulkDeleting.count <= 3
                     ? bulkDeleting.map(\.name).joined(separator: ", ")
                     : String(localized: .sftpNSelected)
                        .replacingOccurrences(of: "%1$d", with: "\(bulkDeleting.count)"))
            }
            .fileImporter(
                isPresented: $isPickingUpload,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handlePickedFiles(result, model: model)
            }
            .alert(
                String(localized: .sftpConflictTitle),
                isPresented: .init(get: { uploadConflict != nil }, set: { if !$0 { uploadConflict = nil } }),
                presenting: uploadConflict
            ) { conflict in
                Button(String(localized: .actionCancel), role: .cancel) { uploadConflict = nil }
                Button(String(localized: .actionKeepBoth)) {
                    let pending = conflict
                    uploadConflict = nil
                    startUpload(pending.localURL, named: pending.suggestedName, model: model)
                }
                Button(String(localized: .actionOverwrite), role: .destructive) {
                    let pending = conflict
                    uploadConflict = nil
                    startUpload(pending.localURL, named: pending.localURL.lastPathComponent, model: model)
                }
            } message: { conflict in
                Text(
                    String(localized: .iosSftpConflictDetail)
                        .replacingOccurrences(of: "%1$@", with: conflict.localURL.lastPathComponent)
                        .replacingOccurrences(of: "%2$@", with: conflict.suggestedName)
                )
            }
            .modifier(FileAlerts(
                model: model,
                isCreatingFolder: $isCreatingFolder,
                newFolderName: $newFolderName,
                renaming: $renaming,
                renameInput: $renameInput,
                deleting: $deleting
            ))
    }

    @ViewBuilder
    private func phaseView(_ model: SFTPModel) -> some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .connecting:
                Spacer()
                ProgressView("Connecting to \(host.hostname)…")
                Spacer()

            case .failed(let message):
                Spacer()
                EmptyStateView {
                    Label(String(localized: .errorConnectionFailed), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(String(localized: .iosActionRetry)) { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()

            case .browsing:
                breadcrumb(model)
                Divider()
                listing(model)

            // The same two panels the terminal shows, from the same builder, so
            // one question does not look like two different things depending on
            // which screen asked it. They used to be system alerts here.
            case .needsPassword:
                ConnectionPrompt.password(
                    for: host.username,
                    at: host.hostname,
                    text: $passwordInput,
                    isFocused: $isPasswordFocused,
                    onConnect: {
                        let password = passwordInput
                        passwordInput = ""
                        isPasswordFocused = false
                        Task { await model.connect(password: password) }
                    },
                    onCancel: {
                        environment.browsers.close(host)
                        dismiss()
                    }
                )

            case .needsHostKeyApproval(let info, let isChange):
                ConnectionPrompt.hostKey(
                    info,
                    hostname: host.hostname,
                    isChange: isChange,
                    onTrust: { Task { await model.connect(acceptHostKey: true) } },
                    onReject: {
                        environment.browsers.close(host)
                        dismiss()
                    }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: SFTPModel) -> some ToolbarContent {
        if model.phase == .browsing {
            if editMode.isEditing {
                // In selection mode the bar belongs to the selection: acting on
                // several entries at once is the whole point of being in it, and
                // Android puts download and delete in the same place.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: .actionDone)) { leaveSelection() }
                }
                ToolbarItem(placement: .principal) {
                    Text(
                        String(localized: .sftpNSelected)
                            .replacingOccurrences(of: "%1$d", with: "\(selection.count)")
                    )
                    .font(.headline)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: .sftpDownloadSelectedCd), systemImage: "arrow.down.circle") {
                        guard let session = model.activeSession else { return }
                        transfers.download(selectedEntries(model), from: model.path, using: session)
                        leaveSelection()
                    }
                    .disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: .sftpDeleteSelectedCd), systemImage: "trash", role: .destructive) {
                        bulkDeleting = selectedEntries(model)
                    }
                    .disabled(selection.isEmpty)
                }
            } else {
                // The one control that ends the session, as on Android and as
                // the terminal's own close button does. The back chevron only
                // leaves the screen.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: .sftpDisconnectCd), systemImage: "xmark.circle") {
                        environment.browsers.close(host)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(String(localized: .sftpSelectItemsCd), systemImage: "checkmark.circle") {
                            selection = []
                            editMode = .active
                        }
                        Button(String(localized: .sftpMkdirTitle), systemImage: "folder.badge.plus") {
                            newFolderName = ""
                            isCreatingFolder = true
                        }
                        Button(String(localized: .iosSftpUpload), systemImage: "arrow.up.doc") {
                            isPickingUpload = true
                        }
                        Button(String(localized: .sftpRefreshCd), systemImage: "arrow.clockwise") {
                            Task { await model.refresh() }
                        }
                        Divider()
                        // Android gives this an eye of its own in the bar, with
                        // a red iris when dotfiles are showing. Here it joins
                        // the actions that are already in this menu — select,
                        // new folder, upload, refresh are all separate icons
                        // there too — and a menu item can say which way it is
                        // set, which a single eye glyph has to encode in colour.
                        Toggle(isOn: .init(
                            get: { model.showsHiddenFiles },
                            set: { _ in Task { await model.toggleHiddenFiles() } }
                        )) {
                            Label {
                                Text(hiddenFilesLabel(model))
                            } icon: {
                                Self.hiddenFilesEye(active: model.showsHiddenFiles)
                            }
                        }
                    } label: {
                        Label(String(localized: .iosSftpActions), systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    /// Named for what tapping it will do, which is how Android words its two
    /// content descriptions for the same button.
    private func hiddenFilesLabel(_ model: SFTPModel) -> String {
        model.showsHiddenFiles
            ? String(localized: .sftpHideHiddenCd)
            : String(localized: .sftpShowHiddenCd)
    }

    /// The eye, red while dotfiles are showing — Android draws a red iris over
    /// the same glyph for the same reason.
    ///
    /// Tinted through `UIImage` rather than `.foregroundStyle`: a menu is a
    /// `UIMenu` underneath, and it recolours the symbols its items carry to its
    /// own tint. An image marked `.alwaysOriginal` is the one thing it leaves
    /// alone. The menu item also carries a checkmark of its own, so the state is
    /// still legible if a future iOS decides otherwise about the colour.
    private static func hiddenFilesEye(active: Bool) -> Image {
        guard let symbol = UIImage(systemName: "eye") else {
            return Image(systemName: "eye")
        }
        guard active else { return Image(uiImage: symbol) }
        return Image(uiImage: symbol.withTintColor(.systemRed, renderingMode: .alwaysOriginal))
    }

    // MARK: - Selecting

    /// The chosen entries, in the order they appear rather than the set's.
    private func selectedEntries(_ model: SFTPModel) -> [SFTPEntry] {
        visibleEntries(model).filter { selection.contains($0.id) }
    }

    private func leaveSelection() {
        selection = []
        editMode = .inactive
    }

    /// Starts a download and reports the one thing that can go wrong before the
    /// transfer bar takes over: having no connection to ask.
    private func download(_ entry: SFTPEntry, model: SFTPModel) {
        guard let session = model.activeSession else { return }
        transfers.download(entry, from: model.path, using: session)
    }

    // MARK: - Uploading

    private func handlePickedFiles(_ result: Result<[URL], Error>, model: SFTPModel) {
        guard case .success(let urls) = result else { return }

        for url in urls {
            let name = url.lastPathComponent

            if model.existingNames.contains(name) {
                // Ask once per clashing file rather than guessing. Only the
                // first is queued here; the rest follow as the user answers.
                uploadConflict = UploadConflict(
                    localURL: url,
                    suggestedName: TransferManager.uniqueRemoteName(
                        for: name,
                        existing: model.existingNames
                    )
                )
                break
            }
            startUpload(url, named: name, model: model)
        }
    }

    private func startUpload(_ url: URL, named name: String, model: SFTPModel) {
        guard let session = model.activeSession else { return }

        // A file picked outside the sandbox needs its access opened, and it must
        // stay open for the whole upload, not just this function.
        let needsScope = url.startAccessingSecurityScopedResource()

        let id = transfers.upload(from: url, to: model.path, named: name, using: session)

        Task {
            // Held until this specific transfer stops. Waiting on the id rather
            // than the name matters: two uploads can share a name.
            while transfers.isRunning(id) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if needsScope { url.stopAccessingSecurityScopedResource() }
            await model.refresh()
        }
    }

    // MARK: - Pieces

    private func breadcrumb(_ model: SFTPModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) {
                            Task { await model.navigate(to: crumb.path) }
                        }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.breadcrumb.count - 1 ? .primary : Color.accentColor)
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onValueChange(of: model.path) { _ in
                // Keep the current directory in view when descending into a
                // deep tree, instead of leaving it off the right edge.
                withAnimation { proxy.scrollTo(model.breadcrumb.count - 1, anchor: .trailing) }
            }
        }
    }

    private func visibleEntries(_ model: SFTPModel) -> [SFTPEntry] {
        SFTPModel.visibleEntries(
            model.entries,
            showingHidden: model.showsHiddenFiles,
            directoriesFirst: environment.preferences.sftpSortDirsFirst
        )
    }

    @ViewBuilder
    private func listing(_ model: SFTPModel) -> some View {
        let entries = visibleEntries(model)

        if entries.isEmpty && !model.isLoading {
            EmptyStateView(String(localized: .sftpEmptyDirectory), systemImage: "folder")
        } else {
            List(selection: $selection) {
                // Not selectable, and it stays a plain button in edit mode:
                // ".." is a move, not a thing to act on in bulk.
                if model.path != "/" && !editMode.isEditing {
                    Button {
                        Task { await model.navigateUp() }
                    } label: {
                        Label { Text(verbatim: "..") } icon: { Image(systemName: "arrow.turn.left.up") }
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(entries) { entry in
                    Button {
                        // A folder opens, a file downloads — the Android rule.
                        // The row used to be `.disabled` for files, so tapping
                        // one did nothing at all and the only way down was the
                        // long-press menu.
                        if entry.isDirectory {
                            Task { await model.navigate(into: entry) }
                        } else {
                            download(entry, model: model)
                        }
                    } label: {
                        EntryRow(entry: entry) {
                            // Folders need a control of their own precisely
                            // because their tap is taken: it opens them. Files
                            // get the same glyph without a button behind it —
                            // an affordance saying "this comes down if you tap
                            // it", which is what Android draws too.
                            download(entry, model: model)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(entry.id)
                    .contextMenu {
                        Button(String(localized: .sftpDownloadCd), systemImage: "arrow.down.circle") {
                            download(entry, model: model)
                        }
                        Button(String(localized: .sftpMenuRename), systemImage: "pencil") {
                            renameInput = entry.name
                            renaming = entry
                        }
                        Button(String(localized: .sftpMenuDelete), systemImage: "trash", role: .destructive) {
                            deleting = entry
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            // A selection is a set of names, and the names mean something
            // different once the listing changes. Cleared on every move so a
            // stale tick cannot download the wrong file.
            .onValueChange(of: model.path) { _ in leaveSelection() }
            .onValueChange(of: model.entries.map(\.id)) { _ in
                selection = selection.intersection(model.entries.map(\.id))
            }
            .refreshable { await model.refresh() }
            .overlay {
                if model.isLoading && model.entries.isEmpty {
                    ProgressView()
                }
            }
        }
    }

}

private struct EntryRow: View {
    let entry: SFTPEntry

    /// Called by the folder's own download button. Files draw the same glyph
    /// without a button behind it: their row tap already downloads, so a second
    /// tappable thing in the same row would be two ways to do one job.
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if !entry.isDirectory {
                        Text(entry.size.formatted(.byteCount(style: .file)))
                    }
                    if let modified = entry.modified {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // A folder's tap is spoken for — it opens it — so downloading one
            // needs a control of its own. A file's does not, and gets the glyph
            // alone as a hint that a tap brings it down. Android draws exactly
            // this asymmetry: `IconButton` for a directory, bare `Icon` for a
            // file.
            if entry.isDirectory && !entry.isSymlink {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: .sftpDownloadFolderCd))
            } else if !entry.isDirectory {
                Image(systemName: "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if entry.isSymlink { return entry.isDirectory ? "folder.badge.questionmark" : "link" }
        return entry.isDirectory ? "folder.fill" : "doc"
    }
}
