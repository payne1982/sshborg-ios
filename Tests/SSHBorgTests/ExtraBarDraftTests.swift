// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The editor's arithmetic, with no editor.
///
/// Every one of these is an index that can be off by one in a direction the
/// screen makes look plausible: a key moved to the end of the wrong row, a
/// selection left pointing at a key that has gone. The draft is a value type
/// precisely so this can be checked without a view.
final class ExtraBarDraftTests: XCTestCase {

    private func draft(
        _ rows: [[ExtraKeyDef]],
        fit: Bool = false,
        name: String = "Mine"
    ) -> ExtraBarDraft {
        ExtraBarDraft(bar: ExtraBar(
            id: "custom:test",
            name: name,
            rows: rows.map { ExtraBarRow(keys: $0, fit: fit) }
        ))
    }

    private func labels(_ draft: ExtraBarDraft) -> [[String]] {
        draft.bar.rows.map { $0.keys.map(\.displayLabel) }
    }

    // MARK: - Selection

    func testANewDraftIsCleanAndHasNothingSelected() {
        let draft = draft([[.special(.esc)]])
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.selection)
        XCTAssertFalse(draft.hasSelection)
    }

    func testTappingTheSelectedKeyAgainClearsTheSelection() {
        var draft = draft([[.special(.esc), .special(.tab)]])
        draft.select(.init(row: 0, index: 1))
        XCTAssertEqual(draft.selection, .init(row: 0, index: 1))

        draft.select(.init(row: 0, index: 1))
        XCTAssertNil(draft.selection)
    }

    /// Selecting is not an edit. If it were, opening a bar and looking at a key
    /// would make the editor ask about unsaved changes on the way out.
    func testSelectingDoesNotMakeTheDraftDirty() {
        var draft = draft([[.special(.esc)]])
        draft.select(.init(row: 0, index: 0))
        XCTAssertFalse(draft.isDirty)
    }

    /// A selection can outlive the key it pointed at. Everything that reads it
    /// goes through `selectedKey`, so a stale index answers "nothing" rather
    /// than trapping.
    func testAStaleSelectionReadsAsNoSelection() {
        var draft = draft([[.special(.esc)], [.special(.tab)]])
        draft.select(.init(row: 1, index: 0))
        draft.removeRow(1)

        XCTAssertNil(draft.selectedKey)
        XCTAssertFalse(draft.hasSelection)
    }

    // MARK: - Inserting

    func testAKeyIsInsertedAfterTheSelectionAndBecomesIt() {
        var draft = draft([[.special(.esc), .special(.tab)]])
        draft.select(.init(row: 0, index: 0))
        draft.insert(.modifier(.ctrl))

        XCTAssertEqual(labels(draft), [["ESC", "Ctrl", "Tab"]])
        XCTAssertEqual(draft.selection, .init(row: 0, index: 1))
        XCTAssertTrue(draft.isDirty)
    }

    /// Because each insert selects what it just added, picking three keys in a
    /// row leaves them in the order they were picked rather than reversed.
    func testSeveralInsertsKeepTheOrderTheyWerePickedIn() {
        var draft = draft([[.special(.esc)]])
        draft.select(.init(row: 0, index: 0))
        draft.insert(.text("a"))
        draft.insert(.text("b"))
        draft.insert(.text("c"))

        XCTAssertEqual(labels(draft), [["ESC", "a", "b", "c"]])
    }

    func testWithNothingSelectedAKeyGoesToTheEndOfTheLastRow() {
        var draft = draft([[.special(.esc)], [.special(.tab)]])
        draft.insert(.modifier(.alt))

        XCTAssertEqual(labels(draft), [["ESC"], ["Tab", "Alt"]])
        XCTAssertEqual(draft.selection, .init(row: 1, index: 1))
    }

    func testAKeyCanBeAddedToAnEmptyRow() {
        var draft = draft([[]])
        draft.insert(.special(.esc))

        XCTAssertEqual(labels(draft), [["ESC"]])
        XCTAssertEqual(draft.selection, .init(row: 0, index: 0))
    }

    // MARK: - Replacing and removing

    func testReplacingChangesOnlyTheSelectedKey() {
        var draft = draft([[.special(.esc), .special(.tab)]])
        draft.select(.init(row: 0, index: 1))
        draft.replaceSelection(with: .action(.paste))

        XCTAssertEqual(draft.bar.rows[0].keys, [.special(.esc), .action(.paste)])
    }

    func testReplacingWithNothingSelectedChangesNothing() {
        var draft = draft([[.special(.esc)]])
        draft.replaceSelection(with: .action(.paste))

        XCTAssertEqual(labels(draft), [["ESC"]])
        XCTAssertFalse(draft.isDirty)
    }

    /// The selection stays where the finger is, on the key that slid into the
    /// gap — so deleting four keys in a row is four taps in the same place.
    func testRemovingKeepsTheSelectionUnderTheFinger() {
        var draft = draft([[.text("a"), .text("b"), .text("c")]])
        draft.select(.init(row: 0, index: 1))
        draft.removeSelection()

        XCTAssertEqual(labels(draft), [["a", "c"]])
        XCTAssertEqual(draft.selection, .init(row: 0, index: 1))
        XCTAssertEqual(draft.selectedKey, .text("c"))
    }

    func testRemovingTheLastKeyInARowSelectsTheNewLastOne() {
        var draft = draft([[.text("a"), .text("b")]])
        draft.select(.init(row: 0, index: 1))
        draft.removeSelection()

        XCTAssertEqual(draft.selection, .init(row: 0, index: 0))
        XCTAssertEqual(draft.selectedKey, .text("a"))
    }

    func testEmptyingARowClearsTheSelection() {
        var draft = draft([[.text("a")]])
        draft.select(.init(row: 0, index: 0))
        draft.removeSelection()

        XCTAssertNil(draft.selection)
        XCTAssertTrue(draft.bar.rows[0].keys.isEmpty)
    }

    // MARK: - Moving within a row

    func testMovingSwapsWithTheNeighbourAndFollowsTheKey() {
        var draft = draft([[.text("a"), .text("b"), .text("c")]])
        draft.select(.init(row: 0, index: 2))
        draft.moveSelection(by: -1)

        XCTAssertEqual(labels(draft), [["a", "c", "b"]])
        XCTAssertEqual(draft.selectedKey, .text("c"))
    }

    func testMovingPastTheEndOfARowDoesNothing() {
        var draft = draft([[.text("a"), .text("b")]])
        draft.select(.init(row: 0, index: 1))
        draft.moveSelection(by: 1)

        XCTAssertEqual(labels(draft), [["a", "b"]])
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - Moving between rows

    func testAKeyMovesToTheSamePositionInTheRowBelow() {
        var draft = draft([[.text("a"), .text("b"), .text("c")], [.text("x"), .text("y"), .text("z")]])
        draft.select(.init(row: 0, index: 1))
        draft.moveSelectionToRow(by: 1)

        XCTAssertEqual(labels(draft), [["a", "c"], ["x", "b", "y", "z"]])
        XCTAssertEqual(draft.selection, .init(row: 1, index: 1))
        XCTAssertEqual(draft.selectedKey, .text("b"))
    }

    /// The target row can be shorter than the position the key came from, in
    /// which case it lands at the end rather than out of bounds. This is the
    /// crash the whole type exists to prevent.
    func testAKeyMovedToAShorterRowLandsAtItsEnd() {
        var draft = draft([[.text("a"), .text("b"), .text("c"), .text("d")], [.text("x")]])
        draft.select(.init(row: 0, index: 3))
        draft.moveSelectionToRow(by: 1)

        XCTAssertEqual(labels(draft), [["a", "b", "c"], ["x", "d"]])
        XCTAssertEqual(draft.selection, .init(row: 1, index: 1))
    }

    func testAKeyMovedToAnEmptyRowIsItsOnlyKey() {
        var draft = draft([[.text("a")], []])
        draft.select(.init(row: 0, index: 0))
        draft.moveSelectionToRow(by: 1)

        XCTAssertEqual(labels(draft), [[], ["a"]])
        XCTAssertEqual(draft.selection, .init(row: 1, index: 0))
    }

    func testMovingOffTheTopOrBottomDoesNothing() {
        var draft = draft([[.text("a")], [.text("b")]])
        draft.select(.init(row: 0, index: 0))
        draft.moveSelectionToRow(by: -1)
        XCTAssertEqual(labels(draft), [["a"], ["b"]])

        draft.select(.init(row: 1, index: 0))
        draft.moveSelectionToRow(by: 1)
        XCTAssertEqual(labels(draft), [["a"], ["b"]])
        XCTAssertFalse(draft.isDirty)
    }

    // MARK: - The toolbar's buttons

    /// Each button is lit by the same predicate the operation guards on, so a
    /// button can never be enabled for a move the draft would then refuse.
    func testAButtonIsLitExactlyWhenItsMoveWouldChangeSomething() {
        var draft = draft([[.text("a"), .text("b")], [.text("x")]])

        // Nothing selected: only "add" is available, and it has no predicate.
        XCTAssertFalse(draft.canMoveLeft)
        XCTAssertFalse(draft.canMoveRight)
        XCTAssertFalse(draft.canMoveToRowAbove)
        XCTAssertFalse(draft.canMoveToRowBelow)
        XCTAssertFalse(draft.hasSelection)

        draft.select(.init(row: 0, index: 0))
        XCTAssertFalse(draft.canMoveLeft)
        XCTAssertTrue(draft.canMoveRight)
        XCTAssertFalse(draft.canMoveToRowAbove)
        XCTAssertTrue(draft.canMoveToRowBelow)

        draft.select(.init(row: 1, index: 0))
        XCTAssertFalse(draft.canMoveLeft)
        XCTAssertFalse(draft.canMoveRight)
        XCTAssertTrue(draft.canMoveToRowAbove)
        XCTAssertFalse(draft.canMoveToRowBelow)
    }

    // MARK: - Rows

    func testRowsStopAtThree() {
        var draft = draft([[.text("a")]])
        draft.addRow()
        draft.addRow()
        XCTAssertEqual(draft.bar.rows.count, 3)

        draft.addRow()
        XCTAssertEqual(draft.bar.rows.count, ExtraBar.maxRows)
    }

    func testTheLastRowCannotBeRemoved() {
        var draft = draft([[.text("a")]])
        draft.removeRow(0)

        XCTAssertEqual(draft.bar.rows.count, 1)
        XCTAssertFalse(draft.isDirty)
    }

    func testRemovingARowTakesItsKeysAndClearsTheSelection() {
        var draft = draft([[.text("a")], [.text("b")]])
        draft.select(.init(row: 0, index: 0))
        draft.removeRow(0)

        XCTAssertEqual(labels(draft), [["b"]])
        XCTAssertNil(draft.selection)
    }

    // MARK: - Saving

    func testABarNeedsANameAndAKeyBeforeItCanBeSaved() {
        XCTAssertFalse(draft([[]], name: "Mine").canSave)
        XCTAssertFalse(draft([[.text("a")]], name: "   ").canSave)
        XCTAssertTrue(draft([[.text("a")]], name: "Mine").canSave)
    }

    /// A bar with an empty row and a full one is saveable: an empty row is a
    /// row waiting for keys, not a mistake.
    func testAnEmptyRowBesideAFullOneIsStillSaveable() {
        XCTAssertTrue(draft([[.text("a")], []]).canSave)
    }
}
