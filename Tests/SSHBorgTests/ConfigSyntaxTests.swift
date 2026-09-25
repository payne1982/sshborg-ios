// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The highlighter's job is to be right about the cases that catch naive ones,
/// and to be harmless everywhere else: it colours, it never edits, so a mistake
/// here can only look wrong.
final class ConfigSyntaxTests: XCTestCase {

    private func tokens(_ line: String, _ family: ConfigSyntax.Family) -> [(String, ConfigSyntax.Token)] {
        let characters = Array(line)
        return ConfigSyntax.highlight(line, family: family).runs.map {
            (String(characters[$0.start..<$0.end]), $0.token)
        }
    }

    // MARK: - Which file is this

    func testKnownNamesAndExtensionsDecideOnTheirOwn() {
        XCTAssertEqual(ConfigSyntax.family(of: "sshd_config", text: ""), .conf)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy.sh", text: ""), .shell)
        XCTAssertEqual(ConfigSyntax.family(of: "docker-compose.yml", text: ""), .yaml)
        XCTAssertEqual(ConfigSyntax.family(of: "package.json", text: ""), .json)
        XCTAssertEqual(ConfigSyntax.family(of: "pom.xml", text: ""), .xml)
        XCTAssertEqual(ConfigSyntax.family(of: "notes.txt", text: "anything"), .plain)
    }

    /// A name that says nothing leaves the shape of the file to decide.
    ///
    /// Not "config", which is a known *extension* and therefore answers for
    /// itself — as it does on Android, where the same two lookups run in the
    /// same order.
    func testAnUnknownNameIsSniffed() {
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "#!/bin/bash\necho hi\n"), .shell)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "<?xml version=\"1.0\"?>"), .xml)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "{\n  \"a\": 1\n}"), .json)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "[section]\nkey = value\n"), .ini)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "name: value\nother: 2\n"), .yaml)
        XCTAssertEqual(ConfigSyntax.family(of: "deploy", text: "just some prose\nand more of it\n"), .plain)
    }

    /// And a name that does say something is taken at its word.
    func testAKnownExtensionAnswersForItself() {
        XCTAssertEqual(ConfigSyntax.family(of: "config", text: "just some prose\n"), .conf)
    }

    // MARK: - The cases that catch naive highlighters

    /// A `#` inside a string is not a comment.
    func testAHashInsideAStringIsNotAComment() {
        let coloured = tokens("PermitRootLogin \"no # really\"", .conf)
        XCTAssertTrue(coloured.contains { $0.1 == .string && $0.0.contains("#") })
        XCTAssertFalse(coloured.contains { $0.1 == .comment })
    }

    /// An apostrophe in a comment does not open a string that swallows the rest.
    func testAnApostropheInACommentOpensNothing() {
        let coloured = tokens("# don't do this", .shell)
        XCTAssertEqual(coloured.count, 1)
        XCTAssertEqual(coloured.first?.1, .comment)
    }

    /// The `//` in a URL is not the start of anything.
    func testASlashInAURLStartsNothing() {
        let coloured = tokens("url = https://example.invalid/path", .ini)
        XCTAssertFalse(coloured.contains { $0.1 == .comment })
        XCTAssertTrue(coloured.contains { $0.0 == "url" && $0.1 == .key })
    }

    // MARK: - Each family's one useful rule

    /// The first word of a line is the directive in sshd_config and its kin;
    /// that one rule is what makes those files readable.
    func testTheFirstWordOfAConfLineIsTheDirective() {
        let coloured = tokens("Port 2222", .conf)
        XCTAssertEqual(coloured.first?.0, "Port")
        XCTAssertEqual(coloured.first?.1, .keyword)
        XCTAssertTrue(coloured.contains { $0.0 == "2222" && $0.1 == .number })
    }

    func testShellKeywordsAndVariables() {
        let coloured = tokens("export PATH=$HOME/bin", .shell)
        XCTAssertTrue(coloured.contains { $0.0 == "export" && $0.1 == .keyword })
        XCTAssertTrue(coloured.contains { $0.0 == "$HOME" && $0.1 == .variable })
    }

    func testINISectionsAndKeys() {
        XCTAssertTrue(tokens("[core]", .ini).contains { $0.0 == "[core]" && $0.1 == .keyword })
        XCTAssertTrue(tokens("  editor = vim", .ini).contains { $0.0 == "editor" && $0.1 == .key })
    }

    func testYAMLKeysAndAnchors() {
        XCTAssertTrue(tokens("  image: nginx", .yaml).contains { $0.0 == "image" && $0.1 == .key })
        XCTAssertTrue(tokens("  base: &defaults", .yaml).contains { $0.0 == "&defaults" && $0.1 == .variable })
    }

    func testConstantsReadAsValues() {
        XCTAssertTrue(tokens("enabled: true", .yaml).contains { $0.0 == "true" && $0.1 == .number })
    }

    // MARK: - XML, which carries state between lines

    func testXMLTagsAttributesAndEntities() {
        let coloured = tokens("<server port=\"80\">&amp;</server>", .xml)
        XCTAssertTrue(coloured.contains { $0.0 == "<server" && $0.1 == .tag })
        XCTAssertTrue(coloured.contains { $0.0 == "port" && $0.1 == .key })
        XCTAssertTrue(coloured.contains { $0.0 == "\"80\"" && $0.1 == .string })
        XCTAssertTrue(coloured.contains { $0.0 == "&amp;" && $0.1 == .number })
    }

    /// An XML comment crosses lines, and the state carried says so.
    func testAnXMLCommentCarriesToTheNextLine() {
        let opening = ConfigSyntax.highlight("<!-- a note", family: .xml)
        XCTAssertTrue(opening.inComment, "the comment was closed on the same line")

        let middle = ConfigSyntax.highlight("still a note", family: .xml, inComment: true)
        XCTAssertEqual(middle.runs.first?.token, .comment)
        XCTAssertTrue(middle.inComment)

        let closing = ConfigSyntax.highlight("done --><tag/>", family: .xml, inComment: true)
        XCTAssertFalse(closing.inComment)
        XCTAssertTrue(closing.runs.contains { $0.token == .tag })
    }

    // MARK: - Plain files

    /// Prose and logs get no colour at all: it would be noise, not information.
    func testAPlainFileIsLeftAlone() {
        XCTAssertTrue(ConfigSyntax.highlight("anything at all # here", family: .plain).runs.isEmpty)
    }

    /// Runs must stay inside the line and never overlap, or the attributes built
    /// from them would land on the wrong characters.
    func testRunsStayInsideTheLineAndDoNotOverlap() {
        let line = "Host *.example.invalid   # the lot"
        let runs = ConfigSyntax.highlight(line, family: .conf).runs

        var previousEnd = 0
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.start, previousEnd, "runs overlap")
            XCTAssertLessThan(run.start, run.end, "an empty run")
            XCTAssertLessThanOrEqual(run.end, line.count, "a run past the end of the line")
            previousEnd = run.end
        }
    }
}
