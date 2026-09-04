// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

final class CommandHistoryTests: XCTestCase {

    // MARK: - Parsing

    func testPlainBashHistoryIsMostRecentFirst() {
        let history = CommandHistory.parse(Data("""
        first command
        second command
        third command
        """.utf8))

        XCTAssertEqual(history.commands, ["third command", "second command", "first command"])
    }

    /// zsh writes ": <epoch>:<elapsed>;<command>". Leaving the header in would
    /// make every suggestion start with a timestamp.
    func testZshExtendedFormatHeaderIsStripped() {
        let history = CommandHistory.parse(Data("""
        : 1700000000:0;git status
        : 1700000005:12;make build
        """.utf8))

        XCTAssertEqual(history.commands, ["make build", "git status"])
    }

    func testFishFormatIsStripped() {
        let history = CommandHistory.parse(Data("""
        - cmd: ls -la
          when: 1700000000
        """.utf8))

        XCTAssertTrue(history.commands.contains("ls -la"))
    }

    /// A command with a semicolon must not be mistaken for a zsh header.
    func testSemicolonInACommandIsNotTreatedAsAHeader() {
        let history = CommandHistory.parse(Data("cd /tmp; ls".utf8))
        XCTAssertEqual(history.commands, ["cd /tmp; ls"])
    }

    func testDuplicatesKeepOnlyTheMostRecent() {
        let history = CommandHistory.parse(Data("""
        git status
        make
        git status
        """.utf8))

        XCTAssertEqual(history.commands, ["git status", "make"])
    }

    func testVeryShortAndBlankLinesAreDropped() {
        let history = CommandHistory.parse(Data("\nls\n\n  \nx\n".utf8))
        XCTAssertEqual(history.commands, ["ls"])
    }

    func testMergingKeepsFirstOccurrence() {
        let merged = CommandHistory.merging([
            CommandHistory(commands: ["a", "b"]),
            CommandHistory(commands: ["b", "c"]),
        ])
        XCTAssertEqual(merged.commands, ["a", "b", "c"])
    }

    // MARK: - Matching

    private let history = CommandHistory(commands: [
        "git status",
        "git commit -m wip",
        "make build",
        "sudo systemctl restart nginx",
    ])

    func testPrefixMatchesComeFirst() {
        let result = history.suggestions(for: "git")
        XCTAssertEqual(result.first, "git status")
        XCTAssertEqual(result.count, 2)
    }

    /// A substring match finds the long pipeline you only half remember.
    func testSubstringMatchesFollowPrefixMatches() {
        let result = history.suggestions(for: "st")
        XCTAssertTrue(result.contains("git status"))
        XCTAssertTrue(result.contains("sudo systemctl restart nginx"))
    }

    /// Below two characters everything matches and the bar is only noise.
    func testTooShortAQueryOffersNothing() {
        XCTAssertTrue(history.suggestions(for: "g").isEmpty)
        XCTAssertTrue(history.suggestions(for: "").isEmpty)
    }

    /// Suggesting exactly what is already typed is a wasted tap.
    func testExactMatchIsNotSuggested() {
        XCTAssertFalse(history.suggestions(for: "make build").contains("make build"))
    }

    func testLimitIsRespected() {
        let many = CommandHistory(commands: (0..<50).map { "command\($0)" })
        XCTAssertEqual(many.suggestions(for: "command", limit: 5).count, 5)
    }

    // MARK: - Prompt parsing

    func testTypedPortionAfterADollarPrompt() {
        XCTAssertEqual(PromptParser.typedPortion(of: "user@host:~$ git st"), "git st")
    }

    func testTypedPortionAfterARootPrompt() {
        XCTAssertEqual(PromptParser.typedPortion(of: "root@box:/etc# systemctl"), "systemctl")
    }

    func testTypedPortionAfterAZshPercentPrompt() {
        XCTAssertEqual(PromptParser.typedPortion(of: "box% make"), "make")
    }

    /// The Starship / Powerlevel10k arrow, which this list did not have until
    /// 05/09/2026 while Android's regex always did.
    ///
    /// It is not an exotic case: the app bundles a Nerd Font so exactly these
    /// prompts render, and on a host using one the suggestion bar could never
    /// appear — `typedPortion` returned nil for every line.
    func testAnArrowPromptIsRecognised() {
        XCTAssertEqual(PromptParser.typedPortion(of: "~/src ❯ git pu"), "git pu")
        XCTAssertEqual(PromptParser.typedPortion(of: "❯ ls -la"), "ls -la")
    }

    /// A prompt carrying a path with a terminator in it must not confuse the
    /// split — the *last* one wins.
    func testLastTerminatorWins() {
        XCTAssertEqual(PromptParser.typedPortion(of: "user@host:/tmp/a#b$ ls -la"), "ls -la")
    }

    /// Ordinary output has no prompt, and matching against it would fill the bar
    /// with nonsense.
    func testOutputWithoutAPromptYieldsNothing() {
        XCTAssertNil(PromptParser.typedPortion(of: "total 48"))
        XCTAssertNil(PromptParser.typedPortion(of: ""))
    }

    func testEmptyLineAfterThePromptIsEmptyNotNil() {
        XCTAssertEqual(PromptParser.typedPortion(of: "user@host:~$ "), "")
    }
}
