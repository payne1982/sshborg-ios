// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import UIKit

/// The terminal settings that act on the view rather than on the connection:
/// the double-tap action, inverted scrolling, the scrollback size, and
/// pinch-to-zoom. Counterpart of the Android `TerminalView`'s `GestureListener`
/// and `ScaleListener`.
///
/// Until 13/09/2026 the first three were offered in Settings, stored, carried in
/// backups — and read by nothing, and there was no pinch at all. It came to
/// light only because the website's user guide was being checked against the
/// code, sentence by sentence.
///
/// Each `apply` is cheap when nothing changed, because the screen calls them on
/// every pass of its body.
@MainActor
final class TerminalTouchHandling: NSObject {

    private weak var terminal: TerminalView?
    private let send: (Data) -> Void
    private let zoom: (CGFloat) -> Void

    private var appliedDoubleTap: AppPreferences.DoubleTapAction?
    private var appliedInvertedScroll: Bool?
    private var appliedScrollback: Int?

    private let invertedPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    /// Points dragged but not yet worth a whole line. Carried across events,
    /// as Android's `scrollRemainderY` is, or a slow drag never moves at all.
    private var remainder: CGFloat = 0

    private var coast: CADisplayLink?
    private var coastVelocity: CGFloat = 0
    private var coastTimestamp: CFTimeInterval = 0

    private var pinchStartSize: CGFloat = 0

    init(terminal: TerminalView, send: @escaping (Data) -> Void, zoom: @escaping (CGFloat) -> Void) {
        self.terminal = terminal
        self.send = send
        self.zoom = zoom
        super.init()

        invertedPan.addTarget(self, action: #selector(handleInvertedPan(_:)))
        invertedPan.maximumNumberOfTouches = 1
        invertedPan.isEnabled = false
        terminal.addGestureRecognizer(invertedPan)

        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        terminal.addGestureRecognizer(pinch)
    }

    // MARK: - Double tap

    /// SwiftTerm's handler for its own double-tap, which selects a word.
    ///
    /// `@objc` but internal to SwiftTerm, so it can only be named by string.
    /// `TerminalTouchSettingsTests` pins that it still exists: if an update
    /// renames it, the test fails rather than the gesture quietly doing nothing.
    static let swiftTermDoubleTap = Selector(("doubleTap:"))

    /// The two-tap recogniser SwiftTerm installs. Reused rather than competing
    /// with a second one: its failure requirements — a single tap waits for it,
    /// and it waits for a triple tap — are exactly what a double tap needs, and
    /// a recogniser of our own would have none of them.
    static func doubleTapRecognizer(on terminal: TerminalView) -> UITapGestureRecognizer? {
        terminal.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first { $0.numberOfTapsRequired == 2 }
    }

    /// Hands the double tap to the shell, or back to SwiftTerm's word selection.
    ///
    /// Android sends nothing by default and selects nothing either; iOS keeps
    /// SwiftTerm's selection when the setting is off, since that is what the
    /// gesture already meant there and taking it away would buy nothing.
    func apply(doubleTap action: AppPreferences.DoubleTapAction) {
        guard action != appliedDoubleTap, let terminal,
              let recognizer = Self.doubleTapRecognizer(on: terminal) else { return }
        appliedDoubleTap = action

        let ownsSwiftTermHandler = terminal.responds(to: Self.swiftTermDoubleTap)
        recognizer.removeTarget(self, action: #selector(handleDoubleTap(_:)))
        if ownsSwiftTermHandler {
            recognizer.removeTarget(terminal, action: Self.swiftTermDoubleTap)
        }

        if action == .none {
            if ownsSwiftTermHandler {
                recognizer.addTarget(terminal, action: Self.swiftTermDoubleTap)
            }
        } else {
            recognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let terminal,
              let bytes = appliedDoubleTap?.bytes else { return }
        // Back to the live prompt first, as Android's `emitInput` does: a Tab
        // sent while reading old output would complete something out of sight.
        terminal.scrollTo(row: .max)
        send(bytes)
    }

    // MARK: - Scrollback

    func apply(scrollback lines: Int) {
        guard lines != appliedScrollback, let terminal else { return }
        appliedScrollback = lines
        terminal.getTerminal().changeScrollback(lines)
    }

    // MARK: - Inverted scrolling

    /// Replaces the scroll view's own drag with one that moves the other way.
    ///
    /// Not done by adjusting `contentOffset` from a gesture of our own:
    /// SwiftTerm only treats an offset change as the user reading back while its
    /// scroll view is *tracking*, so an offset set from outside is taken for a
    /// layout change and snapped back to the live output on the next line that
    /// arrives. `scrollUp` and `scrollDown` go through `scrollTo(row:)`, which
    /// sets that state itself — and they move in whole lines, which is how
    /// Android scrolls too.
    func apply(invertedScroll: Bool) {
        guard invertedScroll != appliedInvertedScroll, let terminal else { return }
        appliedInvertedScroll = invertedScroll
        terminal.isScrollEnabled = !invertedScroll
        invertedPan.isEnabled = invertedScroll
        if !invertedScroll { stopCoasting() }
    }

    @objc private func handleInvertedPan(_ pan: UIPanGestureRecognizer) {
        guard let terminal else { return }
        switch pan.state {
        case .began:
            stopCoasting()
            remainder = 0
        case .changed:
            let dy = pan.translation(in: terminal).y
            pan.setTranslation(.zero, in: terminal)
            scroll(byPoints: dy, in: terminal)
        case .ended:
            startCoasting(velocity: pan.velocity(in: terminal).y)
        default:
            break
        }
    }

    /// Positive lines move toward newer output. With the scroll inverted, a
    /// finger moving down (positive `dy`) is exactly that — "swipe up to see
    /// older output", as the setting's subtitle puts it.
    static func wholeLines(accumulated: CGFloat, cellHeight: CGFloat) -> (lines: Int, remainder: CGFloat) {
        guard cellHeight > 0 else { return (0, accumulated) }
        let lines = Int(accumulated / cellHeight)
        return (lines, accumulated - CGFloat(lines) * cellHeight)
    }

    private func scroll(byPoints dy: CGFloat, in terminal: TerminalView) {
        let rows = max(1, terminal.getTerminal().rows)
        let step = Self.wholeLines(accumulated: remainder + dy, cellHeight: terminal.bounds.height / CGFloat(rows))
        remainder = step.remainder
        if step.lines > 0 {
            terminal.scrollDown(lines: step.lines)
        } else if step.lines < 0 {
            terminal.scrollUp(lines: -step.lines)
        }
    }

    // MARK: Momentum

    /// Below this, in points per second, a lifted finger just stops.
    static let minimumCoastSpeed: CGFloat = 40

    /// The speed after `interval` seconds of coasting, at the rate a
    /// `UIScrollView` decelerates, so the inverted scroll does not feel heavier
    /// or slipperier than the ordinary one beside it.
    static func decayed(_ velocity: CGFloat, over interval: CFTimeInterval) -> CGFloat {
        let perMillisecond = Double(UIScrollView.DecelerationRate.normal.rawValue)
        return velocity * CGFloat(pow(perMillisecond, interval * 1000))
    }

    private func startCoasting(velocity: CGFloat) {
        stopCoasting()
        guard abs(velocity) >= Self.minimumCoastSpeed else { return }
        coastVelocity = velocity
        coastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(coastStep(_:)))
        link.add(to: .main, forMode: .common)
        coast = link
    }

    @objc private func coastStep(_ link: CADisplayLink) {
        guard let terminal else {
            stopCoasting()
            return
        }
        if coastTimestamp == 0 {
            coastTimestamp = link.timestamp
            return
        }
        let interval = link.timestamp - coastTimestamp
        coastTimestamp = link.timestamp

        scroll(byPoints: coastVelocity * CGFloat(interval), in: terminal)
        coastVelocity = Self.decayed(coastVelocity, over: interval)
        if abs(coastVelocity) < Self.minimumCoastSpeed {
            stopCoasting()
        }
    }

    /// Also what breaks the display link's hold on this object: it retains its
    /// target until invalidated.
    private func stopCoasting() {
        coast?.invalidate()
        coast = nil
    }

    // MARK: - Pinch to zoom

    /// The size a pinch that started at `start` asks for: whole points, inside
    /// the same bounds as the Settings stepper.
    ///
    /// Whole points because every change of font makes SwiftTerm re-measure the
    /// grid and the server hear about a new window size; a pinch passing through
    /// every fraction would send dozens of them.
    static func zoomedSize(from start: CGFloat, scale: CGFloat) -> CGFloat {
        let wanted = (start * scale).rounded()
        let lower = CGFloat(AppPreferences.Limits.minTerminalFontSize)
        let upper = CGFloat(AppPreferences.Limits.maxTerminalFontSize)
        return min(max(wanted, lower), upper)
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard let terminal else { return }
        switch pinch.state {
        case .began:
            pinchStartSize = terminal.font.pointSize
        case .changed:
            let size = Self.zoomedSize(from: pinchStartSize, scale: pinch.scale)
            if size != terminal.font.pointSize {
                zoom(size)
            }
        default:
            break
        }
    }
}

extension AppPreferences.DoubleTapAction {

    /// What the gesture types. One Tab completes; two in a row make readline
    /// list the candidates. The same bytes Android sends.
    var bytes: Data? {
        switch self {
        case .none: nil
        case .tab: Data([0x09])
        case .tabTwice: Data([0x09, 0x09])
        }
    }
}
