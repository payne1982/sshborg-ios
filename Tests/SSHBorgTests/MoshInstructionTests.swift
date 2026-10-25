// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The instruction and the two layers it is wrapped in: the hand-written
/// protobuf, and zlib.
final class MoshInstructionTests: XCTestCase {

    func testAnInstructionSurvivesSerialisationWholeAndInOrder() throws {
        var instruction = MoshInstruction()
        instruction.oldNumber = 11
        instruction.newNumber = 12
        instruction.ackNumber = 300
        instruction.throwawayNumber = 7
        instruction.diff = Data([0x1B, 0x5B, 0x48])

        let parsed = try MoshInstruction.parse(instruction.serialized)

        XCTAssertEqual(parsed, instruction)
        // Field order is the message's own, smallest field number first, which
        // is what makes two identical instructions identical on the wire.
        XCTAssertEqual(Array(instruction.serialized.prefix(2)), [0x08, 0x02], "version is field 1")
    }

    func testAnInstructionSurvivesCompressionToo() throws {
        var instruction = MoshInstruction()
        instruction.newNumber = 5
        instruction.diff = Data(repeating: 0x41, count: 2000)

        let encoded = try instruction.encoded
        XCTAssertLessThan(encoded.count, 200, "two thousand of the same byte did not compress")
        XCTAssertEqual(Array(encoded.prefix(2)), [0x78, 0x9C], "not a zlib stream")

        XCTAssertEqual(try MoshInstruction.decode(fragmentPayload: encoded), instruction)
    }

    /// The chaff is padding so that the size of a datagram cannot report how
    /// much was typed. It goes out and it is dropped on the way in, which means
    /// a round trip is not an equality but a deliberate asymmetry.
    func testTheChaffIsSentAndThenIgnored() throws {
        var instruction = MoshInstruction()
        instruction.chaff = Data(repeating: 0x00, count: 32)

        let serialized = instruction.serialized
        XCTAssertGreaterThan(serialized.count, MoshInstruction().serialized.count)

        let parsed = try MoshInstruction.parse(serialized)
        XCTAssertEqual(parsed.chaff, Data(), "the padding was kept")
        XCTAssertEqual(parsed.diff, Data())
    }

    /// Mosh treats a version it does not know as fatal rather than as something
    /// to negotiate, and so do we: the state numbering *is* the protocol, and
    /// guessing at a different one corrupts the screen instead of failing.
    func testAnotherProtocolVersionIsFatal() {
        let wrong = ProtoWriter().varint(1, 3).varint(2, 0).varint(3, 0).data

        XCTAssertThrowsError(try MoshInstruction.parse(wrong)) {
            XCTAssertEqual($0 as? MoshProtocolError, .protocolVersion(3))
        }
    }

    func testAMessageWithNoVersionAtAllIsRefused() {
        XCTAssertThrowsError(try MoshInstruction.parse(Data())) {
            XCTAssertEqual($0 as? MoshProtocolError, .protocolVersion(0))
        }
    }

    /// Unknown fields are skipped, which is how protocol buffers are meant to
    /// behave and what would let a future mosh add something without breaking
    /// us. All four wire types, because skipping is where a parser loses its
    /// place.
    func testAFieldWeDoNotKnowIsSkippedRatherThanRefused() throws {
        let writer = ProtoWriter()
            .varint(1, UInt64(MoshInstruction.protocolVersion))
            .varint(99, 1234)
            .bytes(98, Data([1, 2, 3]))
            .varint(3, 42)

        let parsed = try MoshInstruction.parse(writer.data)

        XCTAssertEqual(parsed.newNumber, 42, "the parser lost its place on an unknown field")
    }

    func testAWireTypeMoshNeverUsesIsRefused() {
        // Field 1, wire type 3 (the start of a proto2 group), which mosh's
        // messages never contain and this parser cannot step over.
        var bytes = Data([0x0B])
        bytes.append(0x00)

        XCTAssertThrowsError(try MoshInstruction.parse(bytes)) {
            XCTAssertEqual($0 as? MoshProtocolError, .unknownWireType(3))
        }
    }

    func testATruncatedVarintIsRefusedRatherThanRead() {
        // 0x08 is "field 1, varint", and then the varint's continuation bit is
        // set with nothing after it.
        XCTAssertThrowsError(try MoshInstruction.parse(Data([0x08, 0x80]))) {
            XCTAssertEqual($0 as? MoshProtocolError, .varintPastTheEnd)
        }
    }

    func testALengthThatDoesNotFitIsRefused() {
        // Field 6 (the diff), length-delimited, claiming 200 bytes in a message
        // that has three.
        XCTAssertThrowsError(try MoshInstruction.parse(Data([0x32, 200, 1, 2, 3]))) {
            XCTAssertEqual($0 as? MoshProtocolError, .fieldDoesNotFit(200))
        }
    }

    /// A peer decides how far its own payload expands, so there has to be a
    /// ceiling — and mosh's own is 2048 by 2048.
    func testAnInstructionThatDecompressesPastTheCeilingIsRefused() throws {
        let bomb = try MoshDeflate.deflate(Data(count: MoshInstruction.maxDecompressed + 1))

        XCTAssertThrowsError(try MoshInstruction.decode(fragmentPayload: bomb)) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .tooLarge)
        }
    }

    func testSomethingThatIsNotCompressedAtAllIsRefused() {
        XCTAssertThrowsError(
            try MoshInstruction.decode(fragmentPayload: MoshInstruction().serialized)
        ) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .notZlib)
        }
    }

    // MARK: - zlib both ways

    /// The deflater is ours — Apple's framework does raw DEFLATE and mosh wants
    /// the zlib format — so the two halves have to agree about the wrapper and
    /// the checksum.
    func testWhatWeDeflateWeCanInflate() throws {
        for length in [1, 2, 100, 5000] {
            let raw = Data((0..<length).map { UInt8($0 % 251) })
            let stream = try MoshDeflate.deflate(raw)

            XCTAssertEqual(Array(stream.prefix(2)), [0x78, 0x9C], "length \(length)")
            XCTAssertEqual(try MoshDeflate.inflate(stream), raw, "length \(length)")
        }
    }

    /// Nothing to compress is refused rather than answered, and the reason is
    /// the asymmetry it would otherwise create: the stream for an empty payload
    /// is the one thing `compression_decode_buffer` cannot read back, because it
    /// reports "nothing came out" and "it failed" with the same zero. An
    /// instruction always carries its five numbers, so the protocol never asks.
    func testThereIsNothingToDeflateAboutNothing() {
        XCTAssertThrowsError(try MoshDeflate.deflate(Data())) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .nothingToDeflate)
        }
    }
}
