// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import SwiftUI
import UIKit

/// Places a session's `TerminalView` into SwiftUI.
///
/// `makeUIView` hands back the view the session already owns instead of building
/// one, so switching tabs re-parents the existing terminal rather than starting
/// a blank one.
struct TerminalHostView: UIViewRepresentable {

    let session: TerminalSession
    var fontSize: Int

    func makeUIView(context: Context) -> TerminalView {
        session.terminalView
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        let size = CGFloat(fontSize)
        let wanted = TerminalFont.regular(size: size)
        // Compare the family too: the size alone would not notice the very first
        // switch from the system font to the bundled one at the same point size.
        if view.font.pointSize != size || view.font.familyName != wanted.familyName {
            view.font = wanted
        }
    }
}
