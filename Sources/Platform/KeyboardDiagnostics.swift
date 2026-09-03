// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import UIKit

/// Temporary instrumentation for two keyboard defects reported from the iPhone X
/// on 03/09/2026: the hide-keyboard key does not hide it, and two extra terminal
/// rows are lost when it is up, with the cursor row ending under it.
///
/// It exists because neither can be settled by reading code. Both have a
/// plausible cause — something re-taking focus, and UIKit reserving space for a
/// system assistant bar that was removed — and both plausible causes are
/// numerically close enough to the symptom to be believed without evidence.
/// These lines are the evidence.
///
/// **This whole file is `#if DEBUG` and is meant to be deleted** once the two
/// are fixed. Every line is prefixed `SSHBORGDIAG` so it can be grepped out of a
/// device console in one pass.
///
/// `NSLog` and not `print`: `print` goes to stdout, which is only collected when
/// a debugger is attached. `NSLog` reaches the device's own log, which can be
/// read from the Mac without Xcode in the way.
enum KeyboardDiagnostics {

    static func log(_ event: String, _ pairs: [String: Any] = [:]) {
        let detail = pairs
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        NSLog("SSHBORGDIAG %@ %@", event, detail)
    }

    /// Who currently holds the keyboard.
    ///
    /// `resignFirstResponder()` on a view that is not the first responder does
    /// nothing and reports nothing, which is one of the two candidate
    /// explanations — SwiftTerm may keep an inner input view rather than being
    /// the responder itself. Naming the actual responder tells the two apart.
    static func firstResponderDescription() -> String {
        FirstResponderProbe.find().map { String(describing: type(of: $0)) } ?? "none"
    }

    /// Heights that should add up and, by the report, do not.
    static func geometry(of terminal: UIView) -> [String: Any] {
        let window = terminal.window
        return [
            "termH": Int(terminal.bounds.height),
            "termW": Int(terminal.bounds.width),
            "winH": Int(window?.bounds.height ?? 0),
            "safeBottom": Int(window?.safeAreaInsets.bottom ?? 0),
            "termSafeBottom": Int(terminal.safeAreaInsets.bottom),
            "accessory": terminal.inputAccessoryView == nil ? "nil" : "set",
            "isFirstResponder": terminal.isFirstResponder,
        ]
    }
}

/// Finds the first responder by asking every responder in the chain to identify
/// itself. There is no public API for this; sending an action to `nil` walks the
/// chain, and only the first responder answers.
private final class FirstResponderProbe {
    private static weak var found: UIResponder?

    static func find() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.sshborgDiagnosticIdentify), to: nil, from: nil, for: nil)
        return found
    }

    static func record(_ responder: UIResponder) { found = responder }
}

private extension UIResponder {
    @objc func sshborgDiagnosticIdentify() { FirstResponderProbe.record(self) }
}
#endif
