// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftTerm
import XCTest

@testable import SSHBorg

/// Phase 5's gate: two emulators, the same bytes, compared cell by cell.
///
/// "Repaints with no dirt" cannot be asserted by the code that produced the
/// repaint. So the bytes a real program wrote to a pty are recorded once, and
/// the test replays **the identical bytes** into SwiftTerm and compares the
/// result with how tmux 3.5a drew them in a pane of the same size. Two
/// emulators disagreeing about the same bytes is a defect in one of them; two
/// agreeing is the only evidence worth having.
///
/// tmux is one mature emulator and not the truth: agreement means we are not
/// alone in a misreading, not that neither of us has one. And a text comparison
/// **cannot see an attribute** — a cell in the wrong colour holds the right
/// character and the diff shrugs — which is why `colours` is also asserted
/// directly.
///
/// Nothing here touches mosh, and that is the point: what the gate is really
/// about is whether the emulator we did not write agrees about the sequences
/// mosh leans on. It runs offline, in milliseconds, from the fixtures in
/// `Tests/Fixtures/oracle` — see the README there for how they were recorded.
final class MoshOracleTests: XCTestCase {

    private static let columns = 100
    private static let rows = 30

    /// The checkpoints, and what each one is for.
    ///
    /// `wide-margin` puts 日本語 against the right margin at four offsets, where
    /// our character widths and the shell's `wcwidth` have to agree and where
    /// the terminal's deferred wrap decides the answer. `colours` is the
    /// 256-colour cube as placement. `partial` is a scroll region, absolute
    /// positioning and an erase-in-line — the moves a program would rarely make
    /// by itself and mosh picks whenever they are cheaper. `less` is a pager
    /// with a reverse-video status line, repainting by scrolling. `vim` is a
    /// full-screen editor on the alternate screen.
    private static let checkpoints = ["wide-margin", "colours", "partial", "less", "vim"]

    func testOurTerminalAgreesWithTmuxAboutTheSameBytes() throws {
        for name in Self.checkpoints {
            let bytes = try fixture(name, "raw")
            let expected = try text(name, "txt")
            let rendered = render(bytes)

            XCTAssertEqual(rendered.count, expected.count, "\(name): a different number of rows")
            for (row, pair) in zip(rendered, expected).enumerated() {
                // Two renderings normalised the same way, and both differences
                // are conventions rather than disagreements about the bytes.
                //
                // A cell nobody wrote to is a **NUL** in SwiftTerm's buffer and
                // a space in tmux's capture — which the `partial` checkpoint
                // found, where an absolute cursor move jumps past four columns
                // to write PARTIAL and leaves them untouched. And trailing
                // blanks are stripped by `capture-pane` whether the program
                // wrote real spaces or left the cells alone, so a prompt of
                // "# " comes back as "#". Everything that is *in* a line is
                // still compared exactly.
                XCTAssertEqual(
                    pair.0.asTmuxWouldPrintIt, pair.1.asTmuxWouldPrintIt,
                    "\(name), row \(row):\n  ours: \(pair.0.debugDescription)\n  tmux: \(pair.1.debugDescription)"
                )
            }
        }
    }

    /// The attribute half, which the comparison above is blind to.
    ///
    /// The recording was built to produce one background colour per cell in a
    /// known place — `\u{1B}[48;5;Nm` then four characters, twenty-five entries
    /// to a row — so the expectation is arithmetic rather than another
    /// emulator's opinion. All 256, because the low sixteen and the greys are
    /// where a palette implementation goes wrong.
    func testEveryColourOfTheCubeLandsInTheRightCell() throws {
        let terminal = feed(try fixture("colours", "raw"))
        let rendered = render(try fixture("colours", "raw"))

        // Found rather than hardcoded: the recording opens with the echo of the
        // command that produced it, so the cube does not start at row nought.
        // Entry 0 prints as three spaces and a nought, and `printf " %3d"` makes
        // every entry four columns wide, which is twenty-five to a row.
        let first = try XCTUnwrap(
            rendered.firstIndex(where: { $0.hasPrefix("   0   1") }),
            "the colour cube is not in this recording:\n\(rendered.prefix(3).joined(separator: "\n"))"
        )

        for code in 0..<256 {
            let row = first + code / 25
            let column = (code % 25) * 4
            let cell = try XCTUnwrap(
                terminal.getCharData(col: column + 1, row: row),
                "no cell at row \(row), column \(column + 1)"
            )
            XCTAssertEqual(
                cell.attribute.bg, .ansi256(code: UInt8(code)),
                "colour \(code) at row \(row), column \(column + 1)"
            )
        }
    }

    /// The one thing the oracle cannot be asked about, and the reason the seam
    /// matters: applying host output can make the emulator *answer* — a device
    /// status report, an identification — and under mosh that answer has to go
    /// into the user stream, not onto a dead SSH channel. Here it is only
    /// observed; wiring it is phase 6's.
    func testTheEmulatorsOwnRepliesAreSomethingWeHaveToCarry() throws {
        let delegate = Recorder()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: Self.columns, rows: Self.rows)
        )

        // Device status report, and "what are you": both are questions a program
        // asks the terminal, and both are answered by the terminal itself.
        terminal.feed(text: "\u{1B}[6n\u{1B}[c")

        XCTAssertFalse(
            delegate.replies.isEmpty,
            "the emulator answered nothing, so there is nothing for the transport to carry"
        )
        let answer = String(decoding: delegate.replies.joined(), as: UTF8.self)
        XCTAssertTrue(answer.contains("\u{1B}["), "the reply is not an escape sequence: \(answer.debugDescription)")
    }

    // MARK: - Rendering

    private func render(_ bytes: Data) -> [String] {
        let terminal = feed(bytes)
        return (0..<Self.rows).map { row in
            terminal.getLine(row: row)?
                .translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
        }
    }

    private func feed(_ bytes: Data) -> Terminal {
        let terminal = Terminal(
            delegate: Recorder(),
            options: TerminalOptions(cols: Self.columns, rows: Self.rows)
        )
        terminal.feed(byteArray: [UInt8](bytes))
        return terminal
    }

    // MARK: - Fixtures

    private func fixture(_ name: String, _ suffix: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: name, withExtension: suffix, subdirectory: "oracle"
            ),
            "the fixture \(name).\(suffix) is not in the bundle"
        )
        return try Data(contentsOf: url)
    }

    /// tmux writes one line per row, each ended by a newline, so the split
    /// leaves a trailing empty element that is not a row.
    private func text(_ name: String, _ suffix: String) throws -> [String] {
        let whole = String(decoding: try fixture(name, suffix), as: UTF8.self)
        var lines = whole.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Only `send` has to be implemented; everything else in `TerminalDelegate`
    /// has a default — measured against the protocol and its extension rather
    /// than guessed, which saved a build. What it collects is the emulator's own
    /// replies.
    private final class Recorder: TerminalDelegate {
        var replies: [[UInt8]] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            replies.append(Array(data))
        }
    }
}

private extension String {
    /// What `tmux capture-pane` does to every line it prints, and therefore
    /// what a comparison with it has to do to ours: a cell nobody wrote to
    /// reads as a space, and trailing blanks go.
    var asTmuxWouldPrintIt: String {
        var copy = replacingOccurrences(of: "\0", with: " ")
        while let last = copy.last, last == " " || last == "\t" { copy.removeLast() }
        return copy
    }
}
