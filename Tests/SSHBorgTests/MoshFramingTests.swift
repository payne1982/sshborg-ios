// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The packet, the fragment, and the two halves of putting an instruction on
/// the wire and getting it back.
final class MoshFramingTests: XCTestCase {

    // MARK: - The packet

    func testAPacketIsTwoTimestampsThenThePayload() throws {
        let packet = MoshPacket(timestamp: 0x1234, timestampReply: 0xABCD, payload: Data([1, 2, 3]))

        XCTAssertEqual(Array(packet.encoded), [0x12, 0x34, 0xAB, 0xCD, 1, 2, 3])
        XCTAssertEqual(try MoshPacket.decode(packet.encoded), packet)
    }

    /// Sixteen bits of ones is "nothing to say", which is what the first
    /// datagram of a session replies with because there is nothing to reply to.
    func testTheEmptyTimestampSurvivesTheWire() throws {
        let packet = MoshPacket(timestamp: 0, timestampReply: MoshPacket.none, payload: Data())

        let decoded = try MoshPacket.decode(packet.encoded)
        XCTAssertEqual(decoded.timestampReply, 0xFFFF)
        XCTAssertEqual(decoded.payload, Data())
    }

    func testAPacketWithoutItsTimestampsIsRefused() {
        for length in 0..<4 {
            XCTAssertThrowsError(try MoshPacket.decode(Data(count: length))) {
                XCTAssertEqual($0 as? MoshProtocolError, .packetWithoutTimestamps)
            }
        }
    }

    // MARK: - The fragment

    func testAFragmentCarriesItsIdAndItsFinalBit() throws {
        let fragment = MoshFragment(id: 0x0102_0304_0506_0708, number: 5, isFinal: true, contents: Data([9]))

        XCTAssertEqual(
            Array(fragment.encoded),
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x80, 0x05, 9]
        )
        XCTAssertEqual(try MoshFragment.decode(fragment.encoded), fragment)
    }

    /// The number is fifteen bits because the sixteenth is the final flag, so a
    /// number that would overflow into it has to be impossible to construct.
    func testTheFinalBitAndTheNumberDoNotOverlap() throws {
        let last = MoshFragment(id: 1, number: 0x7FFF, isFinal: false, contents: Data())

        let decoded = try MoshFragment.decode(last.encoded)
        XCTAssertEqual(decoded.number, 0x7FFF)
        XCTAssertFalse(decoded.isFinal)
    }

    func testAFragmentWithoutItsHeaderIsRefused() {
        XCTAssertThrowsError(try MoshFragment.decode(Data(count: 9))) {
            XCTAssertEqual($0 as? MoshProtocolError, .fragmentWithoutHeader)
        }
    }

    // MARK: - Assembly

    func testFragmentsInOrderAssembleWhenTheLastOneArrives() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNil(try assembly.add(MoshFragment(id: 7, number: 0, isFinal: false, contents: Data([1, 2]))))
        XCTAssertNil(try assembly.add(MoshFragment(id: 7, number: 1, isFinal: false, contents: Data([3, 4]))))
        let whole = try assembly.add(MoshFragment(id: 7, number: 2, isFinal: true, contents: Data([5])))

        XCTAssertEqual(whole, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(assembly.largestAssembly, 3)
    }

    /// UDP reorders, so the final fragment arriving first must not complete
    /// anything, and the total it announces has to be remembered.
    func testFragmentsOutOfOrderStillAssemble() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNil(try assembly.add(MoshFragment(id: 1, number: 2, isFinal: true, contents: Data([5]))))
        XCTAssertNil(try assembly.add(MoshFragment(id: 1, number: 1, isFinal: false, contents: Data([3, 4]))))
        let whole = try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([1, 2])))

        XCTAssertEqual(whole, Data([1, 2, 3, 4, 5]))
    }

    /// A retransmission is normal: the sender reuses the id while the
    /// instruction is unchanged. It must not be counted twice, and it must not
    /// deliver the instruction a second time — which is where we part company
    /// with mosh, because inflating a full-screen repaint again is work a peer
    /// could ask for at will.
    func testARetransmissionNeitherCountsTwiceNorDeliversTwice() throws {
        let assembly = MoshFragmentAssembly()

        _ = try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([1])))
        XCTAssertNil(try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([1]))))
        let whole = try assembly.add(MoshFragment(id: 1, number: 1, isFinal: true, contents: Data([2])))
        XCTAssertEqual(whole, Data([1, 2]))

        XCTAssertNil(
            try assembly.add(MoshFragment(id: 1, number: 1, isFinal: true, contents: Data([2]))),
            "the instruction was delivered a second time"
        )
        XCTAssertEqual(assembly.conflictingFragments, 0)
    }

    /// The counter that checks what the "deliver once" rule relies on: the
    /// sender never reusing an id for different bytes. It should stay at zero
    /// against a real server, and the lab asserts that it does.
    func testAFragmentThatContradictsOneWeHoldIsCounted() throws {
        let assembly = MoshFragmentAssembly()

        _ = try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([1])))
        _ = try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([99])))

        XCTAssertEqual(assembly.conflictingFragments, 1)
    }

    /// A new id means the sender has moved on, so what was half-assembled is of
    /// no use to anybody.
    func testANewIdAbandonsWhatWasHalfAssembled() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNil(try assembly.add(MoshFragment(id: 1, number: 0, isFinal: false, contents: Data([1]))))
        let whole = try assembly.add(MoshFragment(id: 2, number: 0, isFinal: true, contents: Data([2])))

        XCTAssertEqual(whole, Data([2]), "the old instruction's bytes leaked into the new one")
    }

    /// Nine fragments is not a round number: it is what a 240x70 screen painted
    /// with random bytes took on Android, and the size the assembly has to grow
    /// to from its eight initial slots.
    func testNineFragmentsAssemble() throws {
        let assembly = MoshFragmentAssembly()
        let pieces = (0..<9).map { Data(repeating: UInt8($0), count: 100) }

        for (index, piece) in pieces.enumerated() where index < 8 {
            XCTAssertNil(try assembly.add(MoshFragment(id: 3, number: index, isFinal: false, contents: piece)))
        }
        let whole = try assembly.add(MoshFragment(id: 3, number: 8, isFinal: true, contents: pieces[8]))

        XCTAssertEqual(whole?.count, 900)
        XCTAssertEqual(whole, pieces.reduce(Data(), +))
        XCTAssertEqual(assembly.largestAssembly, 9)
    }

    /// **A count of fragments is not the same as having them**, which is
    /// Android's `e7bf644` and was a crash here rather than an exception.
    ///
    /// Fragment 2 of an unknown total, then a fragment numbered 1 that says it
    /// is the last: two arrived out of two, with nothing in slot 0. The old code
    /// then force-unwrapped that slot. It needs a peer holding the session key,
    /// so a broken or hostile server rather than the network.
    func testACountThatAddsUpOverAHoleIsRefused() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNil(try assembly.add(MoshFragment(id: 9, number: 2, isFinal: false, contents: Data([3]))))

        XCTAssertThrowsError(
            try assembly.add(MoshFragment(id: 9, number: 1, isFinal: true, contents: Data([2])))
        ) {
            XCTAssertEqual($0 as? MoshProtocolError, .fragmentPastTheLastOne(id: 9, number: 2))
        }
    }

    /// The last fragment is the only thing that can contradict itself, because
    /// it is what says how many there are.
    func testTwoDifferentLastFragmentsAreRefused() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNotNil(try assembly.add(MoshFragment(id: 1, number: 0, isFinal: true, contents: Data([1]))))

        XCTAssertThrowsError(
            try assembly.add(MoshFragment(id: 1, number: 1, isFinal: true, contents: Data([2])))
        ) {
            XCTAssertEqual($0 as? MoshProtocolError, .contradictoryLastFragment(id: 1))
        }
    }

    func testAFragmentPastAKnownLastOneIsRefused() throws {
        let assembly = MoshFragmentAssembly()

        XCTAssertNil(try assembly.add(MoshFragment(id: 2, number: 1, isFinal: true, contents: Data([2]))))

        XCTAssertThrowsError(
            try assembly.add(MoshFragment(id: 2, number: 5, isFinal: false, contents: Data([6])))
        ) {
            XCTAssertEqual($0 as? MoshProtocolError, .fragmentPastTheLastOne(id: 2, number: 5))
        }
    }

    /// The ceiling on a decompressed instruction applies after assembly, and
    /// with fifteen bits of fragment numbers there is room for many times that
    /// much to sit waiting for a last fragment that never comes.
    func testPiecesWaitingForeverHaveACeiling() throws {
        let assembly = MoshFragmentAssembly()
        let piece = Data(repeating: 0x41, count: 1 << 20)

        for number in 0..<4 {
            XCTAssertNil(
                try assembly.add(MoshFragment(id: 3, number: number, isFinal: false, contents: piece)),
                "fragment \(number) completed an instruction that has no last fragment"
            )
        }

        XCTAssertThrowsError(
            try assembly.add(MoshFragment(id: 3, number: 4, isFinal: false, contents: piece))
        ) {
            guard case MoshProtocolError.unassembledTooLarge = $0 else {
                return XCTFail("refused for the wrong reason: \($0)")
            }
        }
    }

    // MARK: - Fragmenting

    func testASmallInstructionIsOneFragment() throws {
        let fragmenter = MoshFragmenter()

        let fragments = try fragmenter.fragments(of: MoshInstruction(), budget: 1224)

        XCTAssertEqual(fragments.count, 1)
        XCTAssertTrue(fragments[0].isFinal)
        XCTAssertEqual(fragments[0].number, 0)
    }

    func testABigInstructionIsSplitAtTheBudgetAndComesBackWhole() throws {
        let fragmenter = MoshFragmenter()
        var instruction = MoshInstruction()
        // Random, so zlib cannot shrink it away and the split really happens.
        instruction.diff = Data((0..<4000).map { _ in UInt8.random(in: 0...255) })

        let fragments = try fragmenter.fragments(of: instruction, budget: 300)

        XCTAssertGreaterThan(fragments.count, 3)
        XCTAssertTrue(fragments.allSatisfy { $0.contents.count <= 300 - MoshFragment.headerLength })
        XCTAssertTrue(fragments.last!.isFinal)
        XCTAssertEqual(fragments.map(\.number), Array(0..<fragments.count))
        XCTAssertEqual(Set(fragments.map(\.id)).count, 1)

        let assembly = MoshFragmentAssembly()
        var assembled: Data?
        for fragment in fragments { assembled = try assembly.add(fragment) ?? assembled }
        XCTAssertEqual(assembled, try instruction.encoded)
    }

    /// The id advances when the bytes change and only then: that is what tells
    /// the far end a retransmission from a new instruction. It has to be the
    /// whole payload and not the state numbers, because the random chaff makes
    /// two otherwise identical instructions different on the wire.
    func testTheIdAdvancesOnlyWhenTheBytesChange() throws {
        let fragmenter = MoshFragmenter()
        var instruction = MoshInstruction()
        instruction.diff = Data([1, 2, 3])

        let first = try fragmenter.fragments(of: instruction, budget: 1224)
        let again = try fragmenter.fragments(of: instruction, budget: 1224)
        XCTAssertEqual(first[0].id, again[0].id, "a retransmission looked like a new instruction")

        instruction.newNumber = 1
        let changed = try fragmenter.fragments(of: instruction, budget: 1224)
        XCTAssertNotEqual(again[0].id, changed[0].id, "a new instruction reused an id")
    }

    /// A budget with no room for a payload is our bug, not the network's, so it
    /// says so instead of producing an endless list of empty fragments.
    func testABudgetWithNoRoomIsRefused() {
        let fragmenter = MoshFragmenter()

        XCTAssertThrowsError(try fragmenter.fragments(of: MoshInstruction(), budget: 10)) {
            XCTAssertEqual($0 as? MoshProtocolError, .noRoomForAFragment(10))
        }
    }
}
