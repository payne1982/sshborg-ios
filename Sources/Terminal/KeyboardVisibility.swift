// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

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
@Observable
final class KeyboardVisibility {

    private(set) var isVisible = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        observers = [
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = true }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isVisible = false }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
