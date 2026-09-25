// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// The bytes the hex editor is working on, changed in place.
///
/// Only values change, never the length: this is overwrite mode, the default of
/// every hex editor there is. It covers what people actually do to a binary —
/// flip a flag, fix a number, correct a string — and it keeps every offset in
/// the file where it was, which is what makes the change safe to write back.
/// Inserting would move everything after it, and in most binary formats that
/// breaks the file whatever we do.
///
/// Ported from the Android `HexBuffer`, minus its revision counter: SwiftUI
/// observes the array itself.
@MainActor
@Perceptible
final class HexBuffer {

    private(set) var bytes: [UInt8]

    /// Offset and the value that was there, newest last.
    @PerceptionIgnored private var history: [(index: Int, previous: UInt8)] = []

    init(_ original: Data) {
        bytes = Array(original)
    }

    var count: Int { bytes.count }

    var isDirty: Bool { !history.isEmpty }

    var data: Data { Data(bytes) }

    subscript(index: Int) -> UInt8 {
        bytes[index]
    }

    func set(_ value: UInt8, at index: Int) {
        guard bytes.indices.contains(index), bytes[index] != value else { return }
        history.append((index, bytes[index]))
        bytes[index] = value
    }

    /// Undoes the last change and returns the offset it was at, or `nil` when
    /// there is none.
    @discardableResult
    func undo() -> Int? {
        guard let last = history.popLast() else { return nil }
        bytes[last.index] = last.previous
        return last.index
    }

    /// Called once a save has landed: what is on the server now is what is here.
    func markSaved() {
        history.removeAll()
    }
}
