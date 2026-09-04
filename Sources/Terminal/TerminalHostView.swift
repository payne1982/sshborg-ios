// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import SwiftUI
import UIKit

/// Places a session's `TerminalView` into SwiftUI.
///
/// A container that stays put, with the selected session's terminal moved in and
/// out of it. The terminal is owned by the session, not by this view, so
/// switching tabs must re-parent the existing one — building a new one would
/// show a blank screen where a live shell is.
///
/// Two failed attempts are worth recording, because both looked right:
///
/// Handing `session.terminalView` straight back from `makeUIView` does not work:
/// SwiftUI calls that once per identity, and every session renders at the same
/// spot in the tree, so switching tabs renamed the screen and left the previous
/// terminal on it.
///
/// Keying the view on the session id fixes that and breaks the keyboard: an
/// identity change is a teardown, the destroyed view was the first responder,
/// and the keyboard drops every time you change tab. Hence the container — one
/// identity for SwiftUI, a swap underneath, and the focus handed over rather
/// than lost.
struct TerminalHostView: UIViewRepresentable {

    let session: TerminalSession
    var fontSize: Int

    /// The colours to draw in. Passed in rather than read here so the choice —
    /// which depends on a preference and on the app's appearance — stays in
    /// SwiftUI, where both of those are observable.
    var palette: TerminalPalette


    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        // Matches the terminal underneath it, so a resize never flashes the
        // wrong colour. Set again in `updateUIView`, which is where it follows
        // the palette; this is only so the very first frame is right.
        container.backgroundColor = palette.background
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let terminal = session.terminalView

        if terminal.superview !== container {
            let previous = container.subviews.first
            let hadKeyboard = previous?.isFirstResponder ?? false

            // SwiftTerm ships its own accessory bar above the keyboard, and this
            // app has a ported one with more keys and the pin. Both were
            // showing, two rows deep, eating screen the terminal needs — found
            // by looking at a screenshot with the keyboard up, which no test
            // would have caught.
            terminal.inputAccessoryView = nil
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: container.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            // Hand the focus over *before* the old view leaves the hierarchy.
            // Removing a first responder makes it resign, and with nothing else
            // claiming the keyboard it packs up — so the order here is the whole
            // difference between the keyboard staying and the keyboard blinking
            // away and back.
            if hadKeyboard {
                terminal.becomeFirstResponder()
            }
            previous?.removeFromSuperview()
        }


        container.backgroundColor = palette.background

        // Guarded, because `installColors` rebuilds all 256 entries and forces a
        // full redraw, and this runs on every pass of the enclosing body — which
        // includes every `cd`, since that changes the tab title.
        //
        // The two native colours are the check: SwiftTerm hands back exactly
        // what was last assigned to it, so if both already match, the palette
        // that came with them does too.
        if terminal.nativeForegroundColor != palette.foreground
            || terminal.nativeBackgroundColor != palette.background {
            terminal.installColors(palette.ansi)
            terminal.nativeForegroundColor = palette.foreground
            terminal.nativeBackgroundColor = palette.background
            terminal.caretColor = palette.caret
        }

        let size = CGFloat(fontSize)
        let wanted = TerminalFont.regular(size: size)
        // Compare the family too: the size alone would not notice the very first
        // switch from the system font to the bundled one at the same point size.
        if terminal.font.pointSize != size || terminal.font.familyName != wanted.familyName {
            terminal.font = wanted
        }
    }

    /// Fill whatever is offered. An empty container has no intrinsic size, and
    /// without this the terminal can be laid out at nothing at all.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIScreen.main.bounds.width,
            height: proposal.height ?? UIScreen.main.bounds.height
        )
    }
}
