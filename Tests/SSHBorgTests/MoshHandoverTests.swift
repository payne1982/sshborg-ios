// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The handover line, and the two things that must never go wrong with it: it
/// has to be found in the middle of everything else the server says, and the
/// key has to be gone from anything a user could paste into an issue.
///
/// The fixture is mosh 1.4.0's real output, captured from a server started by
/// hand on 25/10/2026 — with the key replaced, because a real one is a secret
/// even after the session is over.
final class MoshHandoverTests: XCTestCase {

    private let said = """
        MOSH CONNECT 60001 d0rNPihs5BdCcl3I5zHHAg

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        Copyright 2012 Keith Winstein <mosh-devel@mit.edu>
        License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.
        This is free software: you are free to change and redistribute it.
        There is NO WARRANTY, to the extent permitted by law.

        [mosh-server detached, pid = 495665]
        """

    func testTheHandoverIsReadOutOfEverythingElseTheServerSays() throws {
        let handover = try XCTUnwrap(MoshHandover.parse(said, host: "a.example"))

        XCTAssertEqual(handover.host, "a.example")
        XCTAssertEqual(handover.port, 60001)
        XCTAssertEqual(handover.key, "d0rNPihs5BdCcl3I5zHHAg")
        // 22 base64 characters with the padding left off, which is sixteen
        // bytes — the length ``MoshCrypto`` insists on.
        XCTAssertEqual(handover.key.count, 22)
    }

    /// A line that looks like a handover **is** one: SSH has already
    /// authenticated whoever printed it, so there is nothing here to distrust.
    /// Android's first version of this test expected a fake line to be
    /// rejected, which was wrong in an instructive way.
    func testWhatIsNotAHandoverIsNotRead() {
        XCTAssertNil(MoshHandover.parse("", host: "h"))
        XCTAssertNil(MoshHandover.parse("mosh-server: command not found", host: "h"))
        XCTAssertNil(MoshHandover.parse("MOSH CONNECT 60001", host: "h"), "no key")
        XCTAssertNil(MoshHandover.parse("MOSH CONNECT abc key", host: "h"), "no port")
        XCTAssertNil(MoshHandover.parse("MOSH CONNECT 99999 key", host: "h"), "no such port")
        XCTAssertNil(MoshHandover.parse("MOSH CONNECT 0 key", host: "h"), "no such port")
    }

    /// The description exists so that a `print` or an error report cannot carry
    /// the key by accident.
    func testTheHandoverNeverDescribesItsKey() throws {
        let handover = try XCTUnwrap(MoshHandover.parse(said, host: "a.example"))

        XCTAssertEqual(handover.description, "MoshHandover(a.example:60001)")
        XCTAssertFalse(handover.description.contains(handover.key))
    }

    // MARK: - Redaction

    /// The case this exists for: the server printed a handover line *and* then
    /// something went wrong, so the whole text goes in front of the user — and
    /// that is exactly when somebody pastes it into an issue.
    func testRedactionTakesTheKeyOutAndLeavesTheDiagnosis() {
        let redacted = MoshHandover.redact(said)

        XCTAssertFalse(redacted.contains("d0rNPihs5BdCcl3I5zHHAg"), "the key survived:\n\(redacted)")
        XCTAssertTrue(redacted.contains("MOSH CONNECT 60001 <key withheld>"))
        // The port stays, because it is the half of the line worth diagnosing.
        XCTAssertTrue(redacted.contains("60001"))
        XCTAssertTrue(redacted.contains("mosh-server (mosh 1.4.0)"))
        XCTAssertTrue(redacted.contains("pid = 495665"))
    }

    func testRedactionIsAPureFunctionWithNothingToSayAboutOtherText() {
        XCTAssertEqual(MoshHandover.redact("  nothing to redact  "), "nothing to redact")
        XCTAssertEqual(MoshHandover.redact(""), "")
    }

    /// Two lines, because a server that is confused can repeat itself.
    func testEveryHandoverLineIsRedactedNotJustTheFirst() {
        let twice = """
            MOSH CONNECT 60001 firstkeyfirstkeyfirst1
            noise in between
            MOSH CONNECT 60002 secondkeysecondkeysec2
            """

        let redacted = MoshHandover.redact(twice)

        XCTAssertFalse(redacted.contains("firstkeyfirstkeyfirst1"))
        XCTAssertFalse(redacted.contains("secondkeysecondkeysec2"))
        XCTAssertTrue(redacted.contains("MOSH CONNECT 60002 <key withheld>"))
    }

    func testTheDetailIsBoundedSoItCannotFillADialog() {
        let shouting = String(repeating: "x", count: 5000)

        XCTAssertEqual(MoshHandover.redact(shouting).count, MoshHandover.detailLimit)
    }

    // MARK: - The port range a host may ask for

    /// Typed by hand out of a firewall rule, so a colon is as likely as a dash.
    func testAPortRangeIsReadTheWaySomebodyWouldWriteIt() {
        XCTAssertEqual(MoshHandover.portRange("60001-60999"), "60001:60999")
        XCTAssertEqual(MoshHandover.portRange("60001:60999"), "60001:60999")
        XCTAssertEqual(MoshHandover.portRange(" 60001 - 60999 "), "60001:60999")
        XCTAssertEqual(MoshHandover.portRange("60001"), "60001")
        XCTAssertEqual(MoshHandover.portRange("60001-60001"), "60001")
    }

    /// Anything we cannot make sense of asks for nothing, rather than handing
    /// the server rubbish after `-p`.
    func testNonsenseAsksForNothing() {
        XCTAssertNil(MoshHandover.portRange(nil))
        XCTAssertNil(MoshHandover.portRange(""))
        XCTAssertNil(MoshHandover.portRange("   "))
        XCTAssertNil(MoshHandover.portRange("sixty thousand"))
        XCTAssertNil(MoshHandover.portRange("60999-60001"), "backwards")
        XCTAssertNil(MoshHandover.portRange("0-100"), "no port zero")
        XCTAssertNil(MoshHandover.portRange("1-70000"), "no port 70000")
        XCTAssertNil(MoshHandover.portRange("1-2-3"), "three of them")
    }

    // MARK: - Nothing prints the key

    /// Every way Swift has of turning a value into text, and the debugger's too.
    /// It used to be a property that happened to be called `description`, so
    /// all of these fell back to printing every field, the key among them.
    func testNoFormattingOfAHandoverCarriesItsKey() {
        let handover = MoshHandover(host: "a.example", port: 60001, key: "SECRETKEYSECRETKEYSECR")
        var dumped = ""
        dump(handover, to: &dumped)

        for text in ["\(handover)", String(describing: handover), String(reflecting: handover), dumped] {
            XCTAssertFalse(text.contains("SECRETKEY"), "the key escaped: \(text)")
            XCTAssertTrue(text.contains("60001"), "and it no longer says where: \(text)")
        }
    }
}
