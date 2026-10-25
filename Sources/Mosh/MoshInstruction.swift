// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The transport instruction: the envelope that carries one state diff and the
/// bookkeeping that makes the exchange idempotent.
///
/// ``oldNumber`` and ``newNumber`` say which state the diff goes *from* and
/// *to*, which is what lets either side skip intermediate states entirely —
/// the reason a session that was asleep for an hour repaints at once instead of
/// replaying the hour. ``ackNumber`` reports the newest state of the other
/// side's that we hold; ``throwawayNumber`` says which of ours it may forget.
///
/// The serialised message is zlib-compressed before it is fragmented, with the
/// ordinary zlib header and not a raw deflate stream — see ``MoshDeflate``,
/// where that distinction is the whole file.
struct MoshInstruction: Equatable {

    static let protocolVersion = 2

    /// Mosh's own ceiling on a decompressed instruction, and our guard against
    /// a bomb: a peer decides how far its own payload expands.
    static let maxDecompressed = 2048 * 2048

    var version = MoshInstruction.protocolVersion
    var oldNumber: UInt64 = 0
    var newNumber: UInt64 = 0
    var ackNumber: UInt64 = 0
    var throwawayNumber: UInt64 = 0
    var diff = Data()
    /// Padding of a random length, which mosh sends so that the size of a
    /// datagram cannot report how much was typed. We send it for the same
    /// reason and ignore it on the way in.
    var chaff = Data()

    var serialized: Data {
        let writer = ProtoWriter()
            .varint(Field.version, UInt64(version))
            .varint(Field.oldNumber, oldNumber)
            .varint(Field.newNumber, newNumber)
            .varint(Field.ackNumber, ackNumber)
            .varint(Field.throwawayNumber, throwawayNumber)
        if !diff.isEmpty { writer.bytes(Field.diff, diff) }
        if !chaff.isEmpty { writer.bytes(Field.chaff, chaff) }
        return writer.data
    }

    var encoded: Data {
        get throws { try MoshDeflate.deflate(serialized) }
    }

    static func decode(fragmentPayload: Data) throws -> MoshInstruction {
        try parse(MoshDeflate.inflate(fragmentPayload, limit: maxDecompressed))
    }

    static func parse(_ serialized: Data) throws -> MoshInstruction {
        var instruction = MoshInstruction()
        instruction.version = 0

        let reader = ProtoReader(serialized)
        try reader.forEachField { field, wireType in
            switch (field, wireType) {
            case (Field.version, ProtoWire.varint):
                instruction.version = Int(truncatingIfNeeded: try reader.readVarint())
            case (Field.oldNumber, ProtoWire.varint):
                instruction.oldNumber = try reader.readVarint()
            case (Field.newNumber, ProtoWire.varint):
                instruction.newNumber = try reader.readVarint()
            case (Field.ackNumber, ProtoWire.varint):
                instruction.ackNumber = try reader.readVarint()
            case (Field.throwawayNumber, ProtoWire.varint):
                instruction.throwawayNumber = try reader.readVarint()
            case (Field.diff, ProtoWire.bytes):
                instruction.diff = try reader.readBytes()
            case (Field.chaff, ProtoWire.bytes):
                // Padding: read so the parse advances, and then dropped.
                _ = try reader.readBytes()
            default:
                try reader.skip(wireType: wireType)
            }
        }

        guard instruction.version == protocolVersion else {
            // Mosh treats this as fatal rather than as something to negotiate,
            // and so must we: the state numbering *is* the protocol, and
            // guessing at a different one corrupts the screen instead of
            // failing cleanly.
            throw MoshProtocolError.protocolVersion(instruction.version)
        }
        return instruction
    }

    private enum Field {
        static let version = 1
        static let oldNumber = 2
        static let newNumber = 3
        static let ackNumber = 4
        static let throwawayNumber = 5
        static let diff = 6
        static let chaff = 7
    }
}
