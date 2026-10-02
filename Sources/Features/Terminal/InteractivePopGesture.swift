// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Gives the swipe back to a screen that has hidden its navigation bar.
///
/// `UINavigationController` switches its own `interactivePopGestureRecognizer`
/// off while the bar is hidden, and SwiftUI's `NavigationStack` is one
/// underneath, so `.toolbar(.hidden, for: .navigationBar)` takes the gesture
/// with it. On the terminal screen that is not a cosmetic loss: the swipe is
/// how most people leave a pushed screen, and here it is also what closes the
/// session.
///
/// Measured rather than assumed, both ways, by `TerminalTitleBarUITests`: with
/// the bar fixed the swipe leaves the terminal, with the bar hidden it did
/// nothing at all. That control run is what says the gesture is ours to give
/// back and not something that was already broken.
///
/// The way back is the one UIKit has always answered with: switch the
/// recogniser on again and answer for it yourself. The only question it asks is
/// whether there is anything to pop, which is also the one thing that must not
/// be got wrong — allowing it on the root view controller is the classic way to
/// wedge a navigation stack. The delegate it had is put back when the screen
/// goes, so nothing of SwiftUI's is left holding ours.
///
/// Add it with `.background(InteractivePopGesture())`: it draws nothing and
/// takes no space.
struct InteractivePopGesture: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController { Controller() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {

        private weak var borrowed: UIGestureRecognizer?
        private weak var previousDelegate: UIGestureRecognizerDelegate?
        private var wasEnabled = true

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer,
                  gesture.delegate !== self else { return }
            borrowed = gesture
            previousDelegate = gesture.delegate
            wasEnabled = gesture.isEnabled
            gesture.delegate = self
            gesture.isEnabled = true
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard let borrowed, borrowed.delegate === self else { return }
            borrowed.delegate = previousDelegate
            borrowed.isEnabled = wasEnabled
            self.borrowed = nil
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
