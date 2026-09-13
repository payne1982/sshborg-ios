// SPDX-License-Identifier: GPL-3.0-or-later

import ObjectiveC
import SwiftTerm
import UIKit

/// SwiftTerm's terminal view, telling the software keyboard that there is
/// always something to delete.
///
/// **Holding backspace deleted one character and stopped.** iOS repeats the
/// delete key only while the text input answers `hasText` with yes, and
/// SwiftTerm answers from its own input-session shadow — the few characters of
/// a word being composed — which is empty at an ordinary shell prompt. The far
/// side, the line the shell is editing, is exactly what the view cannot see.
/// `deleteBackward()` already sends a backspace in that state; only the repeat
/// was refused. Reported from the phone on 14/09/2026.
///
/// SwiftTerm fixed the declaration upstream after 1.15.0 — `hasText` became
/// `open`, with a comment saying an embedder that knows its far side always has
/// something to delete should say so. At 1.15.0 it is `public`, which Swift does
/// not let a subclass in another module override. UIKit asks through the
/// Objective-C runtime, though, so the answer is added to this subclass there.
/// SwiftTerm's own Swift code still reads its original value. When the pinned
/// version has `open var hasText`, replace this with a plain `override`.
final class ShellTerminalView: TerminalView {

    /// Installs the Objective-C `hasText` once, on this subclass only.
    ///
    /// `class_addMethod` adds a method to this class without touching
    /// `TerminalView` itself, and does nothing if this class already has one.
    private static let installAlwaysHasText: Void = {
        let selector = #selector(getter: UIKeyInput.hasText)
        let answer: @convention(block) (AnyObject) -> Bool = { _ in true }
        let types = method_getTypeEncoding(class_getInstanceMethod(TerminalView.self, selector)!)
        class_addMethod(ShellTerminalView.self, selector, imp_implementationWithBlock(answer), types)
    }()

    override init(frame: CGRect) {
        _ = Self.installAlwaysHasText
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        _ = Self.installAlwaysHasText
        super.init(coder: coder)
    }
}
