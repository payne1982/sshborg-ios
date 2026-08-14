// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The row of keys a software keyboard does not have but a terminal needs.
///
/// Key order follows the Android `ExtraKeyRow` so muscle memory carries across:
/// modifiers, then navigation, then paste, then the pin, then the function keys.
/// The pin sits *before* F1 rather than at the head of the row — an earlier
/// version put it first with a comment about it keeping its place while the rest
/// scrolled, which was invented here and is not where Android has it.
///
/// One key is ours alone: **hide keyboard**. Android dismisses the keyboard with
/// the system Back button and iOS has no such thing, so without a control here
/// the keyboard could be raised and never lowered.
///
/// Android's "word mode" toggle is still missing — it turns the soft keyboard's
/// suggestions on for composing a long command. SwiftTerm exposes the traits it
/// would need, so this is a gap to close, not an impossibility.
struct ExtraKeyRow: View {

    @Bindable var session: TerminalSession

    /// Whether the row stays on screen with the keyboard closed. Bound to the
    /// preference so the pin on the bar and the switch in Settings are the same
    /// control seen from two places, which is how the Android build has it.
    @Binding var isPinned: Bool

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // iPad's own software keyboard carries a dismiss key in its
                // bottom-right corner; iPhone's does not. Showing ours on iPad
                // would be a second button for the same job, in a bar that is
                // already long.
                if !isPad {
                    hideKeyboard
                    Divider().frame(height: 20)
                }

                toggle("Ctrl", isOn: $session.ctrlActive)
                toggle("Alt", isOn: $session.altActive)
                wordModeKey

                Divider().frame(height: 20)

                key("ESC") { send([0x1B]) }
                key("Tab") { send([0x09]) }

                key("↑", repeatsOnHold: true) { session.sendExtraKey(session.cursorKey("A")) }
                key("↓", repeatsOnHold: true) { session.sendExtraKey(session.cursorKey("B")) }
                key("←", repeatsOnHold: true) { session.sendExtraKey(session.cursorKey("D")) }
                key("→", repeatsOnHold: true) { session.sendExtraKey(session.cursorKey("C")) }

                key("Home") { send(escape("[H")) }
                key("End") { send(escape("[F")) }
                key("PgUp", repeatsOnHold: true) { send(escape("[5~")) }
                key("PgDn", repeatsOnHold: true) { send(escape("[6~")) }
                key("Del") { send(escape("[3~")) }

                Button {
                    if let text = UIPasteboard.general.string {
                        session.sendExtraKey(Data(text.utf8))
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14))
                        .frame(minWidth: 34, minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 5))
                .accessibilityLabel("Paste")

                // Android's position: after Paste, immediately before F1.
                pin

                Divider().frame(height: 20)

                // F1–F4 use the SS3 form, F5 upwards the CSI form. That split is
                // what xterm sends and what curses applications expect.
                key("F1") { send(escape("OP")) }
                key("F2") { send(escape("OQ")) }
                key("F3") { send(escape("OR")) }
                key("F4") { send(escape("OS")) }
                key("F5") { send(escape("[15~")) }
                key("F6") { send(escape("[17~")) }
                key("F7") { send(escape("[18~")) }
                key("F8") { send(escape("[19~")) }
                key("F9") { send(escape("[20~")) }
                key("F10") { send(escape("[21~")) }
                key("F11") { send(escape("[23~")) }
                key("F12") { send(escape("[24~")) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .background(Color(.tertiarySystemBackground))
    }

    // MARK: - Pieces

    /// A plain key is a `Button`; only the ones that repeat drive their own
    /// gesture.
    ///
    /// This is the split Android makes — `Modifier.clickable` for ordinary keys,
    /// `pointerInput` only when `repeatOnHold` — and it is what lets the bar
    /// scroll. Everything used to go through the press gesture, which claims the
    /// touch the instant a finger lands, so dragging the bar sideways fired keys
    /// instead of scrolling: reported as "Tab too, not just the arrows".
    @ViewBuilder
    private func key(
        _ label: String,
        repeatsOnHold: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if repeatsOnHold {
            RepeatingKey(label: label, action: action)
        } else {
            Button(action: action) {
                KeyFace(label: label)
            }
            .buttonStyle(.plain)
        }
    }

    /// iPhone only. Android dismisses the keyboard with the system Back button
    /// and iPhone has no equivalent — a terminal has nothing to swipe down on
    /// either, since its own surface scrolls the scrollback — so without this the
    /// keyboard could be raised and never lowered. iPad needs none of it: its
    /// software keyboard has a dismiss key of its own.
    ///
    /// **Why not make the tap toggle instead**, which is the obvious idea and was
    /// asked for: a tap on a focused terminal already means four things in
    /// SwiftTerm's `singleTap` — follow a link, deliver a click to a remote
    /// program that has mouse reporting on, clear the selection, or open the
    /// copy/paste menu when it lands near the cursor. Closing the keyboard would
    /// collide with all four, and worst with the second: inside `vim` every click
    /// would drop the keyboard, and getting it back means sending `vim` another
    /// click. There is a branch where the tap does nothing today and a toggle
    /// would fit, but recognising it from outside means reading SwiftTerm's
    /// `selection.active` and `terminal.mouseMode` and re-deriving its
    /// conditions — the kind of coupling that breaks quietly on the next update.
    /// Decided 12/08/2026: a visible key beats a clever gesture here.
    private var hideKeyboard: some View {
        Button {
            session.terminalView.resignFirstResponder()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 14))
                .frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 5))
        .accessibilityLabel(String(localized: .iosHideKeyboard))
    }

    /// Toggles ``isPinned``. Deliberately on the bar and not only in Settings:
    /// the moment you want the keys without the keyboard is while you are
    /// looking at the terminal, and going three screens away to find a switch
    /// is enough friction that nobody would.
    private var pin: some View {
        Button {
            isPinned.toggle()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.footnote)
                .frame(width: 34, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
        .accessibilityLabel(String(localized: .terminalPinKeysCd))
        .accessibilityAddTraits(isPinned ? [.isSelected] : [])
    }

    /// Android's Spellcheck key, in Android's place: after Alt, before ESC.
    ///
    /// It turns the soft keyboard's suggestions on for the length of a long
    /// command and off again afterwards. The terminal is already suggestion-free
    /// by default — SwiftTerm ships `autocorrectionType = .no` — so this is the
    /// switch that was missing, not the behaviour.
    private var wordModeKey: some View {
        Button {
            session.wordMode.toggle()
        } label: {
            Image(systemName: "textformat.abc.dottedunderline")
                .font(.system(size: 14))
                .foregroundStyle(session.wordMode ? Color.white : Color.primary)
                .frame(minWidth: 40, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(
            session.wordMode ? Color.accentColor : Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 5)
        )
        .accessibilityLabel(String(localized: .iosWordMode))
        .accessibilityAddTraits(session.wordMode ? .isSelected : [])
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isOn.wrappedValue ? .bold : .medium, design: .rounded))
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.primary)
                .frame(minWidth: 40, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(
            isOn.wrappedValue ? Color.accentColor : Color(.secondarySystemBackground),
            in: .rect(cornerRadius: 5)
        )
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func send(_ bytes: [UInt8]) {
        session.sendExtraKey(Data(bytes))
    }

    private func escape(_ tail: String) -> [UInt8] {
        [0x1B] + Array(tail.utf8)
    }
}

/// The look of a key, shared by the plain and the repeating kind.
private struct KeyFace: View {

    let label: String
    var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(minWidth: 34, minHeight: 30)
            .background(
                Color(isPressed ? .tertiarySystemBackground : .secondarySystemBackground),
                in: .rect(cornerRadius: 5)
            )
            .contentShape(.rect)
    }
}

/// A key that keeps firing while held — arrows and paging, the way the
/// keyboard's own backspace behaves.
///
/// Holding ← to walk back through a long command is the case this exists for;
/// tapping it thirty times is what people did before. Only these keys need it:
/// repeating Esc or Tab would be a bug, not a feature, and those are plain
/// buttons so the bar can scroll under them.
///
/// The gesture is **simultaneous**, not exclusive. An exclusive one claims the
/// touch the moment the finger lands and the enclosing scroll view never sees
/// it, which is how the whole bar became unscrollable. Sharing it lets the
/// scroll view recognise a pan while this still detects a hold, and a finger
/// that travels cancels the repeat.
///
/// One press still fires on touch-down even if that touch turns into a scroll —
/// Android has the same wart, its `awaitFirstDown(requireUnconsumed = false)`
/// calling `onClick()` before it can know which one it is.
///
/// Android reads the platform's key-repeat timings from `ViewConfiguration`.
/// iOS has no public equivalent, so the two constants below are chosen to match
/// what the system keyboard feels like — long enough that a normal tap never
/// repeats, short enough that holding is quicker than tapping.
private struct RepeatingKey: View {

    let label: String
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    /// Before the first repeat, and between repeats afterwards.
    private static let initialDelay: Duration = .milliseconds(450)
    private static let interval: Duration = .milliseconds(60)

    /// How far a finger may stray before this counts as scrolling the bar.
    private static let slop: CGFloat = 10

    var body: some View {
        KeyFace(label: label, isPressed: isPressed)
            .simultaneousGesture(press)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { action() }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) > Self.slop
                    || abs(value.translation.height) > Self.slop {
                    stop()
                    return
                }
                guard !isPressed else { return }
                isPressed = true
                action()

                repeatTask = Task {
                    try? await Task.sleep(for: Self.initialDelay)
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(for: Self.interval)
                    }
                }
            }
            .onEnded { _ in stop() }
    }

    private func stop() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}
