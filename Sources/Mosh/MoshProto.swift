// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Just enough protocol-buffer wire format for mosh's messages.
///
/// Mosh's `.proto` files describe six messages in all, every one of them flat,
/// and the only wire types that ever appear are varint and length-delimited.
/// That is small enough to read and write by hand, which keeps a code generator
/// and a runtime library out of the build for the sake of a few hundred bytes
/// of parsing. The field numbers are in Android's `docs/mosh-wire-format.md`
/// §§2-3, which is the specification this was written from.
///
/// Unknown fields are skipped rather than refused: that is how protocol buffers
/// are meant to behave, and it is what would let a future mosh add something
/// without breaking us.
final class ProtoReader {

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var hasMore: Bool { offset < bytes.count }

    func readTag() throws -> Int {
        Int(truncatingIfNeeded: try readVarint())
    }

    func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw MoshProtocolError.varintPastTheEnd }
            guard shift <= 63 else { throw MoshProtocolError.varintTooLong }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    func readBytes() throws -> Data {
        let length = try readVarint()
        guard length <= UInt64(bytes.count - offset) else {
            throw MoshProtocolError.fieldDoesNotFit(Int(clamping: length))
        }
        let end = offset + Int(length)
        defer { offset = end }
        return Data(bytes[offset..<end])
    }

    func skip(wireType: Int) throws {
        switch wireType {
        case ProtoWire.varint: _ = try readVarint()
        case ProtoWire.bytes: _ = try readBytes()
        case ProtoWire.fixed64: try advance(8)
        case ProtoWire.fixed32: try advance(4)
        default: throw MoshProtocolError.unknownWireType(wireType)
        }
    }

    private func advance(_ count: Int) throws {
        guard offset + count <= bytes.count else { throw MoshProtocolError.fixedFieldPastTheEnd }
        offset += count
    }

    /// Walks every field in order, handing the caller the field number and its
    /// wire type. The caller reads what it wants and skips the rest.
    func forEachField(_ body: (_ field: Int, _ wireType: Int) throws -> Void) throws {
        while hasMore {
            let tag = try readTag()
            try body(tag >> 3, tag & 0x7)
        }
    }
}

final class ProtoWriter {

    private var out = Data()

    @discardableResult
    func varint(_ field: Int, _ value: UInt64) -> ProtoWriter {
        tag(field, ProtoWire.varint)
        put(value)
        return self
    }

    @discardableResult
    func bytes(_ field: Int, _ value: Data) -> ProtoWriter {
        tag(field, ProtoWire.bytes)
        put(UInt64(value.count))
        out.append(value)
        return self
    }

    var data: Data { out }

    private func tag(_ field: Int, _ wireType: Int) {
        put(UInt64(field << 3 | wireType))
    }

    private func put(_ value: UInt64) {
        var remaining = value
        while remaining & ~0x7F != 0 {
            out.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining))
    }
}

enum ProtoWire {
    static let varint = 0
    static let fixed64 = 1
    static let bytes = 2
    static let fixed32 = 5
}
