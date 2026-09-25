// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The editor for one remote file, over the file list.
///
/// The text lives here rather than in the model, as it does on Android and for
/// the same reason: a published property updated on every keystroke would redraw
/// the browser behind it. What the model owns is the file — its bytes, its
/// charset, and the two trips to the server.
struct EditorScreen: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var environment

    let path: String
    let session: SFTPSession

    /// Opened for its bytes, from the browser's "Open in hex".
    var asHex = false

    @State private var model: EditorModel?
    @State private var text = ""
    @State private var isDirty = false
    @State private var suggestions = false

    @State private var charsets: [TextFile.Charset] = []
    @State private var isPickingCharset = false
    @State private var confirmCharsetChange = false
    @State private var confirmDiscard = false

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationBarBackButtonHidden(true)
            .task {
                guard model == nil else { return }
                let model = EditorModel(path: path, session: session)
                self.model = model
                await model.load(asHex: asHex)
                if case .ready(let decoded) = model.phase {
                    text = decoded.text
                }
                charsets = await model.readableCharsets()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: EditorModel) -> some View {
        WithPerceptionTracking {
            switch model.phase {
            case .loading(let received, let size):
                loading(received: received, size: size)

            case .ready(let decoded):
                editor(model, decoded)

            case .hex(let bytes):
                HexEditorScreen(model: model, bytes: bytes)

            case .unsupported(let refusal, let size):
                refused(model, refusal, size: size)

            case .failed(let report):
                failure(report)
            }
        }
    }

    // MARK: - Reading

    /// A screen of its own while the file arrives, with a figure on it: a few
    /// megabytes over a slow link take long enough that a spinner alone reads as
    /// a hung screen, and Back gives up on the file rather than waiting it out.
    private func loading(received: UInt64, size: UInt64) -> some View {
        VStack(spacing: 12) {
            if size > 0 {
                ProgressView(value: min(1, Double(received) / Double(size)))
                    .frame(maxWidth: 280)
                Text("\(received.formatted(.byteCount(style: .file))) / \(size.formatted(.byteCount(style: .file)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(.editorLoading)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
    }

    // MARK: - Editing

    private func editor(_ model: EditorModel, _ decoded: TextFile.Decoded) -> some View {
        VStack(spacing: 0) {
            EditorTextView(
                text: $text,
                family: ConfigSyntax.family(of: name, text: decoded.text),
                fontSize: environment.preferences.terminalFontSize,
                suggestions: suggestions
            )
            .onValueChange(of: text) { _ in
                if text != decoded.text { isDirty = true }
            }

            Divider()
            statusLine(model, decoded)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            closeButton

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    suggestions.toggle()
                } label: {
                    Label(String(localized: .editorSuggestions), systemImage: "text.badge.checkmark")
                }
                .foregroundStyle(suggestions ? Color.accentColor : Color.secondary)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            await model.save(text)
                            if model.didSave { isDirty = false }
                        }
                    } label: {
                        Label(String(localized: .actionSave), systemImage: "checkmark")
                    }
                    .disabled(!isDirty)
                }
            }
        }
        .alert(String(localized: .editorUnsavedTitle), isPresented: $confirmDiscard) {
            Button(String(localized: .actionCancel), role: .cancel) {}
            Button(String(localized: .editorDiscard), role: .destructive) { dismiss() }
        } message: {
            Text(.editorUnsavedMessage)
        }
        .alert(String(localized: .editorCharset), isPresented: $confirmCharsetChange) {
            Button(String(localized: .actionCancel), role: .cancel) {}
            Button(String(localized: .editorDiscard), role: .destructive) { isPickingCharset = true }
        } message: {
            Text(.editorCharsetDiscard)
        }
        .sheet(isPresented: $isPickingCharset) {
            charsetPicker(model, current: decoded.charset)
        }
        .sheet(item: Binding(get: { model.problem }, set: { model.problem = $0 })) { report in
            ErrorReportSheet(report: report) { model.problem = nil }
        }
    }

    /// What the file is made of, so saving never holds a surprise: charset, line
    /// ending, state. Tapping the charset reads the same bytes another way.
    private func statusLine(_ model: EditorModel, _ decoded: TextFile.Decoded) -> some View {
        HStack(spacing: 12) {
            Button {
                if isDirty { confirmCharsetChange = true } else { isPickingCharset = true }
            } label: {
                HStack(spacing: 2) {
                    Text(decoded.label)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }

            Text(statusParts(decoded).joined(separator: "  ·  "))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func statusParts(_ decoded: TextFile.Decoded) -> [String] {
        var parts = [decoded.lineEnding == .crlf ? "CRLF" : "LF"]
        if decoded.mixedEndings { parts.append(String(localized: .editorMixedEndings)) }
        if isDirty {
            parts.append(String(localized: .editorUnsaved))
        } else if model?.didSave == true {
            parts.append(String(localized: .editorSaved))
        }
        return parts
    }

    private func charsetPicker(_ model: EditorModel, current: TextFile.Charset) -> some View {
        NavigationStack {
            List(charsets) { charset in
                Button {
                    isPickingCharset = false
                    model.reread(as: charset)
                    if case .ready(let decoded) = model.phase {
                        text = decoded.text
                        isDirty = false
                    }
                } label: {
                    HStack {
                        Text(charset.name)
                        Spacer()
                        if charset == current {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(Text(.editorCharset))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: .actionDone)) { isPickingCharset = false }
                }
            }
        }
    }

    // MARK: - The files it will not edit

    private func refused(_ model: EditorModel, _ refusal: EditorModel.Refusal, size: UInt64) -> some View {
        EmptyStateView {
            Label(String(localized: .editorFailed), systemImage: "doc.questionmark")
        } description: {
            switch refusal {
            case .tooLarge:
                Text(
                    String(localized: .editorTooLarge)
                        .replacingOccurrences(of: "%1$@", with: size.formatted(.byteCount(style: .file)))
                        .replacingOccurrences(
                            of: "%2$@",
                            with: EditorModel.maximumBytes.formatted(.byteCount(style: .file))
                        )
                    + "\n" + String(localized: .editorUseTerminal)
                )
            case .binary:
                Text(.editorBinary)
            }
        } actions: {
            if refusal == .binary {
                Button(String(localized: .editorOpenHex)) { model.openAsHex() }
                    .buttonStyle(.borderedProminent)
                Button(String(localized: .editorOpenAsText)) {
                    model.openAsText()
                    if case .ready(let decoded) = model.phase { text = decoded.text }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { closeButton }
    }

    private func failure(_ report: ErrorReport) -> some View {
        ErrorReportSheet(report: report) { dismiss() }
    }

    // MARK: - Plumbing

    private var name: String { (path as NSString).lastPathComponent }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                if isDirty { confirmDiscard = true } else { dismiss() }
            } label: {
                Label(String(localized: .actionBack), systemImage: "chevron.backward")
            }
        }
    }
}
