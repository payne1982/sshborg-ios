// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import UIKit

/// The terminal settings that act on the view rather than on the connection:
/// the double-tap action, inverted scrolling, the scrollback size, and
/// pinch-to-zoom — plus the swipe that scrolls inside tmux and other full-screen
/// apps. Counterpart of the Android `TerminalView`'s `GestureListener` and
/// `ScaleListener`.
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
    private let wheelPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    /// Points dragged but not yet worth a whole line. Carried across events,
    /// as Android's `scrollRemainderY` is, or a slow drag never moves at all.
    private var remainder: CGFloat = 0

    private var coast: CADisplayLink?
    private var coastVelocity: CGFloat = 0
    private var coastTimestamp: CFTimeInterval = 0

    /// Where the finger left the screen when the momentum is a wheel's, which
    /// keeps reporting at that cell. Nil when it scrolls the view.
    private var coastWheelPoint: CGPoint?

    private var pinchStartSize: CGFloat = 0

    init(terminal: TerminalView, send: @escaping (Data) -> Void, zoom: @escaping (CGFloat) -> Void) {
        self.terminal = terminal
        self.send = send
        self.zoom = zoom
        super.init()

        invertedPan.addTarget(self, action: #selector(handleInvertedPan(_:)))
        invertedPan.maximumNumberOfTouches = 1
        invertedPan.isEnabled = false
        invertedPan.delegate = self
        terminal.addGestureRecognizer(invertedPan)

        wheelPan.addTarget(self, action: #selector(handleWheelPan(_:)))
        wheelPan.maximumNumberOfTouches = 1
        wheelPan.delegate = self
        terminal.addGestureRecognizer(wheelPan)
        // Both scrolling drags wait for the wheel to decline, which it does the
        // moment a swipe starts anywhere but in a full-screen app that asked for
        // the mouse. A swipe is never a scroll and a wheel at once.
        terminal.panGestureRecognizer.require(toFail: wheelPan)
        invertedPan.require(toFail: wheelPan)

        for longPress in Self.longPressRecognizers(on: terminal) {
            longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        }

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

    // MARK: - Long press

    /// Every long-press recogniser on the view, SwiftTerm's among them.
    ///
    /// All of them rather than the first: picking the first on 14/09/2026 hung
    /// the handler on some other one and it never ran. Being on a stray one
    /// costs nothing, because `select(_:)` does nothing unless SwiftTerm's own
    /// long press has just recorded a position.
    static func longPressRecognizers(on terminal: TerminalView) -> [UILongPressGestureRecognizer] {
        (terminal.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
    }

    /// Selects straight away, as Android does.
    ///
    /// SwiftTerm's long press only opens the edit menu, and a selection begins
    /// from its Select item — a step nobody looks for, which on the phone read
    /// as "the copy and paste menu comes up, but nothing can be selected"
    /// (14/09/2026). This chooses that item for the user: SwiftTerm's own
    /// handler has just recorded where the finger is, and `select(_:)` selects
    /// the word there and brings the menu back with Copy in it.
    @objc private func handleLongPress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        // On the next turn, so SwiftTerm's handler for the same recogniser has
        // run whichever of the two targets is called first.
        DispatchQueue.main.async { [weak self] in
            guard let terminal = self?.terminal, !terminal.selectionActive else { return }
            // The menu SwiftTerm has just opened lists Select, not Copy, and a
            // menu already on screen is not asked again. Closed here,
            // `select(_:)` reopens it with the items a selection offers.
            UIMenuController.shared.hideMenu()
            terminal.select(nil)
        }
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

    // MARK: - Scrolling inside full-screen apps

    /// Whether a swipe goes to the remote app as wheel notches instead of
    /// scrolling the view. Android's `reportsWheel`, condition for condition.
    ///
    /// Only on the alternate screen: on the main screen there is real history
    /// above the prompt, and scrolling it here is what the finger is after.
    /// The alternate screen has none — SwiftTerm gives it no scrollback — so
    /// there the swipe is better spent on the app, which scrolls itself; in
    /// tmux that is its own history rather than the shell underneath. And only
    /// once the app has asked for mouse events, or the notches mean nothing.
    static func reportsWheel(_ terminal: Terminal) -> Bool {
        terminal.isCurrentBufferAlternate && terminal.mouseMode != .off
    }

    /// The wheel button for a drag of `lines`, positive being a finger moving
    /// down. Unless inverted, that reads older output, as the main screen's
    /// scroll does: wheel up, button 4. Down is 5.
    static func wheelButton(lines: Int, inverted: Bool) -> Int {
        (lines > 0) != inverted ? 4 : 5
    }

    /// Momentum for a reported wheel, relative to the view's own. Android found
    /// a full-strength flick overshooting: the view does not move, so there is
    /// no moving content to judge the speed by, and even a gentle one ran away.
    static let wheelCoastDamping: CGFloat = 0.7

    @objc private func handleWheelPan(_ pan: UIPanGestureRecognizer) {
        guard let terminal else { return }
        switch pan.state {
        case .began:
            stopCoasting()
            remainder = 0
        case .changed:
            let dy = pan.translation(in: terminal).y
            pan.setTranslation(.zero, in: terminal)
            wheel(byPoints: dy, at: pan.location(in: terminal), in: terminal)
        case .ended:
            startCoasting(
                velocity: pan.velocity(in: terminal).y * Self.wheelCoastDamping,
                wheelAt: pan.location(in: terminal)
            )
        default:
            break
        }
    }

    /// One notch per line of travel, at the cell under the finger — the cell is
    /// what tells tmux which pane to scroll. One per line because tmux moves
    /// about a line per notch, and Android's coarser first ratio made a long
    /// swipe crawl.
    private func wheel(byPoints dy: CGFloat, at point: CGPoint, in terminal: TerminalView) {
        let emulator = terminal.getTerminal()
        // The app may have left the alternate screen, or dropped the mouse,
        // while a flick was still coasting.
        guard Self.reportsWheel(emulator) else {
            stopCoasting()
            return
        }

        let rows = max(1, emulator.rows)
        let cols = max(1, emulator.cols)
        let cellHeight = terminal.bounds.height / CGFloat(rows)
        let step = Self.wholeLines(accumulated: remainder + dy, cellHeight: cellHeight)
        remainder = step.remainder
        guard step.lines != 0 else { return }

        // The view is a scroll view, so the location includes its offset.
        let x = point.x - terminal.bounds.minX
        let y = point.y - terminal.bounds.minY
        let col = min(max(0, Int(x / (terminal.bounds.width / CGFloat(cols)))), cols - 1)
        let row = min(max(0, Int(y / cellHeight)), rows - 1)
        let flags = emulator.encodeButton(
            button: Self.wheelButton(lines: step.lines, inverted: appliedInvertedScroll ?? false),
            release: false, shift: false, meta: false, control: false
        )
        for _ in 0..<abs(step.lines) {
            // Pixel coordinates in points, as SwiftTerm's own mouse events do.
            emulator.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: Int(x), pixelY: Int(y))
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

    private func startCoasting(velocity: CGFloat, wheelAt point: CGPoint? = nil) {
        stopCoasting()
        guard abs(velocity) >= Self.minimumCoastSpeed else { return }
        coastVelocity = velocity
        coastWheelPoint = point
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

        let travel = coastVelocity * CGFloat(interval)
        if let point = coastWheelPoint {
            wheel(byPoints: travel, at: point, in: terminal)
        } else {
            scroll(byPoints: travel, in: terminal)
        }
        guard coast != nil else { return }
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

extension TerminalTouchHandling: UIGestureRecognizerDelegate {

    /// The wheel declines every swipe it should not take, which is what lets
    /// the scrolling drags waiting on it go ahead. A selection in progress keeps
    /// its gestures, as on Android: neither drag starts while one is up, the
    /// same rule `SessionTerminalView` applies to the scroll view's own pan.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let terminal else { return false }
        if terminal.selectionActive { return false }
        if recognizer === wheelPan { return Self.reportsWheel(terminal.getTerminal()) }
        return true
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
