// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        if view.font.pointSize != size {
            view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
