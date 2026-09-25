// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// Opens one remote file, holds it while it is edited, and writes it back.
///
/// Counterpart of the Android editor's half of `SftpViewModel`. The text itself
/// lives in the view — a model updated on every keystroke would redraw the whole
/// SFTP screen behind it — and what lives here is everything that touches the
/// server, plus the decision of what kind of file this is.
@MainActor
@Perceptible
final class EditorModel {

    /// What the editor is doing with this file.
    enum Phase: Equatable {
        /// Reading it off the server. `size` is what the server said it is,
        /// `received` how much has arrived: a file of megabytes over a slow link
        /// needs to show that it is moving.
        case loading(received: UInt64, size: UInt64)
        /// Open as text, with everything needed to write the bytes back.
        case ready(TextFile.Decoded)
        /// Open as bytes, because it is not text.
        case hex(Data)
        /// Readable, but not editable as text — see ``Refusal``.
        case unsupported(Refusal, size: UInt64)
        /// Reading or writing failed.
        case failed(ErrorReport)
    }

    enum Refusal: Equatable {
        case tooLarge
        case binary
    }

    /// The largest file the editor will open, text or hex.
    ///
    /// A memory limit, not a drawing one: `UITextView` lays out lazily, so the
    /// length of the file does not decide how the editor feels. What it decides
    /// is how much of the phone's memory this holds — the bytes, the string and
    /// the attributed copy at once.
    static let maximumBytes: UInt64 = 4 * 1024 * 1024

    let path: String
    var name: String { (path as NSString).lastPathComponent }

    private(set) var phase: Phase = .loading(received: 0, size: 0)
    private(set) var isSaving = false
    private(set) var didSave = false

    /// A failed save, shown over the editor rather than replacing it: a file
    /// that could not be written is exactly when the user must keep their text.
    var problem: ErrorReport?

    /// The bytes as they arrived, kept so another charset can be tried against
    /// the same file without fetching it again.
    @PerceptionIgnored private var raw = Data()

    @PerceptionIgnored private let session: SFTPSession

    init(path: String, session: SFTPSession) {
        self.path = path
        self.session = session
    }

    // MARK: - Reading

    /// Fetches the file and decides what to do with it.
    ///
    /// The size is asked for first, because refusing a 900 MB log after
    /// downloading it would be a special kind of rude. `asText` forces the text
    /// path for a file the binary test rejected — the user asked for it, and the
    /// round trip still has to be exact, so the worst case is that it looks
    /// wrong.
    func load(asText forcedText: Bool = false, asHex forcedHex: Bool = false) async {
        phase = .loading(received: 0, size: 0)

        let size = (try? await session.stat(path))?.size ?? 0
        guard size <= Self.maximumBytes else {
            phase = .unsupported(.tooLarge, size: size)
            return
        }
        phase = .loading(received: 0, size: size)

        // Through a temporary file rather than into memory directly: that is the
        // transfer path with the retries, the cancellation and the progress
        // already in it, and four megabytes is not worth a second one.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshborg-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            try await session.download(
                from: path,
                to: scratch,
                isCancelled: nil,
                onProgress: { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, case .loading(_, let total) = self.phase else { return }
                        self.phase = .loading(received: bytes, size: total)
                    }
                }
            )
            raw = try Data(contentsOf: scratch)
        } catch {
            phase = .failed(
                ErrorReport(title: String(localized: .editorFailed), name: name, error: error)
            )
            return
        }

        decideWhatThisIs(forcedText: forcedText, forcedHex: forcedHex)
    }

    private func decideWhatThisIs(forcedText: Bool, forcedHex: Bool) {
        if forcedHex {
            phase = .hex(raw)
            return
        }

        if let decoded = TextFile.decode(raw, allowBinary: forcedText) {
            phase = .ready(decoded)
        } else {
            // Not text. The hex editor is offered rather than opened: someone
            // who tapped Edit on a JPEG meant to tap something else.
            phase = .unsupported(.binary, size: UInt64(raw.count))
        }
    }

    /// Reads the same bytes as another charset, which is the one judgement the
    /// machine cannot make.
    func reread(as charset: TextFile.Charset) {
        guard let decoded = TextFile.decode(raw, as: charset, bom: nil) else { return }
        phase = .ready(decoded)
    }

    /// Opens a file the binary test rejected as text anyway.
    func openAsText() {
        decideWhatThisIs(forcedText: true, forcedHex: false)
    }

    func openAsHex() {
        phase = .hex(raw)
    }

    /// The charsets this file could be read as, best guess first. Worked out
    /// once, off the main actor: it decodes the file once per candidate, which
    /// for a few megabytes is long enough to drop a frame.
    func readableCharsets() async -> [TextFile.Charset] {
        let bytes = raw
        return await Task.detached(priority: .userInitiated) {
            TextFile.readableCharsets(of: bytes)
        }.value
    }

    // MARK: - Writing

    /// Writes `text` back, in the file's own charset, with its own line ending
    /// and its own byte-order mark.
    ///
    /// Refuses rather than mangling: text that the file's charset cannot write —
    /// a € typed into a Latin-1 file — is a thing to say out loud, not to
    /// replace with a "?".
    func save(_ text: String) async {
        guard case .ready(let decoded) = phase else { return }

        guard let bytes = TextFile.encode(text, from: decoded) else {
            problem = ErrorReport(
                title: String(localized: .editorSaveFailed),
                failures: [
                    FileFailure(
                        name: name,
                        message: String(localized: .editorCannotEncode)
                            .replacingOccurrences(of: "%1$@", with: decoded.charset.name),
                        detail: ""
                    )
                ]
            )
            return
        }

        await write(bytes) {
            // What is on screen is now what is on the server, line endings and
            // all, so the decoded state has to agree with it — otherwise the
            // next save would re-apply a change that has already landed.
            self.phase = .ready(
                TextFile.Decoded(
                    text: text,
                    charset: decoded.charset,
                    bom: decoded.bom,
                    lineEnding: decoded.lineEnding,
                    mixedEndings: false
                )
            )
        }
    }

    /// Writes raw bytes back, which is what the hex editor saves.
    func save(bytes: Data) async {
        await write(bytes) { self.phase = .hex(bytes) }
    }

    private func write(_ bytes: Data, onSuccess: @escaping () -> Void) async {
        isSaving = true
        didSave = false
        defer { isSaving = false }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshborg-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            try bytes.write(to: scratch)
            try await session.upload(from: scratch, to: path, isCancelled: nil, onProgress: nil)
            raw = bytes
            onSuccess()
            didSave = true
        } catch {
            problem = ErrorReport(
                title: String(localized: .editorSaveFailed),
                name: name,
                error: error
            )
        }
    }
}
