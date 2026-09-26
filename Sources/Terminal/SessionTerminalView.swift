// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import UIKit

/// SwiftTerm's view, minus the gesture that turns a swipe into a mouse drag,
/// and with a selection that survives the output arriving under it.
///
/// ## The drag
///
/// When the remote app asks for mouse events — tmux with `set -g mouse on`, vim
/// with `set mouse=a` — SwiftTerm installs a pan recogniser that reports the
/// finger as the left button held down and dragged. To tmux that is a selection,
/// so a swipe meant to scroll selected text instead (reported from the phone on
/// 14/09/2026, while Android had already learned to scroll there).
///
/// Android never reports a drag: a swipe becomes wheel notches on the alternate
/// screen and local scrolling everywhere else. `TerminalTouchHandling` does the
/// same here, and this is what keeps SwiftTerm's drag out of its way.
///
/// Taps are left alone: a tap still arrives as a click, which is how a tmux pane
/// or a vim split is picked.
final class SessionTerminalView: TerminalView {

    override func mouseModeChanged(source: Terminal) {
        // Deliberately not calling super, which is what installs the drag.
    }

    // MARK: - The selection

    /// Keeps a selection alive while output arrives.
    ///
    /// SwiftTerm drops the selection on every chunk it is fed while
    /// `allowMouseReporting` is on, which is its default. So a shell repainting
    /// its prompt when the keyboard resizes the window, or tmux redrawing its
    /// status line, took the selection away before it could be copied —
    /// "nothing can be selected, outside tmux too", reported on 14/09/2026. On
    /// the simulator, with no server and so no output, the same selection stayed
    /// on screen with both handles.
    ///
    /// The flag is off only while something is selected: the touches belong to
    /// the selection then, as on Android, and the moment it goes a tap is a
    /// click for tmux again.
    /// While something is selected, a drag belongs to the selection.
    ///
    /// SwiftTerm extends a selection with a pan recogniser of its own, and
    /// nothing arbitrates between it and the scroll view's pan on the same view:
    /// the scroll view won, so dragging a handle scrolled (or, with nothing to
    /// scroll, did nothing) and the selection never grew. Measured on the
    /// simulator on 14/09/2026 — the screenshot after the drag was identical to
    /// the one before it.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer && selectionActive {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        allowMouseReporting = !selectionActive
    }

    // MARK: - The keyboard's idea of where the text is

    /// Stops UIKit painting its selection over the whole screen.
    ///
    /// `TerminalView` conforms to `UITextInput`, and the geometry it owes that
    /// protocol is stubbed: `selectionRects(for:)` answers `bounds` — the entire
    /// view — for any range at all, and so do `firstRect` and `caretRect`
    /// (`iOSTextInput.swift`, unchanged from 1.15.0 through 1.20.0). So the
    /// moment UIKit has something to highlight, it highlights everything.
    ///
    /// That is what "every so often, typing fast, the whole screen goes blue and
    /// then the flash is gone" was, reported from an iPhone 18 Pro on
    /// 26/09/2026. Swipe-typing keeps the word being drawn as *marked text*
    /// while the finger is down: UIKit asks where that text is, is told the
    /// whole terminal, paints its selection over it, and drops it again when the
    /// word is committed. Holding the space bar opens the keyboard's trackpad
    /// and reaches the same stub through `caretRect`. Harmless — no selection is
    /// made and the characters arrive intact — but it looks exactly like an
    /// accidental select-all.
    ///
    /// Nothing is given up by answering nothing. UIKit's document here is a
    /// scratch buffer of the few characters typed since the last reset, kept so
    /// autocorrect and dictation have something to work on; it is never on
    /// screen. The selection the user can see is SwiftTerm's own, painted by the
    /// terminal renderer in `selectedTextBackgroundColor`, and UIKit knows
    /// nothing about it.
    ///
    /// ## Why this is not an `override`
    ///
    /// Both methods are `public`, not `open`, and live in SwiftTerm's
    /// `extension TerminalView: UITextInput`, so the compiler refuses:
    /// *overriding non-open instance method outside of its defining module*.
    /// They are `@objc` — they must be, UIKit calls them by selector — so they
    /// are added to **this** class at runtime instead. Nothing of SwiftTerm's is
    /// swizzled: the class given a method is ours, the inherited implementation
    /// stays exactly where it is, and the two selectors are public UIKit API,
    /// not private ones.
    private static let installedGeometry: Void = {
        let noRects: @convention(block) (SessionTerminalView, AnyObject) -> [UITextSelectionRect] = { _, _ in [] }
        install("selectionRectsForRange:", imp_implementationWithBlock(noRects))

        let caret: @convention(block) (SessionTerminalView, AnyObject) -> CGRect = { view, _ in view.cursorCell }
        install("caretRectForPosition:", imp_implementationWithBlock(caret))
    }()

    /// Builds a terminal with those answers in place. A factory rather than an
    /// `init`, because SwiftTerm's initialisers are `public` too and cannot be
    /// overridden either.
    static func make(frame: CGRect) -> SessionTerminalView {
        _ = installedGeometry
        return SessionTerminalView(frame: frame)
    }

    /// Adds `imp` to this class under `name`, borrowing the inherited method's
    /// type encoding: writing one by hand for a `CGRect` return is exactly the
    /// kind of string nobody should be asked to proofread.
    ///
    /// If SwiftTerm ever stops answering the selector, the encoding cannot be
    /// read and nothing is installed — the flash comes back, rather than the app
    /// claiming a method whose shape it guessed.
    private static func install(_ name: String, _ imp: IMP) {
        let selector = NSSelectorFromString(name)
        guard let inherited = class_getInstanceMethod(self, selector),
              let types = method_getTypeEncoding(inherited) else {
            assertionFailure("SwiftTerm no longer answers \(name)")
            return
        }
        class_addMethod(self, selector, imp, types)
    }

    /// The cell the cursor sits on, in view coordinates — what `caretRect`
    /// should have been. The caret the user sees is SwiftTerm's own view, so
    /// this rect is only ever read by the system: by the floating cursor the
    /// space bar opens, and by whatever UIKit wants to place beside the caret.
    private var cursorCell: CGRect {
        let emulator = getTerminal()
        let rows = max(1, emulator.rows)
        let cols = max(1, emulator.cols)
        let size = CGSize(width: bounds.width / CGFloat(cols), height: bounds.height / CGFloat(rows))
        let cursor = emulator.getCursorLocation()
        return CGRect(
            origin: CGPoint(
                x: bounds.minX + CGFloat(cursor.x) * size.width,
                y: bounds.minY + CGFloat(cursor.y) * size.height
            ),
            size: size
        )
    }
}
