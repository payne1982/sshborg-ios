// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The toggles the bar reflects and the callbacks it drives, owned by whoever
/// shows the bar.
///
/// A bag of closures rather than the session itself, because the editor renders
/// the very same bar with everything inert — see ``ExtraBarState/preview``.
/// That is what makes the editor's preview the real thing rather than a drawing
/// of it.
struct ExtraBarState {

    var ctrlActive = false
    var altActive = false
    var wordMode = false
    var pinned = false
    var keyboardVisible = false

    var onCtrlToggle: () -> Void = {}
    var onAltToggle: () -> Void = {}
    var onWordModeToggle: () -> Void = {}
    var onPinToggle: () -> Void = {}
    var onKeyboardToggle: () -> Void = {}

    /// Raw bytes to the session. The session applies the sticky Ctrl/Alt.
    var onKey: (Data) -> Void = { _ in }

    /// A CSI final character resolved through the emulator's cursor-key mode.
    var cursorKeys: (Character) -> Data = { _ in Data() }

    /// Nothing toggles and nothing is sent: the editor's preview.
    static let preview = ExtraBarState()
}

/// The row of keys a software keyboard does not have but a terminal needs,
/// drawn from an ``ExtraBar`` description.
///
/// Ported from the Android `ExtraKeyBar`. Rows marked `fit` share the width
/// between their keys; the others keep natural widths and scroll sideways.
///
/// **One key is ours alone: hide keyboard.** Android dismisses the keyboard
/// with the system Back button and iOS has no such thing, so without a control
/// here the keyboard could be raised and never lowered. Android's presets carry
/// no `keyboard` action, so on iPhone this bar puts one in front of the first
/// row when the chosen bar does not already have its own — including a custom
/// bar the user built on Android. iPad needs none of it: its software keyboard
/// has a dismiss key in the corner.
struct ExtraKeyBar: View {

    let bar: ExtraBar
    let state: ExtraBarState

    /// The bars offered by the on-bar switch key, custom first then presets.
    var bars: [ExtraBar] = []
    var onSelectBar: (String) -> Void = { _ in }

    /// Editor preview: keys select instead of sending, and ``selected`` is the
    /// (row, index) drawn highlighted.
    var editing = false
    var selected: KeyPosition?
    var onSelectKey: (KeyPosition) -> Void = { _ in }

    /// Where a key sits: which row, and which position in it.
    struct KeyPosition: Equatable {
        var row: Int
        var index: Int
    }

    /// The switch key swaps the keys for a row of bar names *in place*: same
    /// height, no popup. A `Menu` would be a separate presentation that takes
    /// first responder away, so the software keyboard would close and the
    /// terminal would resize under the user's thumb — which is the whole thing
    /// the bar exists to avoid.
    @State private var isChoosingBar = false

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The keyboard key, ahead of the first row, when this platform needs one
    /// and the bar has not got its own.
    private var needsKeyboardKey: Bool {
        !isPad && !editing && !bar.containsKeyboardAction
    }

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                ForEach(Array(bar.rows.enumerated()), id: \.offset) { index, row in
                    rowView(row, at: index)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .opacity(isChoosingBar ? 0 : 1)
            // Not `if !isChoosingBar`: keeping the rows laid out under the
            // chooser is what holds the bar at exactly one height, so the
            // terminal does not resize when the chooser opens and closes.
            .accessibilityHidden(isChoosingBar)

            if isChoosingBar {
                barChooser
            }
        }
        .background(Color(.tertiarySystemBackground))
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: ExtraBarRow, at rowIndex: Int) -> some View {
        // The keyboard key rides in front of the first row and outside the
        // model, so it is never something the editor can move or delete.
        let leading = rowIndex == 0 && needsKeyboardKey

        if row.fit {
            HStack(spacing: 1) {
                if leading {
                    keyboardKey(fit: true)
                }
                ForEach(Array(row.keys.enumerated()), id: \.offset) { index, key in
                    keyView(key, at: KeyPosition(row: rowIndex, index: index), fit: true)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    if leading {
                        keyboardKey(fit: false)
                    }
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { index, key in
                        keyView(key, at: KeyPosition(row: rowIndex, index: index), fit: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: ExtraKeyDef, at position: KeyPosition, fit: Bool) -> some View {
        let highlighted = editing && selected == position
        // In the editor every key means "select me" instead of what it does.
        let select: (() -> Void)? = editing ? { onSelectKey(position) } : nil

        switch key {
        case .special(let special, _):
            KeyFace(
                label: key.displayLabel,
                fontSize: bar.fontScale.pointSize,
                isArrow: special.isArrow,
                fit: fit,
                isActive: highlighted,
                repeats: special.repeats && !editing,
                action: select ?? { state.onKey(special.bytes(cursorKeys: state.cursorKeys)) }
            )

        case .modifier(let mod):
            let isOn = mod == .ctrl ? state.ctrlActive : state.altActive
            KeyFace(
                label: key.displayLabel,
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted || isOn,
                action: select ?? (mod == .ctrl ? state.onCtrlToggle : state.onAltToggle)
            )
            .accessibilityAddTraits(isOn ? .isSelected : [])

        case .text(let text, _):
            KeyFace(
                label: key.displayLabel,
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted,
                action: select ?? { state.onKey(Data(unescapeKeyText(text).utf8)) }
            )

        case .action(let action):
            actionKey(action, highlighted: highlighted, fit: fit, select: select)
        }
    }

    @ViewBuilder
    private func actionKey(
        _ action: BarAction,
        highlighted: Bool,
        fit: Bool,
        select: (() -> Void)?
    ) -> some View {
        switch action {
        case .paste:
            IconKey(
                systemImage: "doc.on.clipboard",
                label: String(localized: .terminalPasteCd),
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted,
                action: select ?? {
                    if let text = UIPasteboard.general.string {
                        state.onKey(Data(text.utf8))
                    }
                }
            )

        case .pin:
            IconKey(
                systemImage: state.pinned ? "pin.fill" : "pin",
                label: String(localized: .terminalPinKeysCd),
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted || state.pinned,
                action: select ?? state.onPinToggle
            )
            .accessibilityAddTraits(state.pinned ? .isSelected : [])

        case .wordMode:
            IconKey(
                systemImage: "textformat.abc.dottedunderline",
                label: String(localized: .iosWordMode),
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted || state.wordMode,
                action: select ?? state.onWordModeToggle
            )
            .accessibilityAddTraits(state.wordMode ? .isSelected : [])

        case .keyboard:
            IconKey(
                systemImage: state.keyboardVisible
                    ? "keyboard.chevron.compact.down"
                    : "keyboard",
                label: String(localized: .terminalKeyboardCd),
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted,
                action: select ?? state.onKeyboardToggle
            )

        case .switchBar:
            IconKey(
                systemImage: "arrow.left.arrow.right",
                label: String(localized: .terminalSwitchBarCd),
                fontSize: bar.fontScale.pointSize,
                fit: fit,
                isActive: highlighted,
                action: select ?? { isChoosingBar = true }
            )
        }
    }

    /// The iPhone-only dismiss key. Always the "down" glyph: it is only ever
    /// shown to close a keyboard that is up, unlike the `keyboard` action key,
    /// which does both jobs and says which one it is about to do.
    private func keyboardKey(fit: Bool) -> some View {
        IconKey(
            systemImage: "keyboard.chevron.compact.down",
            label: String(localized: .iosHideKeyboard),
            fontSize: bar.fontScale.pointSize,
            fit: fit,
            isActive: false,
            action: state.onKeyboardToggle
        )
    }

    // MARK: - Switching bars

    private var barChooser: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                IconKey(
                    systemImage: "xmark",
                    label: String(localized: .actionCancel),
                    fontSize: bar.fontScale.pointSize,
                    fit: false,
                    isActive: false,
                    action: { isChoosingBar = false }
                )

                ForEach(bars) { candidate in
                    KeyFace(
                        label: candidate.localizedName,
                        fontSize: bar.fontScale.pointSize,
                        fit: false,
                        isActive: candidate.id == bar.id,
                        action: {
                            onSelectBar(candidate.id)
                            isChoosingBar = false
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .background(Color(.tertiarySystemBackground))
    }
}

// MARK: - Keys

/// Why every key here carries `.contentShape(.rect)`.
///
/// A `Text` or an `Image` inside a larger `.frame()` stays tappable only where
/// it actually draws: the transparent padding around it receives nothing. So a
/// key looks 34 points wide and answers on the few points its glyph covers.
///
/// Found by him on 04/09/2026, after a long evening of my looking elsewhere:
/// "the pin is only clicked when you click exactly inside the drawing pin,
/// which is about a tenth of my finger". The device had been saying so all
/// along — ten presses of the pin, none recorded — and I had read that as a
/// gesture being stolen by the enclosing scroll view.
private struct KeyFace: View {

    let label: String
    let fontSize: CGFloat
    var isArrow = false

    /// Whether the key shares the row's width with its neighbours. A stretched
    /// key takes its room from the layout, so it gets no minimum of its own —
    /// nine columns will not fit a narrow phone otherwise.
    var fit = false

    var isActive = false
    var repeats = false
    let action: () -> Void

    var body: some View {
        RepeatingKey(repeats: repeats, action: action) { isPressed in
            Text(label)
                .font(.system(size: fontSize, weight: isActive || isArrow ? .bold : .medium, design: isArrow ? .monospaced : .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .padding(.horizontal, fit ? 2 : 8)
                .frame(minWidth: fit ? 0 : 34, minHeight: 30)
                .frame(maxWidth: fit ? .infinity : nil)
                .background(
                    background(isPressed: isPressed),
                    in: .rect(cornerRadius: 5)
                )
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
    }

    private func background(isPressed: Bool) -> Color {
        if isActive { return .accentColor }
        return Color(isPressed ? .tertiarySystemBackground : .secondarySystemBackground)
    }
}

/// An action key: an icon rather than a label, with the same face and the same
/// hit area as every other key.
private struct IconKey: View {

    let systemImage: String
    let label: String
    let fontSize: CGFloat
    var fit = false
    var isActive = false
    let action: () -> Void

    var body: some View {
        RepeatingKey(repeats: false, action: action) { isPressed in
            Image(systemName: systemImage)
                .font(.system(size: fontSize + 2))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .padding(.horizontal, fit ? 2 : 8)
                .frame(minWidth: fit ? 0 : 34, minHeight: 30)
                .frame(maxWidth: fit ? .infinity : nil)
                .background(
                    isActive
                        ? Color.accentColor
                        : Color(isPressed ? .tertiarySystemBackground : .secondarySystemBackground),
                    in: .rect(cornerRadius: 5)
                )
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

/// The press behaviour every key on this bar shares: a `Button`.
///
/// A button fires on release, and gives the touch up to the scroll view as soon
/// as the finger travels — so tapping a key types it, and dragging across the
/// keys scrolls the row without typing anything. That is Android's split too:
/// its ordinary keys are `clickable`, which behaves the same way.
///
/// **This has swung twice, so the history is worth keeping.** From 05/09 to
/// 14/09/2026 every key was a simultaneous `DragGesture(minimumDistance: 0)`
/// that fired the moment a finger landed. On the phone that meant: "the key is
/// executed at once and blocks scrolling; the bar only scrolls if I land
/// between two keys". The belief behind the gesture — that a button "loses the
/// touch" — came from the pin key, whose hit area turned out to be only its
/// glyph; `.contentShape(.rect)` on every face fixed that (see ``KeyFace``), and
/// the gesture stayed on for a reason that no longer existed.
///
/// Holding a repeating key still repeats. The button style reports the press;
/// once it has lasted `initialDelay` with the finger still on the key — a drag
/// ends the press, so a scroll never repeats — the action fires every
/// `interval`, and the release adds nothing more.
///
/// Android reads the platform's key-repeat timings from `ViewConfiguration`.
/// iOS has no public equivalent, so the constants in ``KeyRepeater`` are chosen
/// to match what the system keyboard feels like.
private struct RepeatingKey<Face: View>: View {

    /// Whether holding keeps firing. Off for keys where repeating would be a
    /// bug rather than a feature — Esc, Tab, the function keys.
    let repeats: Bool
    let action: () -> Void

    @ViewBuilder var face: (Bool) -> Face

    @State private var repeater = KeyRepeater()

    /// Holds the pressed face a moment after a quick tap. Without it the
    /// highlight lasts a few milliseconds and a key that worked is
    /// indistinguishable from one that did not — Esc and ← at an empty prompt
    /// have no visible effect of their own.
    @State private var isFlashing = false

    var body: some View {
        Button {
            guard !repeater.didRepeat else { return }
            action()
            flash()
        } label: {
            EmptyView()
        }
        .buttonStyle(KeyPressStyle(
            repeats: repeats,
            action: action,
            repeater: repeater,
            isFlashing: isFlashing,
            face: face
        ))
        // A held key can be taken off the screen mid-press: the keyboard key
        // dismisses the keyboard and the whole bar goes with it, and so does
        // choosing another bar, or the session dropping. The repeat task is not
        // owned by the view and would carry on sending arrow bytes to a session
        // nobody is touching. Android had the same defect (4f34a7a), reported as
        // the cursor moving on its own after the finger was gone.
        .onDisappear { repeater.stop() }
    }

    private func flash() {
        isFlashing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isFlashing = false
        }
    }
}

/// Draws a key from its press state, and tells the repeater when a press starts
/// and ends. The label the button carries is ignored: the face is the label.
private struct KeyPressStyle<Face: View>: ButtonStyle {

    let repeats: Bool
    let action: () -> Void
    let repeater: KeyRepeater
    let isFlashing: Bool
    let face: (Bool) -> Face

    func makeBody(configuration: Configuration) -> some View {
        face(configuration.isPressed || isFlashing)
            .onValueChange(of: configuration.isPressed) { pressed in
                repeater.pressChanged(pressed, repeats: repeats, action: action)
            }
    }
}

/// The hold-to-repeat timer of one key.
///
/// A reference type held in `@State`, so the timer survives the redraws the
/// press itself causes, and so the release — which reaches the button's action
/// and the style's press change in no guaranteed order — can read whether the
/// hold already typed.
///
/// Not `@MainActor` as a type, because a `@State` default value is evaluated
/// outside the actor; it is only ever touched from the main thread, and the
/// repeat task is pinned there.
final class KeyRepeater {

    /// Before the first repeat: long enough that a normal tap never repeats.
    static let initialDelay: Duration = .milliseconds(450)
    /// Between repeats: quicker than tapping.
    static let interval: Duration = .milliseconds(60)

    /// Whether the current press has fired by repeating, in which case its
    /// release must not fire once more.
    private(set) var didRepeat = false

    private var task: Task<Void, Never>?

    func pressChanged(_ pressed: Bool, repeats: Bool, action: @escaping () -> Void) {
        guard pressed else {
            stop()
            return
        }
        didRepeat = false
        guard repeats else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.initialDelay)
            while !Task.isCancelled {
                self?.didRepeat = true
                action()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

#Preview {
    VStack(spacing: 12) {
        ExtraKeyBar(bar: ExtraBarPresets.standard, state: .preview)
        ExtraKeyBar(bar: ExtraBarPresets.natural2, state: .preview)
        ExtraKeyBar(bar: ExtraBarPresets.minimal, state: .preview)
    }
}
