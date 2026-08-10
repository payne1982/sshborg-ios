// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The row of keys a software keyboard does not have but a terminal needs.
///
/// Same key set and order as the Android `ExtraKeyRow`, so muscle memory carries
/// across platforms: modifiers, then navigation, then paste, then function keys.
///
/// Android's "word mode" toggle is deliberately absent — it switches the Android
/// soft keyboard out of its suggestion mode, and iOS has no equivalent knob that
/// an app can reach.
struct ExtraKeyRow: View {

    @Bindable var session: TerminalSession

    /// Whether the row stays on screen with the keyboard closed. Bound to the
    /// preference so the pin on the bar and the switch in Settings are the same
    /// control seen from two places, which is how the Android build has it.
    @Binding var isPinned: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Leading, so it keeps its place while the rest scrolls past.
                pin

                Divider().frame(height: 20)

                toggle("Ctrl", isOn: $session.ctrlActive)
                toggle("Alt", isOn: $session.altActive)

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

    private func key(
        _ label: String,
        repeatsOnHold: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        RepeatingKey(label: label, repeatsOnHold: repeatsOnHold, action: action)
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

/// One key of the extra row.
///
/// Arrows and paging repeat while held, the way the keyboard's own backspace
/// does — holding ← to walk back through a long command is the case this exists
/// for, and tapping it thirty times is what people did before. Every other key
/// fires once: repeating Esc or Tab would be a bug, not a feature.
///
/// Android reads the platform's key-repeat timings from `ViewConfiguration`.
/// iOS has no public equivalent, so the two constants below are chosen to match
/// what the system keyboard feels like — long enough that a normal tap never
/// repeats, short enough that holding is quicker than tapping.
private struct RepeatingKey: View {

    let label: String
    let repeatsOnHold: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    /// Before the first repeat, and between repeats afterwards.
    private static let initialDelay: Duration = .milliseconds(450)
    private static let interval: Duration = .milliseconds(60)

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
            .gesture(press)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { action() }
    }

    /// A minimum distance of zero makes this fire on touch-down rather than on
    /// release, which is what a key should do and what makes the hold detectable
    /// at all.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                action()
                guard repeatsOnHold else { return }

                repeatTask = Task {
                    try? await Task.sleep(for: Self.initialDelay)
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(for: Self.interval)
                    }
                }
            }
            .onEnded { _ in
                isPressed = false
                repeatTask?.cancel()
                repeatTask = nil
            }
    }
}
