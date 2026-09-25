// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Perception

/// The hex editor, for the files that are not text.
///
/// Ported from Android, including the one decision that matters: overwrite only.
/// Sixteen bytes to a row, offset on the left, printable characters on the
/// right, and a keypad of sixteen digits — a soft keyboard cannot offer hex
/// digits, and typing `2F` into a text field would mean parsing whatever a
/// keyboard chose to send.
///
/// A tap picks a byte, in either column; the first digit sets the high nibble
/// and moves nothing, the second sets the low nibble and moves on, which is how
/// every hex editor behaves.
struct HexEditorScreen: View {

    let model: EditorModel
    @State private var buffer: HexBuffer
    @State private var selected = 0
    @State private var pendingHighNibble: UInt8?

    init(model: EditorModel, bytes: Data) {
        self.model = model
        _buffer = State(initialValue: HexBuffer(bytes))
    }

    private let perRow = 16

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                dump
                Divider()
                keypad
            }
            .navigationTitle(Text(.editorHex))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        buffer.undo().map { selected = $0 }
                        pendingHighNibble = nil
                    } label: {
                        Label(String(localized: .actionUndo), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!buffer.isDirty)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Button {
                            Task {
                                await model.save(bytes: buffer.data)
                                if model.didSave { buffer.markSaved() }
                            }
                        } label: {
                            Label(String(localized: .actionSave), systemImage: "checkmark")
                        }
                        .disabled(!buffer.isDirty)
                    }
                }
            }
        }
    }

    // MARK: - The dump

    private var dump: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HexRow(
                            buffer: buffer,
                            row: row,
                            perRow: perRow,
                            selected: selected,
                            onPick: { index in
                                selected = index
                                pendingHighNibble = nil
                            }
                        )
                        .id(row)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onValueChange(of: selected) { index in
                // Keep the byte being edited on screen when the arrows walk off
                // the end of a row.
                proxy.scrollTo(index / perRow, anchor: .center)
            }
        }
    }

    private var rowCount: Int {
        buffer.count == 0 ? 0 : (buffer.count + perRow - 1) / perRow
    }

    // MARK: - The keypad

    private var keypad: some View {
        VStack(spacing: 4) {
            ForEach([Array(0..<8), Array(8..<16)], id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { digit in
                        Button(String(format: "%X", digit)) { type(UInt8(digit)) }
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 6))
                    }
                }
            }

            HStack(spacing: 4) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").frame(maxWidth: .infinity, minHeight: 32)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 6))

                Text(String(format: "%08X", selected))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Button { step(1) } label: {
                    Image(systemName: "chevron.right").frame(maxWidth: .infinity, minHeight: 32)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(.bar)
    }

    /// The first digit sets the high nibble and stays put; the second sets the
    /// low one and moves on.
    private func type(_ digit: UInt8) {
        guard buffer.bytes.indices.contains(selected) else { return }

        if let high = pendingHighNibble {
            buffer.set((high << 4) | digit, at: selected)
            pendingHighNibble = nil
            step(1)
        } else {
            let low = buffer[selected] & 0x0F
            buffer.set((digit << 4) | low, at: selected)
            pendingHighNibble = digit
        }
    }

    private func step(_ delta: Int) {
        let next = selected + delta
        guard buffer.bytes.indices.contains(next) else { return }
        selected = next
        pendingHighNibble = nil
    }
}

/// One line of the dump: offset, sixteen bytes, and the printable characters.
///
/// Drawn as one monospaced string rather than 33 views, which is what keeps a
/// four-megabyte file scrolling: the row is a single text run, and the selection
/// is an attribute inside it.
private struct HexRow: View {

    let buffer: HexBuffer
    let row: Int
    let perRow: Int
    let selected: Int
    let onPick: (Int) -> Void

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                Text(String(format: "%08X", start))
                    .foregroundStyle(.secondary)

                Text(verbatim: "  ")

                ForEach(0..<perRow, id: \.self) { column in
                    let index = start + column
                    if index < buffer.count {
                        Text(String(format: "%02X ", buffer[index]))
                            .background(index == selected ? Color.accentColor.opacity(0.35) : .clear)
                            .onTapGesture { onPick(index) }
                    } else {
                        Text(verbatim: "   ")
                    }
                }

                Text(verbatim: " ")

                ForEach(0..<perRow, id: \.self) { column in
                    let index = start + column
                    if index < buffer.count {
                        Text(verbatim: printable(buffer[index]))
                            .background(index == selected ? Color.accentColor.opacity(0.35) : .clear)
                            .onTapGesture { onPick(index) }
                    }
                }
            }
            .font(.caption.monospaced())
            .lineLimit(1)
        }
    }

    private var start: Int { row * perRow }

    private func printable(_ byte: UInt8) -> String {
        (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
    }
}
