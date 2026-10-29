// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What sits inside the encryption: two timestamps and one fragment of an
/// instruction.
///
/// ```
/// plaintext:  timestamp[2] || timestamp_reply[2] || fragment
/// fragment:   id[8] || (final<<15 | fragment_num)[2] || payload
/// ```
///
/// Everything is big-endian.
struct MoshPacket: Equatable {

    /// The value both timestamp fields use for "nothing to say", i.e. sixteen
    /// bits of ones.
    static let none = 0xFFFF

    let timestamp: Int
    let timestampReply: Int
    let payload: Data

    init(timestamp: Int, timestampReply: Int, payload: Data) {
        self.timestamp = timestamp
        self.timestampReply = timestampReply
        self.payload = payload
    }

    var encoded: Data {
        var out = Data()
        out.appendBigEndian16(timestamp)
        out.appendBigEndian16(timestampReply)
        out.append(payload)
        return out
    }

    static func decode(_ plaintext: Data) throws -> MoshPacket {
        guard plaintext.count >= 4 else { throw MoshProtocolError.packetWithoutTimestamps }
        let bytes = [UInt8](plaintext)
        return MoshPacket(
            timestamp: Int(bytes[0]) << 8 | Int(bytes[1]),
            timestampReply: Int(bytes[2]) << 8 | Int(bytes[3]),
            payload: Data(bytes[4...])
        )
    }
}

/// One piece of an instruction.
///
/// The instruction id ties the pieces together, and the top bit of the second
/// field marks the last one — so the receiver learns the total only when that
/// one arrives, which is why assembly counts rather than preallocates.
struct MoshFragment: Equatable {

    static let headerLength = 10

    let id: UInt64
    let number: Int
    let isFinal: Bool
    let contents: Data

    init(id: UInt64, number: Int, isFinal: Bool, contents: Data) {
        precondition((0...0x7FFF).contains(number), "fragment number \(number) does not fit in 15 bits")
        self.id = id
        self.number = number
        self.isFinal = isFinal
        self.contents = contents
    }

    var encoded: Data {
        var out = Data()
        out.appendBigEndian64(id)
        out.appendBigEndian16((isFinal ? 0x8000 : 0) | number)
        out.append(contents)
        return out
    }

    static func decode(_ data: Data) throws -> MoshFragment {
        guard data.count >= headerLength else { throw MoshProtocolError.fragmentWithoutHeader }
        let bytes = [UInt8](data)
        var id: UInt64 = 0
        for index in 0..<8 { id = id << 8 | UInt64(bytes[index]) }
        let combined = Int(bytes[8]) << 8 | Int(bytes[9])
        return MoshFragment(
            id: id,
            number: combined & 0x7FFF,
            isFinal: combined & 0x8000 != 0,
            contents: Data(bytes[headerLength...])
        )
    }
}

/// Collects the fragments of one instruction.
///
/// A fragment of a different id abandons whatever was being assembled: mosh
/// does the same, because the sender has moved on and an instruction it no
/// longer sends is of no use to us. A retransmission of a fragment we already
/// hold is dropped rather than counted twice — the sender reuses the id when it
/// resends an unchanged instruction, which is what makes that case normal
/// rather than suspicious.
///
/// One deliberate difference from mosh: an assembly is handed over **once**.
/// Mosh returns the completed instruction again for every repeat of the final
/// fragment and relies on the state layer's idempotency to absorb it; ours is
/// idempotent too, but re-delivering means inflating and parsing the whole
/// instruction again on each retransmission, which for a full-screen repaint is
/// work a peer could ask for at will.
final class MoshFragmentAssembly {

    private var currentID: UInt64?
    private var arrived = 0
    private var total = -1
    private var delivered = false
    private var fragments: [MoshFragment?] = []
    private var bytesHeld = 0

    /// An instruction that went over the ceiling, whose further pieces are
    /// refused without being kept.
    private var poisonedID: UInt64?

    /// What is being held right now for an instruction nobody has finished
    /// sending. Diagnostic, and what the ceiling's test asserts on.
    var heldBytes: Int { bytesHeld }

    /// How many fragments the largest instruction we have assembled was split
    /// into.
    private(set) var largestAssembly = 0

    /// How many times a fragment arrived with an id and number we already held
    /// but **different contents**.
    ///
    /// It should never happen, and nothing here can repair it if it does: it
    /// would mean the sender reuses an id for a changed instruction, which is
    /// exactly what the "deliver once" rule above relies on it not doing.
    /// Counting it is how that reliance gets checked against a real server
    /// instead of trusted.
    private(set) var conflictingFragments = 0

    /// The complete payload once the last missing piece arrives, otherwise
    /// `nil`.
    ///
    /// Throws when the pieces contradict each other, which needs a peer holding
    /// the session key — a broken or hostile server rather than the network.
    /// Android's `e7bf644` found why that matters: **a count of fragments is not
    /// the same as having them.** The total is only known when the last fragment
    /// arrives, so completeness was checked by counting, and the count can add
    /// up over a hole — fragment 2 of an unknown total, then a fragment numbered
    /// 1 that says it is the last, gives two arrived out of two with nothing in
    /// slot 0. In Kotlin that dereferenced null; here it would have been a force
    /// unwrap, which is a crash and not an exception.
    func add(_ fragment: MoshFragment) throws -> Data? {
        // Refused outright, and before anything is kept: see the ceiling below.
        if fragment.id == poisonedID {
            throw MoshProtocolError.unassembledTooLarge(id: fragment.id, bytes: bytesHeld)
        }

        if fragment.id != currentID {
            currentID = fragment.id
            arrived = 0
            total = -1
            delivered = false
            fragments = Array(repeating: nil, count: Self.initialSlots)
            bytesHeld = 0
        }

        // The last fragment is what says how many there are, so it is also the
        // only thing that can contradict itself. Two different answers for one
        // id means the pieces on the floor belong to two instructions, and no
        // amount of waiting will make them into one.
        if fragment.isFinal {
            let announced = fragment.number + 1
            guard total < 0 || total == announced else {
                throw MoshProtocolError.contradictoryLastFragment(id: fragment.id)
            }
            total = announced
            // And a piece already held above it, which is the same contradiction
            // arriving in the other order: it was taken in while the total was
            // still unknown.
            for index in announced..<max(announced, fragments.count) where fragments[index] != nil {
                throw MoshProtocolError.fragmentPastTheLastOne(id: fragment.id, number: index)
            }
        }

        // A piece numbered past the last one. Harmless to drop, and not harmless
        // to keep: it would be counted among the pieces that have arrived while
        // the hole it does not fill stays open.
        if total >= 0, fragment.number >= total {
            throw MoshProtocolError.fragmentPastTheLastOne(id: fragment.id, number: fragment.number)
        }

        if fragment.number >= fragments.count {
            fragments += Array(
                repeating: nil,
                count: max(fragment.number + 1, fragments.count * 2) - fragments.count
            )
        }

        if let held = fragments[fragment.number] {
            if held.contents != fragment.contents { conflictingFragments += 1 }
        } else {
            // What is being held for an instruction nobody has finished sending.
            // The ceiling on a *decompressed* instruction applies after assembly,
            // and with fifteen bits of fragment numbers to fill there is room for
            // many times that much to sit here waiting for a last fragment that
            // never comes.
            //
            // Checked **before** keeping the piece, and then the whole instruction
            // is let go and its id refused. It used to be the other way round —
            // keep, count, then throw — and the caller carries on after a throw,
            // so every further piece with the same id was kept too: the ceiling
            // was a number in an error message, not a limit on memory. An audit
            // on 29/10/2026 measured it on the Android original: 5000 pieces of
            // 1100 bytes, 1187 refusals, 5.5 MB held against a 4 MB ceiling. Our
            // code was the same in the place that matters.
            //
            // It takes the session key to get here — pieces are parsed after OCB
            // — so this is a broken or hostile server, not the network.
            let afterThis = bytesHeld + fragment.contents.count
            guard afterThis <= Self.maximumHeldBytes else {
                poisonedID = fragment.id
                fragments = Array(repeating: nil, count: Self.initialSlots)
                bytesHeld = 0
                arrived = 0
                total = -1
                throw MoshProtocolError.unassembledTooLarge(id: fragment.id, bytes: afterThis)
            }
            fragments[fragment.number] = fragment
            arrived += 1
            bytesHeld = afterThis
        }

        guard total >= 0, arrived >= total, !delivered else { return nil }
        // A count of pieces is not the same as having the right ones. Every rule
        // above exists to keep those two in step; this is the one that does not
        // have to be believed.
        guard !(0..<total).contains(where: { fragments[$0] == nil }) else { return nil }
        delivered = true
        largestAssembly = max(largestAssembly, total)

        var out = Data()
        for index in 0..<total {
            out.append(fragments[index]!.contents)
        }
        return out
    }

    private static let initialSlots = 8

    /// How much unassembled payload one instruction may have waiting. An
    /// instruction is a screen's worth of differences, so this is already far
    /// above anything a real one needs, and the point is only that the number
    /// exists.
    private static let maximumHeldBytes = 4 * 1024 * 1024
}

/// Splits an instruction's compressed payload into fragments.
///
/// The id advances whenever the bytes to send differ from the last ones, and
/// only then. That is what lets the far end tell a retransmission from a new
/// instruction — and it has to be the whole payload rather than the state
/// numbers, because the random chaff makes two otherwise identical instructions
/// different on the wire. Reusing an id for different bytes would be the one
/// real hazard here: the far end would mix the fragments of two instructions
/// into one assembly.
///
/// `budget` is what is left for the fragment *including* its ten-byte header,
/// which is how mosh expresses it — the caller has already taken the nonce, the
/// timestamps and the tag out of the path MTU.
final class MoshFragmenter {

    private var nextID: UInt64 = 0
    private var lastPayload: Data?
    private var lastRoom = -1

    func fragments(of instruction: MoshInstruction, budget: Int) throws -> [MoshFragment] {
        let room = budget - MoshFragment.headerLength
        guard room > 0 else { throw MoshProtocolError.noRoomForAFragment(budget) }

        let payload = try instruction.encoded
        if payload != lastPayload || room != lastRoom { nextID += 1 }
        lastPayload = payload
        lastRoom = room

        var out: [MoshFragment] = []
        var offset = 0
        var number = 0
        repeat {
            let end = min(offset + room, payload.count)
            let isFinal = end == payload.count
            out.append(
                MoshFragment(
                    id: nextID,
                    number: number,
                    isFinal: isFinal,
                    contents: Data(payload[offset..<end])
                )
            )
            number += 1
            offset = end
        } while !out[out.count - 1].isFinal
        return out
    }
}

extension Data {

    mutating func appendBigEndian16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian64(_ value: UInt64) {
        for index in 0..<8 {
            append(UInt8(truncatingIfNeeded: value >> (56 - 8 * index)))
        }
    }
}
