// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                toggle("Ctrl", isOn: $session.ctrlActive)
                toggle("Alt", isOn: $session.altActive)

                Divider().frame(height: 20)

                key("ESC") { send([0x1B]) }
                key("Tab") { send([0x09]) }

                key("↑") { session.sendExtraKey(session.cursorKey("A")) }
                key("↓") { session.sendExtraKey(session.cursorKey("B")) }
                key("←") { session.sendExtraKey(session.cursorKey("D")) }
                key("→") { session.sendExtraKey(session.cursorKey("C")) }

                key("Home") { send(escape("[H")) }
                key("End") { send(escape("[F")) }
                key("PgUp") { send(escape("[5~")) }
                key("PgDn") { send(escape("[6~")) }
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

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 5))
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
