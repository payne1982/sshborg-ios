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

    /// Logs only when the line would differ from the last one for this event.
    ///
    /// `updateUIView` runs on every SwiftUI update of the terminal, which during
    /// output is hundreds of times a second, and `NSLog` is not free — it
    /// formats and crosses into the system log each time. Instrumentation that
    /// heavy risks *causing* the main-thread stalls it was added to find, which
    /// would make every measurement here worthless. Geometry only matters when
    /// it changes, so only changes are written.
    private static var lastLine: [String: String] = [:]

    static func logIfChanged(_ event: String, _ pairs: [String: Any]) {
        let detail = pairs
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        guard lastLine[event] != detail else { return }
        lastLine[event] = detail
        NSLog("SSHBORGDIAG %@ %@", event, detail)
    }

    /// Reports when the main thread stopped answering, and for how long.
    ///
    /// Added 04/09/2026 for the report that the extra key bar "works in fits and
    /// starts": keys and arrows dead for a while, then all fine again. A
    /// hit-testing fault does not come and go; a blocked main thread does, and
    /// while it is blocked nothing draws either — which matches the other half
    /// of the report, that pressed keys showed no feedback at all.
    ///
    /// The measurement is the loop itself. It asks to be woken every 100ms and
    /// writes a line whenever it was woken much later than that, because the
    /// only thing that can delay it is the main thread being busy.
    static func startStallWatchdog() {
        guard !isWatching else { return }
        isWatching = true

        Task { @MainActor in
            var last = ContinuousClock.now
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                let now = ContinuousClock.now
                let late = (last.duration(to: now) - .milliseconds(100))
                if late > .milliseconds(250) {
                    log("stall", ["blockedMs": Int(late.components.seconds * 1000
                        + late.components.attoseconds / 1_000_000_000_000_000)])
                }
                last = now
            }
        }
    }

    private static var isWatching = false

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
