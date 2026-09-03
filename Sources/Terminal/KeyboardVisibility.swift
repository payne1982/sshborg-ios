// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import Perception

/// Whether the software keyboard is on screen.
///
/// Needed because the extra key row is meant to accompany the keyboard, and the
/// pin exists to keep it when the keyboard goes away. Without knowing which
/// state we are in, the row is simply always there and the pin controls nothing
/// — which is what it did until this existed.
///
/// SwiftUI has no first-class way to ask. `keyboardWillShow`/`keyboardWillHide`
/// is the supported one, and "will" rather than "did" so the row appears in the
/// same animation as the keyboard instead of a beat behind it.
@MainActor
@Perceptible
final class KeyboardVisibility {

    private(set) var isVisible = false

    @PerceptionIgnored private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.isVisible = true
                    #if DEBUG
                    // The keyboard's own idea of how much room it takes. The
                    // reported symptom is that the terminal keeps two rows more
                    // than fit, and 45pt — the system assistant bar this app
                    // removes — is about two rows. This is the number that
                    // decides whether that coincidence means anything.
                    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                    KeyboardDiagnostics.log("keyboard.show", [
                        "height": Int(frame?.height ?? -1),
                        "y": Int(frame?.origin.y ?? -1),
                    ])
                    #endif
                }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isVisible = false
                    #if DEBUG
                    KeyboardDiagnostics.log("keyboard.hide")
                    #endif
                }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
