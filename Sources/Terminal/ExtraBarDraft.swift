// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A bar being edited, plus which key is selected.
///
/// A value type with no view in it, so every move, insert and delete is
/// testable on its own. That is deliberate: this is index arithmetic over a
/// ragged array of rows, which is exactly the kind of code that is off by one
/// in one direction only and looks right on screen until the day it does not.
///
/// The editor keeps one of these and writes nothing until Save, so backing out
/// of the screen leaves the stored bars untouched.
struct ExtraBarDraft: Equatable {

    var bar: ExtraBar

    /// The selected key, or `nil` when nothing is selected. Every edit below
    /// keeps this pointing at the key it acted on, so a run of moves works on
    /// the same key without re-selecting it.
    var selection: ExtraKeyBar.KeyPosition?

    /// Whether anything has been changed since the draft was made. What the
    /// back gesture asks about.
    private(set) var isDirty = false

    init(bar: ExtraBar) {
        self.bar = bar
    }

    /// A bar can be saved once it has a name and at least one key. An empty
    /// bar is not a mistake worth an alert — it is just not finished.
    var canSave: Bool {
        !bar.name.trimmed.isEmpty && bar.rows.contains { !$0.keys.isEmpty }
    }

    /// The key the selection points at, if it still exists. Removing a row can
    /// leave a selection pointing past the end, so every reader goes through
    /// here rather than subscripting.
    var selectedKey: ExtraKeyDef? {
        guard let selection,
              let row = bar.rows[safe: selection.row],
              let key = row.keys[safe: selection.index]
        else { return nil }
        return key
    }

    var hasSelection: Bool { selectedKey != nil }

    // MARK: - What the toolbar may do

    // Each of these answers "would that move change anything", which is what
    // decides whether its button is enabled. They are here rather than in the
    // editor so the button and the operation cannot drift apart: a button that
    // is lit for a move the draft then refuses is the same defect as a setting
    // that promises nothing.

    var canMoveLeft: Bool {
        guard let selection, hasSelection else { return false }
        return selection.index > 0
    }

    var canMoveRight: Bool {
        guard let selection, hasSelection, let row = bar.rows[safe: selection.row] else { return false }
        return selection.index < row.keys.count - 1
    }

    var canMoveToRowAbove: Bool {
        guard let selection, hasSelection else { return false }
        return selection.row > 0
    }

    var canMoveToRowBelow: Bool {
        guard let selection, hasSelection else { return false }
        return selection.row < bar.rows.count - 1
    }

    // MARK: - Bar options

    mutating func setName(_ name: String) {
        guard name != bar.name else { return }
        bar.name = name
        isDirty = true
    }

    mutating func setFontScale(_ scale: BarFontScale) {
        guard scale != bar.fontScale else { return }
        bar.fontScale = scale
        isDirty = true
    }

    mutating func setRowFit(_ fit: Bool, row: Int) {
        guard bar.rows.indices.contains(row), bar.rows[row].fit != fit else { return }
        bar.rows[row].fit = fit
        isDirty = true
    }

    // MARK: - Selection

    /// Tapping the selected key again clears the selection, which is how the
    /// toolbar goes back to inserting at the end.
    mutating func select(_ position: ExtraKeyBar.KeyPosition?) {
        selection = (position == selection) ? nil : position
    }

    // MARK: - Rows

    mutating func addRow() {
        guard bar.rows.count < ExtraBar.maxRows else { return }
        bar.rows.append(ExtraBarRow(keys: [], fit: true))
        isDirty = true
    }

    /// Removing the last row is refused: a bar with no rows has nowhere to put
    /// a key, and the editor would have nothing to draw.
    mutating func removeRow(_ row: Int) {
        guard bar.rows.count > 1, bar.rows.indices.contains(row) else { return }
        bar.rows.remove(at: row)
        selection = nil
        isDirty = true
    }

    // MARK: - Keys

    /// Inserts after the selection, or at the end of the last row when nothing
    /// is selected. The new key becomes the selection, so several keys added in
    /// a row come out in the order they were picked.
    mutating func insert(_ key: ExtraKeyDef) {
        let row: Int
        let index: Int

        if let selection, bar.rows.indices.contains(selection.row) {
            row = selection.row
            index = min(selection.index + 1, bar.rows[selection.row].keys.count)
        } else {
            row = bar.rows.indices.last ?? 0
            guard bar.rows.indices.contains(row) else { return }
            index = bar.rows[row].keys.count
        }

        bar.rows[row].keys.insert(key, at: index)
        selection = .init(row: row, index: index)
        isDirty = true
    }

    mutating func replaceSelection(with key: ExtraKeyDef) {
        guard let selection, hasSelection else { return }
        bar.rows[selection.row].keys[selection.index] = key
        isDirty = true
    }

    /// Removes the selected key and keeps the selection where the finger is:
    /// on the key that slid into the gap, or on the new last key when the
    /// removed one was at the end. An emptied row clears the selection.
    mutating func removeSelection() {
        guard let selection, hasSelection else { return }
        bar.rows[selection.row].keys.remove(at: selection.index)

        let remaining = bar.rows[selection.row].keys
        self.selection = remaining.isEmpty
            ? nil
            : .init(row: selection.row, index: min(selection.index, remaining.count - 1))
        isDirty = true
    }

    /// Moves the selected key within its row by `offset` places.
    mutating func moveSelection(by offset: Int) {
        guard let selection, hasSelection else { return }
        let target = selection.index + offset
        guard bar.rows[selection.row].keys.indices.contains(target) else { return }

        bar.rows[selection.row].keys.swapAt(selection.index, target)
        self.selection = .init(row: selection.row, index: target)
        isDirty = true
    }

    /// Moves the selected key to the row above or below, at the same position
    /// or at the end of that row when it is shorter.
    mutating func moveSelectionToRow(by offset: Int) {
        guard let selection, hasSelection else { return }
        let target = selection.row + offset
        guard bar.rows.indices.contains(target) else { return }

        let key = bar.rows[selection.row].keys.remove(at: selection.index)
        let index = min(selection.index, bar.rows[target].keys.count)
        bar.rows[target].keys.insert(key, at: index)
        self.selection = .init(row: target, index: index)
        isDirty = true
    }
}

extension Array {

    /// Subscripting that returns `nil` instead of trapping. Used where an index
    /// can legitimately be stale — a selection that outlived the row it pointed
    /// into.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
