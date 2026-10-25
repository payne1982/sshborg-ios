// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The two state diffs, and the stream of actions that produces ours.
///
/// The host diff is read against bytes built here with the same writer, which
/// proves the *structure* and not the field numbers. The field numbers are
/// proved by the lab, where the bytes come from a real `mosh-server` —
/// `MoshLabIntegrationTests`.
final class MoshDiffsTests: XCTestCase {

    // MARK: - What we send

    /// Keystrokes are nested twice: an `Instruction` in field 1, carrying a
    /// `UserByteString` extension, carrying the bytes. Spelled out here because
    /// a diff that is one level out reaches the server as nothing at all.
    func testKeystrokesAreNestedTheWayMoshNestsThem() throws {
        let diff = MoshDiffs.encodeUserDiff([.keystrokes(Data("ls\r".utf8))])

        let outer = ProtoReader(diff)
        var instructions: [Data] = []
        try outer.forEachField { field, wireType in
            XCTAssertEqual(field, 1)
            XCTAssertEqual(wireType, ProtoWire.bytes)
            instructions.append(try outer.readBytes())
        }
        XCTAssertEqual(instructions.count, 1)

        let instruction = ProtoReader(instructions[0])
        var keystroke: Data?
        try instruction.forEachField { field, wireType in
            XCTAssertEqual(field, 2, "keystrokes are extension 2")
            XCTAssertEqual(wireType, ProtoWire.bytes)
            keystroke = try instruction.readBytes()
        }

        let inner = ProtoReader(try XCTUnwrap(keystroke))
        var keys: Data?
        try inner.forEachField { field, wireType in
            XCTAssertEqual(field, 4, "the bytes are field 4 of the extension")
            XCTAssertEqual(wireType, ProtoWire.bytes)
            keys = try inner.readBytes()
        }
        XCTAssertEqual(keys, Data("ls\r".utf8))
    }

    func testAResizeCarriesItsWidthAndHeight() throws {
        let diff = MoshDiffs.encodeUserDiff([.resize(width: 120, height: 40)])

        let outer = ProtoReader(diff)
        var body = Data()
        try outer.forEachField { _, _ in body = try outer.readBytes() }

        let instruction = ProtoReader(body)
        var resize = Data()
        try instruction.forEachField { field, _ in
            XCTAssertEqual(field, 3, "a user resize is extension 3")
            resize = try instruction.readBytes()
        }

        let fields = ProtoReader(resize)
        var width: UInt64 = 0
        var height: UInt64 = 0
        try fields.forEachField { field, _ in
            if field == 5 { width = try fields.readVarint() } else { height = try fields.readVarint() }
        }
        XCTAssertEqual(width, 120)
        XCTAssertEqual(height, 40)
    }

    func testAnEmptyDiffIsEmptyBytesAndNotAnEmptyMessage() {
        XCTAssertEqual(MoshDiffs.encodeUserDiff([]), Data())
    }

    // MARK: - What we read

    func testHostBytesComeOutAsHostBytes() throws {
        let diff = hostDiff([
            instruction(extension: 2, body: ProtoWriter().bytes(4, Data("hello".utf8)).data)
        ])

        XCTAssertEqual(try MoshDiffs.decodeHostDiff(diff), [.hostBytes(Data("hello".utf8))])
    }

    func testAHostResizeComesOutAsAResize() throws {
        let diff = hostDiff([
            instruction(
                extension: 3,
                body: ProtoWriter().varint(5, 80).varint(6, 24).data
            )
        ])

        XCTAssertEqual(try MoshDiffs.decodeHostDiff(diff), [.resize(width: 80, height: 24)])
    }

    /// Read and ignored until there is a prediction engine, which is phase 7
    /// and may be never — but it has to be read, or the parser loses its place
    /// in a frame that contains one.
    func testAnEchoAcknowledgementIsReadAndNotSkipped() throws {
        let diff = hostDiff([
            instruction(extension: 7, body: ProtoWriter().varint(8, 4242).data),
            instruction(extension: 2, body: ProtoWriter().bytes(4, Data("x".utf8)).data),
        ])

        XCTAssertEqual(
            try MoshDiffs.decodeHostDiff(diff),
            [.echoAck(4242), .hostBytes(Data("x".utf8))]
        )
    }

    /// A future mosh may add an extension. Ignoring it is better than refusing
    /// the frame, which would lose the screen for the sake of a field we do not
    /// need.
    func testAnExtensionWeDoNotKnowIsIgnoredAndTheRestIsRead() throws {
        let diff = hostDiff([
            instruction(extension: 42, body: ProtoWriter().varint(1, 1).data),
            instruction(extension: 2, body: ProtoWriter().bytes(4, Data("after".utf8)).data),
        ])

        XCTAssertEqual(try MoshDiffs.decodeHostDiff(diff), [.hostBytes(Data("after".utf8))])
    }

    func testAnEmptyHostDiffMeansNothingHappened() throws {
        XCTAssertEqual(try MoshDiffs.decodeHostDiff(Data()), [])
    }

    // MARK: - Fixtures

    private func instruction(extension field: Int, body: Data) -> Data {
        ProtoWriter().bytes(field, body).data
    }

    private func hostDiff(_ instructions: [Data]) -> Data {
        let writer = ProtoWriter()
        for instruction in instructions { writer.bytes(1, instruction) }
        return writer.data
    }
}

/// The client's half of the state: a growing list of what the user did.
final class MoshUserStreamTests: XCTestCase {

    func testAStreamStartsWithNothingHavingHappened() throws {
        let stream = MoshUserStream()

        XCTAssertEqual(stream.count, 0)
        XCTAssertEqual(try stream.diff(from: 0), Data())
    }

    func testTypingAdvancesTheState() {
        let stream = MoshUserStream()

        stream.type(Data("a".utf8))
        stream.type(Data("b".utf8))

        XCTAssertEqual(stream.count, 2)
    }

    /// Nothing typed is not an action: an empty write would otherwise advance
    /// the state number and make the far end ask for a diff that says nothing.
    func testTypingNothingIsNotAnAction() {
        let stream = MoshUserStream()

        stream.type(Data())

        XCTAssertEqual(stream.count, 0)
    }

    /// A hundred separate instructions and one instruction of a hundred bytes
    /// mean the same thing to the pty, and the second is smaller. This is where
    /// a burst of typing becomes one packet.
    func testARunOfTypingIsJoinedIntoOneAction() throws {
        let stream = MoshUserStream()
        for character in "hello" { stream.type(Data(String(character).utf8)) }

        let diff = try stream.diff(from: 0)

        XCTAssertEqual(diff, MoshDiffs.encodeUserDiff([.keystrokes(Data("hello".utf8))]))
        // The state is still five actions: coalescing is about the wire, not
        // about the numbering, which has to stay what the far end acknowledged.
        XCTAssertEqual(stream.count, 5)
    }

    /// A resize in the middle of a burst is not a keystroke and cannot be
    /// joined across, because the far end lays out what follows it differently.
    func testAResizeBreaksARunRatherThanBeingSwallowed() throws {
        let stream = MoshUserStream()
        stream.type(Data("ab".utf8))
        stream.resize(width: 100, height: 30)
        stream.type(Data("cd".utf8))

        let diff = try stream.diff(from: 0)

        XCTAssertEqual(
            diff,
            MoshDiffs.encodeUserDiff([
                .keystrokes(Data("ab".utf8)),
                .resize(width: 100, height: 30),
                .keystrokes(Data("cd".utf8)),
            ])
        )
    }

    func testADiffFromTheMiddleCarriesOnlyWhatCameAfter() throws {
        let stream = MoshUserStream()
        stream.type(Data("one".utf8))
        stream.type(Data("two".utf8))

        XCTAssertEqual(
            try stream.diff(from: 1),
            MoshDiffs.encodeUserDiff([.keystrokes(Data("two".utf8))])
        )
    }

    /// Acknowledged actions are freed, and the numbering carries on regardless:
    /// a state number means one thing for the life of the session.
    func testFreeingWhatTheFarEndHasSeenDoesNotMoveTheNumbering() throws {
        let stream = MoshUserStream()
        stream.type(Data("one".utf8))
        stream.type(Data("two".utf8))

        stream.dropThrough(1)

        XCTAssertEqual(stream.count, 2)
        XCTAssertEqual(
            try stream.diff(from: 1),
            MoshDiffs.encodeUserDiff([.keystrokes(Data("two".utf8))])
        )
    }

    /// Both of these would be our bug and not the peer's, so they say so rather
    /// than returning something plausible.
    func testAskingForWhatHasBeenFreedOrNeverHappenedIsRefused() {
        let stream = MoshUserStream()
        stream.type(Data("one".utf8))
        stream.type(Data("two".utf8))
        stream.dropThrough(2)

        XCTAssertThrowsError(try stream.diff(from: 1)) {
            XCTAssertEqual($0 as? MoshProtocolError, .actionsAlreadyFreed(from: 1, freed: 2))
        }
        XCTAssertThrowsError(try stream.diff(from: 3)) {
            XCTAssertEqual($0 as? MoshProtocolError, .noSuchAction(from: 3, count: 2))
        }
    }

    func testFreeingMoreThanHappenedFreesWhatThereIs() {
        let stream = MoshUserStream()
        stream.type(Data("one".utf8))

        stream.dropThrough(99)

        XCTAssertEqual(stream.count, 1)
    }
}
