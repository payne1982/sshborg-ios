// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftTerm
import XCTest

@testable import SSHBorg

/// Does a number from the far end buy a budget in SwiftTerm?
///
/// Android's `f858d7d` found that every count in a CSI sequence was taken at
/// face value in *their* emulator, and three of them drive a loop or index a
/// row: `CSI 2000000000 S` is two billion rows scrolled one at a time, `CSI
/// 2000000000 b` is two billion characters painted, and `CSI 2147483648 @`
/// overflowed the parameter accumulator into a negative number and walked off
/// the start of its own row. None of it needs a hostile server: these arrive on
/// whatever the far end prints, so `cat` of a file somebody else wrote is
/// enough, and it is as true over SSH today as it would be over mosh.
///
/// The emulator is not ours, so the cure would not be either — but the question
/// is ours, because the app freezing is the app freezing. Each case is fed on a
/// thread of its own with a deadline, so that an emulator which never comes back
/// is reported as a failure instead of hanging the suite with nothing to say.
final class TerminalLimitsTests: XCTestCase {

    /// Generous: the point is to tell "slow" from "never".
    private let deadline: TimeInterval = 10

    func testAHugeScrollCountDoesNotHangTheEmulator() {
        measureUnderDeadline("CSI 2000000000 S", feeding: "\u{1B}[2000000000S")
    }

    func testAHugeRepeatCountDoesNotHangTheEmulator() {
        measureUnderDeadline("CSI 2000000000 b", feeding: "A\u{1B}[2000000000b")
    }

    func testAnInsertCountPastTwoBillionDoesNotCrash() {
        measureUnderDeadline("CSI 2147483648 @", feeding: "\u{1B}[2147483648@")
    }

    func testAHugeDeleteAndEraseCountDoNotHangTheEmulator() {
        measureUnderDeadline("CSI 2000000000 P and X", feeding: "\u{1B}[2000000000P\u{1B}[2000000000X")
    }

    func testAHugeCursorMoveDoesNotHangTheEmulator() {
        measureUnderDeadline(
            "CSI 2000000000 B and C", feeding: "\u{1B}[2000000000B\u{1B}[2000000000C"
        )
    }

    /// An unterminated OSC string, which in their emulator grew for as long as
    /// the far end kept typing, and a run of semicolons, which grew the
    /// parameter list the same way. Half a megabyte of each is not a lot to
    /// send and is a great deal to keep.
    func testAnUnterminatedStringAndALongParameterListAreNotKeptForever() {
        measureUnderDeadline(
            "an OSC that never ends",
            feeding: "\u{1B}]0;" + String(repeating: "x", count: 500_000)
        )
        measureUnderDeadline(
            "a parameter list that never ends",
            feeding: "\u{1B}[" + String(repeating: ";", count: 200_000) + "m"
        )
    }

    /// Feeds on a thread of its own and waits. A deadline rather than
    /// `measure`: what matters is whether it comes back at all.
    private func measureUnderDeadline(_ what: String, feeding text: String) {
        let finished = expectation(description: what)
        let elapsed = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        elapsed.initialize(to: 0)
        defer { elapsed.deallocate() }

        Thread.detachNewThread {
            let terminal = Terminal(delegate: Silent(), options: TerminalOptions(cols: 100, rows: 30))
            let started = Date()
            terminal.feed(text: text)
            // Something afterwards, so a parser left in a bad state is noticed
            // here rather than on somebody's screen.
            terminal.feed(text: "\u{1B}[HAFTER")
            elapsed.pointee = Date().timeIntervalSince(started)
            finished.fulfill()
        }

        let outcome = XCTWaiter.wait(for: [finished], timeout: deadline)
        XCTAssertEqual(
            outcome, .completed,
            "\(what): the emulator did not come back within \(Int(deadline)) seconds"
        )
        if outcome == .completed {
            print("TerminalLimits — \(what): \(String(format: "%.3f", elapsed.pointee)) s")
        }
    }

    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}
