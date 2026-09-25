// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shows an ``ErrorReport`` and stays until it is closed.
///
/// A sheet rather than an alert, because an alert cannot hold a list that
/// scrolls, cannot be selected from, and on iOS truncates a long message
/// without saying that it has. Android's version is a dialog with the same
/// three parts: a row per file, a detail behind each one, and Copy.
struct ErrorReportSheet: View {

    let report: ErrorReport
    let onClose: () -> Void

    @State private var expanded: Set<UUID> = []
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(report.failures) { failure in
                        row(failure)
                    }
                } header: {
                    Text(report.title)
                }

                if !report.notAttempted.isEmpty {
                    Section {
                        Text(
                            String(localized: .sftpReportNotAttempted)
                                .replacingOccurrences(
                                    of: "%1$@",
                                    with: report.notAttempted.joined(separator: ", ")
                                )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text(.errorUnknown))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        UIPasteboard.general.string = report.asText
                        withAnimation { didCopy = true }
                    } label: {
                        Label(
                            String(localized: .actionCopy),
                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(didCopy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: .actionDone)) { onClose() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ failure: FileFailure) -> some View {
        let isOpen = expanded.contains(failure.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                // Only when there is something more to see: most failures say
                // everything they have to say in one line.
                if hasDetail(failure) {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasDetail(failure) else { return }
                withAnimation {
                    if isOpen { expanded.remove(failure.id) } else { expanded.insert(failure.id) }
                }
            }

            if isOpen {
                Text(failure.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func hasDetail(_ failure: FileFailure) -> Bool {
        !failure.detail.isEmpty && failure.detail != failure.message
    }
}
