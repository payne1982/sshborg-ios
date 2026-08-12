// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Word mode: Android's Spellcheck key, which swaps the terminal's input type
/// between raw keys and text with autocorrection.
///
/// No server needed — this is about the input traits the keyboard reads, so it
/// runs everywhere rather than skipping with the integration suites.
@MainActor
final class WordModeTests: XCTestCase {

    private var database: AppDatabase!
    private var session: TerminalSession!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        session = TerminalSession(
            host: Host(label: "somewhere", hostname: "example.invalid", username: "someone"),
            hosts: HostRepository(database),
            keys: SSHKeyRepository(database)
        )
    }

    func testATerminalStartsWithNoCorrectionAtAll() {
        XCTAssertFalse(session.wordMode)
        XCTAssertEqual(session.terminalView.autocorrectionType, .no)
        XCTAssertEqual(session.terminalView.spellCheckingType, .no)
    }

    func testTurningItOnAsksTheKeyboardForSuggestions() {
        session.wordMode = true

        XCTAssertEqual(session.terminalView.autocorrectionType, .yes)
        XCTAssertEqual(session.terminalView.spellCheckingType, .yes)
    }

    func testTurningItOffPutsTheTerminalBack() {
        session.wordMode = true
        session.wordMode = false

        XCTAssertEqual(session.terminalView.autocorrectionType, .no)
        XCTAssertEqual(session.terminalView.spellCheckingType, .no)
    }

    /// The parts that must never move, in either mode.
    ///
    /// Capitalisation would fight a case-sensitive shell, and the smart
    /// substitutions are worse than useless in a command line: they turn `"` into
    /// a curly quote and `--flag` into an en dash, which the shell then cannot
    /// parse. Android's word mode sets the autocorrect flag and nothing else, for
    /// the same reason.
    func testWordModeNeverTouchesCapitalisationOrSmartPunctuation() {
        for enabled in [true, false] {
            session.wordMode = enabled

            XCTAssertEqual(session.terminalView.autocapitalizationType, .none, "wordMode = \(enabled)")
            XCTAssertEqual(session.terminalView.smartQuotesType, .no, "wordMode = \(enabled)")
            XCTAssertEqual(session.terminalView.smartDashesType, .no, "wordMode = \(enabled)")
        }
    }
}
