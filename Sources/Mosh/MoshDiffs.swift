// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two state diffs that travel inside an instruction.
///
/// Both are a repeated `Instruction` in field 1, and each of those carries
/// exactly one proto2 extension — on the wire simply a nested message under its
/// own field number. Our client writes the one going up and reads the one
/// coming down; it never has to *compute* a screen diff, which is the server's
/// job and the larger half of mosh.
enum MoshDiffs {

    /// One step of what the user did, in the order it happened.
    enum UserAction: Equatable {
        /// Bytes typed, exactly as they should reach the pty — escape
        /// sequences included.
        case keystrokes(Data)
        case resize(width: Int, height: Int)
    }

    /// One step of what the host did.
    enum HostAction: Equatable {
        /// Terminal output to feed to the emulator. Applying it can produce a
        /// reply — device status and identification answers — and that reply
        /// has to go back as ``UserAction/keystrokes(_:)``, not into a
        /// discarded buffer.
        case hostBytes(Data)
        case resize(width: Int, height: Int)
        /// For predictive echo only; read and ignored until there is a
        /// prediction engine, which is phase 7 and may be never.
        case echoAck(UInt64)
    }

    static func encodeUserDiff(_ actions: [UserAction]) -> Data {
        let message = ProtoWriter()
        for action in actions {
            let instruction = ProtoWriter()
            switch action {
            case .keystrokes(let keys):
                let inner = ProtoWriter().bytes(Field.keys, keys).data
                instruction.bytes(Field.keystroke, inner)
            case .resize(let width, let height):
                instruction.bytes(Field.userResize, encodeResize(width: width, height: height))
            }
            message.bytes(Field.instruction, instruction.data)
        }
        return message.data
    }

    static func decodeHostDiff(_ diff: Data) throws -> [HostAction] {
        var out: [HostAction] = []

        let outer = ProtoReader(diff)
        try outer.forEachField { field, wireType in
            guard field == Field.instruction, wireType == ProtoWire.bytes else {
                try outer.skip(wireType: wireType)
                return
            }
            let instruction = ProtoReader(try outer.readBytes())
            try instruction.forEachField { ext, extWireType in
                switch (ext, extWireType) {
                case (Field.hostBytes, ProtoWire.bytes):
                    if let bytes = try readHostBytes(instruction.readBytes()) {
                        out.append(.hostBytes(bytes))
                    }
                case (Field.hostResize, ProtoWire.bytes):
                    out.append(try readResize(instruction.readBytes()))
                case (Field.echoAck, ProtoWire.bytes):
                    out.append(.echoAck(try readEchoAck(instruction.readBytes())))
                default:
                    // A future mosh may add an extension; ignoring it is better
                    // than refusing the frame, which would lose the screen for
                    // the sake of a field we do not need.
                    try instruction.skip(wireType: extWireType)
                }
            }
        }
        return out
    }

    // MARK: - The nested messages

    private static func encodeResize(width: Int, height: Int) -> Data {
        ProtoWriter()
            .varint(Field.width, UInt64(width))
            .varint(Field.height, UInt64(height))
            .data
    }

    private static func readHostBytes(_ body: Data) throws -> Data? {
        var bytes: Data?
        let reader = ProtoReader(body)
        try reader.forEachField { field, wireType in
            if field == Field.hostString, wireType == ProtoWire.bytes {
                bytes = try reader.readBytes()
            } else {
                try reader.skip(wireType: wireType)
            }
        }
        return bytes
    }

    private static func readResize(_ body: Data) throws -> HostAction {
        var width = 0
        var height = 0
        let reader = ProtoReader(body)
        try reader.forEachField { field, wireType in
            switch (field, wireType) {
            case (Field.width, ProtoWire.varint):
                width = Int(truncatingIfNeeded: try reader.readVarint())
            case (Field.height, ProtoWire.varint):
                height = Int(truncatingIfNeeded: try reader.readVarint())
            default:
                try reader.skip(wireType: wireType)
            }
        }
        return .resize(width: width, height: height)
    }

    private static func readEchoAck(_ body: Data) throws -> UInt64 {
        var number: UInt64 = 0
        let reader = ProtoReader(body)
        try reader.forEachField { field, wireType in
            if field == Field.echoAckNumber, wireType == ProtoWire.varint {
                number = try reader.readVarint()
            } else {
                try reader.skip(wireType: wireType)
            }
        }
        return number
    }

    private enum Field {
        static let instruction = 1

        // Client to server: ClientBuffers.
        static let keystroke = 2
        static let userResize = 3
        static let keys = 4

        // Server to client: HostBuffers.
        static let hostBytes = 2
        static let hostResize = 3
        static let hostString = 4
        static let echoAck = 7
        static let echoAckNumber = 8

        // Shared by both resize messages.
        static let width = 5
        static let height = 6
    }
}
