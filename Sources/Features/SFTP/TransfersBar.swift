// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The strip of transfers under the file list. Hidden entirely when there is
/// nothing to show, so browsing is not permanently shortened by an empty bar.
struct TransfersBar: View {

    @Bindable var manager: TransferManager

    var body: some View {
        if !manager.transfers.isEmpty {
            VStack(spacing: 0) {
                Divider()

                HStack {
                    Text("Transfers")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if manager.transfers.contains(where: { !$0.isActive }) {
                        Button("Clear finished") { manager.dismissFinished() }
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

private struct TransferRow: View {

    let transfer: TransferManager.Transfer
    let manager: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
            }

            Spacer()

            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch transfer.status {
        case .running:
            Button("Stop", systemImage: "stop.circle") { manager.cancel(transfer.id) }
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
                Button("Dismiss", systemImage: "xmark") { manager.dismiss(transfer.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

        case .failed, .cancelled:
            Button("Dismiss", systemImage: "xmark") { manager.dismiss(transfer.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch transfer.status {
        case .running: .accentColor
        case .finished: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private var subtitle: String {
        switch transfer.status {
        case .running:
            let done = transfer.transferred.formatted(.byteCount(style: .file))
            guard let total = transfer.totalBytes else { return done }
            return "\(done) of \(total.formatted(.byteCount(style: .file)))"
        case .finished:
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
