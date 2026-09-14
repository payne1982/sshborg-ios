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
}
