// SPDX-License-Identifier: GPL-3.0-or-later

import QuickLook
import SwiftUI
import Perception

/// The strip of transfers under the file list. Hidden entirely when there is
/// nothing to show, so browsing is not permanently shortened by an empty bar.
struct TransfersBar: View {

    @Perception.Bindable var manager: TransferManager

    var body: some View {
        WithPerceptionTracking {
            if !manager.transfers.isEmpty {
                VStack(spacing: 0) {
                    Divider()

                    HStack {
                        Text(.iosTransfersTitle)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if manager.transfers.contains(where: { !$0.isActive }) {
                            Button(String(localized: .iosTransfersClear)) { manager.dismissFinished() }
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(manager.transfers) { transfer in
                                TransferRow(transfer: transfer, manager: manager)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 160)
                }
                .background(.bar)
            }
        }
    }
}

private struct TransferRow: View {

    let transfer: TransferManager.Transfer
    let manager: TransferManager

    @State private var previewURL: URL?
    @State private var showingReport = false

    /// The file to open, or `nil` when there is nothing openable: an upload
    /// points at a file the user already has, and a download that failed or was
    /// cancelled has nothing on disk worth showing.
    private var openableURL: URL? {
        guard transfer.kind == .download, transfer.status == .finished,
              let url = transfer.localURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                Image(systemName: transfer.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 3) {
                    // A finished download's name opens it. Sharing was already
                    // here, but sharing is what you do to send a file somewhere
                    // else; the common case is wanting to *look* at what you just
                    // fetched, and until now that took a trip through the Files app.
                    // Quick Look is the iOS equivalent of Android's "open with".
                    if let url = openableURL {
                        Button {
                            previewURL = url
                        } label: {
                            Text(transfer.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHint(Text(.sftpDownloadComplete))
                    } else {
                        Text(transfer.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if transfer.isActive {
                        // A determinate bar when the size is known, an indeterminate
                        // one when it is not — never a bar frozen at zero.
                        if let fraction = transfer.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // A row that ended with anything unfinished in it says so
                    // and opens the report. Before this a folder download that
                    // skipped three files was indistinguishable from one that
                    // did not, and the errors were gone by then anyway.
                    if transfer.report != nil {
                        Button {
                            showingReport = true
                        } label: {
                            Label(
                                String(localized: .sftpReportShowErrors),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(transfer.isPartial ? .orange : .red)
                    }
                }

                Spacer()

                trailingControl
            }
            .quickLookPreview($previewURL)
            .sheet(isPresented: $showingReport) {
                if let report = transfer.report {
                    ErrorReportSheet(report: report) { showingReport = false }
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch transfer.status {
        case .running:
            Button(String(localized: .iosActionStop), systemImage: "stop.circle") { manager.cancel(transfer.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

        case .finished:
            HStack(spacing: 8) {
                if let url = transfer.localURL, transfer.kind == .download {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(String(localized: .sftpBackgroundDismissCd), systemImage: "xmark") { manager.dismiss(transfer.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

        case .failed, .cancelled:
            Button(String(localized: .sftpBackgroundDismissCd), systemImage: "xmark") { manager.dismiss(transfer.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        // Partly done is its own state, and orange is what says so: green over a
        // download that left three files behind would be a lie told in colour.
        if transfer.isPartial { return .orange }

        switch transfer.status {
        case .running: return .accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var subtitle: String {
        switch transfer.status {
        case .running:
            let done = transfer.transferred.formatted(.byteCount(style: .file))
            guard let total = transfer.totalBytes else { return done }
            return "\(done) of \(total.formatted(.byteCount(style: .file)))"
        case .finished:
            if transfer.isPartial {
                let done = transfer.doneCount
                let total = transfer.totalCount
                let template = String(
                    localized: transfer.kind == .download
                        ? .sftpReportDownloadedNOfM
                        : .sftpReportUploadedNOfM
                )
                return template
                    .replacingOccurrences(of: "%1$d", with: "\(done)")
                    .replacingOccurrences(of: "%2$d", with: "\(total)")
            }
            return transfer.kind == .download
                ? "Saved to the Files app, under SSHBorg"
                : "Uploaded"
        case .failed(let message):
            return message
        case .cancelled:
            return "Stopped"
        }
    }
}
