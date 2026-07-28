// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Browses a host's files. Ported from the Android `SftpScreen`.
///
/// Transfers are not here yet: downloading to the Files app and uploading from
/// it arrive with phase 6c, together with the conflict handling that needs.
struct SFTPScreen: View {

    @Environment(\.appEnvironment) private var environment
    @Environment(\.dismiss) private var dismiss

    let host: Host

    @State private var model: SFTPModel?
    @State private var passwordInput = ""
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var renaming: SFTPEntry?
    @State private var renameInput = ""
    @State private var deleting: SFTPEntry?
    @State private var transfers = TransferManager()
    @State private var isPickingUpload = false
    @State private var uploadConflict: UploadConflict?

    /// A picked file whose name already exists on the server.
    private struct UploadConflict: Identifiable {
        let localURL: URL
        let suggestedName: String
        var id: URL { localURL }
    }

    var body: some View {
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
            let model = SFTPModel(host: host, hosts: environment.hosts, keys: environment.keys)
            self.model = model
            await model.connect()
        }
        .onDisappear { model?.disconnect() }
    }

    /// Split into small pieces on purpose. Chaining the whole toolbar and all
    /// six alerts onto one expression made the type-checker give up — SwiftUI
    /// modifier chains grow the inference problem faster than they look.
    @ViewBuilder
    private func content(_ model: SFTPModel) -> some View {
        phaseView(model)
            .safeAreaInset(edge: .bottom, spacing: 0) { TransfersBar(manager: transfers) }
            .toolbar { toolbar(model) }
            .fileImporter(
                isPresented: $isPickingUpload,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handlePickedFiles(result, model: model)
            }
            .alert(
                "File exists",
                isPresented: .init(get: { uploadConflict != nil }, set: { if !$0 { uploadConflict = nil } }),
                presenting: uploadConflict
            ) { conflict in
                Button("Cancel", role: .cancel) { uploadConflict = nil }
                Button("Keep both") {
                    let pending = conflict
                    uploadConflict = nil
                    startUpload(pending.localURL, named: pending.suggestedName, model: model)
                }
                Button("Replace", role: .destructive) {
                    let pending = conflict
                    uploadConflict = nil
                    startUpload(pending.localURL, named: pending.localURL.lastPathComponent, model: model)
                }
            } message: { conflict in
                Text("\(conflict.localURL.lastPathComponent) already exists here. Keeping both saves it as \(conflict.suggestedName).")
            }
            .modifier(ConnectionAlerts(model: model, passwordInput: $passwordInput, onCancel: { dismiss() }))
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
                ContentUnavailableView {
                    Label("Could not connect", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()

            case .browsing:
                breadcrumb(model)
                Divider()
                listing(model)

            case .needsPassword, .needsHostKeyApproval:
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: SFTPModel) -> some ToolbarContent {
        if model.phase == .browsing {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        isCreatingFolder = true
                    }
                    Button("Upload…", systemImage: "arrow.up.doc") {
                        isPickingUpload = true
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
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
            .onChange(of: model.path) {
                // Keep the current directory in view when descending into a
                // deep tree, instead of leaving it off the right edge.
                withAnimation { proxy.scrollTo(model.breadcrumb.count - 1, anchor: .trailing) }
            }
        }
    }

    @ViewBuilder
    private func listing(_ model: SFTPModel) -> some View {
        if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            List {
                if model.path != "/" {
                    Button {
                        Task { await model.navigateUp() }
                    } label: {
                        Label("..", systemImage: "arrow.turn.left.up")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(model.entries) { entry in
                    Button {
                        Task { await model.navigate(into: entry) }
                    } label: {
                        EntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .disabled(!entry.isDirectory)
                    .contextMenu {
                        if !entry.isDirectory {
                            Button("Download", systemImage: "arrow.down.circle") {
                                guard let session = model.activeSession else { return }
                                transfers.download(entry, from: model.path, using: session)
                            }
                        }
                        Button("Rename", systemImage: "pencil") {
                            renameInput = entry.name
                            renaming = entry
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleting = entry
                        }
                    }
                }
            }
            .listStyle(.plain)
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
