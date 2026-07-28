// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Writes the binary encoding SSH uses for keys and packets (RFC 4251 §5).
///
/// Everything in an OpenSSH key file is built from three primitives: 32-bit
/// big-endian integers, length-prefixed byte strings, and multiple-precision
/// integers. Getting `mpint` wrong is the classic way to produce a key that
/// looks fine and that `ssh-keygen` rejects, so it has its own tests.
struct SSHWireEncoder {

    private(set) var data = Data()

    mutating func write(uint32 value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// A length-prefixed byte string.
    mutating func write(string bytes: Data) {
        write(uint32: UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func write(string text: String) {
        write(string: Data(text.utf8))
    }

    /// A multiple-precision integer, always positive here.
    ///
    /// Leading zero bytes are dropped, and a single `0x00` is prepended when the
    /// top bit is set — otherwise the value would read as negative in the
    /// two's-complement encoding the format specifies.
    mutating func write(mpint magnitude: Data) {
        var trimmed = magnitude.drop { $0 == 0 }

        if trimmed.isEmpty {
            write(uint32: 0)
            return
        }
        if let first = trimmed.first, first & 0x80 != 0 {
            trimmed = ([0x00] + trimmed)[...]
        }
        write(string: Data(trimmed))
    }

    mutating func write(raw bytes: Data) {
        data.append(bytes)
    }
}

/// Reads the encoding ``SSHWireEncoder`` writes.
struct SSHWireDecoder {

    enum DecodingError: Error, Equatable {
        case truncated
        case invalidLength
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.endIndex else { throw DecodingError.truncated }

        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[offset + index])
        }
        offset += 4
        return value
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())

        // A corrupt length field could otherwise ask for gigabytes.
        guard length >= 0, offset + length <= data.endIndex else {
            throw DecodingError.invalidLength
        }

        let bytes = data[offset..<(offset + length)]
        offset += length
        return Data(bytes)
    }

    mutating func readStringAsText() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// An `mpint` with the sign byte removed, so the result is the raw magnitude.
    mutating func readMPInt() throws -> Data {
        Data(try readString().drop { $0 == 0 })
    }

    mutating func readRemaining() -> Data {
        let rest = data[offset...]
        offset = data.endIndex
        return Data(rest)
    }
}
