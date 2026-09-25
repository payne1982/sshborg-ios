// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// The editing surface: a `UITextView` with ``ConfigSyntax``'s colours on it.
///
/// Android needed a third-party editor widget because a Compose text field lays
/// the whole file out on every keystroke, which a few hundred kilobytes of
/// configuration is already too much for. UIKit has no such problem — TextKit
/// lays out lazily and has done since it was NeXT's — so the editor here is the
/// system one, and what we add is the colouring, the monospaced font and the
/// keyboard's manners.
///
/// Those manners matter more than they sound. A configuration file is not prose:
/// autocorrect turns `usr` into `user`, autocapitalisation turns `permitrootlogin`
/// into `Permitrootlogin`, and smart quotes turn `"` into `"` — each of which
/// produces a file that looks right and does not work. All four are off, as they
/// are in the terminal. The suggestion bar can be turned back on from the
/// toolbar, because dictation needs a field that declares itself as text.
struct EditorTextView: UIViewRepresentable {

    @Binding var text: String
    let family: ConfigSyntax.Family
    let fontSize: Int
    let suggestions: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Self.font(size: fontSize)
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)

        // A file is not a sentence. See the note on the type.
        view.autocorrectionType = suggestions ? .yes : .no
        view.autocapitalizationType = .none
        view.spellCheckingType = suggestions ? .yes : .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no

        context.coordinator.highlighter.family = family
        context.coordinator.highlighter.font = Self.font(size: fontSize)
        view.text = text
        context.coordinator.highlightAll(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let font = Self.font(size: fontSize)
        var needsRepaint = false

        if coordinator.highlighter.family != family {
            coordinator.highlighter.family = family
            needsRepaint = true
        }
        if view.font != font {
            view.font = font
            coordinator.highlighter.font = font
            needsRepaint = true
        }
        if view.autocorrectionType != (suggestions ? .yes : .no) {
            view.autocorrectionType = suggestions ? .yes : .no
            view.spellCheckingType = suggestions ? .yes : .no
            // The keyboard only picks the change up on its next appearance.
            if view.isFirstResponder { view.reloadInputViews() }
        }

        // Only when the text came from somewhere else — a charset change, a
        // reload. Assigning what the user has just typed would move the caret
        // to the end on every keystroke.
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            )
            needsRepaint = true
        }

        if needsRepaint {
            coordinator.highlightAll(view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// The font the terminal uses, at the size the editor was given — one
    /// monospaced face across the app, rather than whatever the system calls
    /// monospaced today. Android made the same change on 23/09/2026.
    private static func font(size: Int) -> UIFont {
        TerminalFont.regular(size: CGFloat(size))
    }

    final class Coordinator: NSObject, UITextViewDelegate {

        var parent: EditorTextView
        let highlighter: SyntaxHighlighter

        init(_ parent: EditorTextView) {
            self.parent = parent
            self.highlighter = SyntaxHighlighter(family: parent.family)
        }

        func highlightAll(_ view: UITextView) {
            highlighter.highlightAll(view.textStorage)
        }

        func textViewDidChange(_ view: UITextView) {
            // The edited range as the view has it: the paragraph the caret is
            // in, which is what the incremental pass needs as a starting point.
            let caret = view.selectedRange
            highlighter.update(view.textStorage, edited: caret)

            // Typing attributes are not part of the storage, so without this the
            // *next* character typed would inherit the colour of the run the
            // caret happens to sit in.
            view.typingAttributes = [
                .font: highlighter.font,
                .foregroundColor: highlighter.palette.plain,
            ]

            parent.text = view.text
        }
    }
}
