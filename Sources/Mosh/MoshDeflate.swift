// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import Foundation

/// zlib, in the form mosh actually sends it.
///
/// An instruction's payload is compressed with zlib's own `compress()`, which
/// is the zlib *format* of RFC 1950: a two-byte header, raw DEFLATE, and a
/// four-byte Adler-32 of the plaintext, big-endian. Apple's `Compression`
/// framework does raw DEFLATE alone — `COMPRESSION_ZLIB` is RFC 1951, despite
/// the name — so the wrapper is ours to read, which is nine lines and one
/// checksum.
///
/// **The checksum is kept rather than skipped**, and that is the point of this
/// file existing instead of a two-line call at the use site. A frame arrives in
/// fragments, and the thing that proves they were reassembled in the right
/// order is that the plaintext hashes to the number the sender put at the end.
/// Android gets that for free from `java.util.zip.Inflater`, which checks it;
/// here nobody would check it unless we did.
enum MoshDeflate {

    enum Failure: Error, Equatable {
        /// Apple's encoder refused, or wanted more room than we were willing to
        /// try. It has never been seen; a payload only ever grows by a fraction
        /// of a per cent even when it is incompressible.
        case deflateFailed
        /// Nothing to compress. Refused rather than answered, because the
        /// stream it would produce is the one thing ``MoshDeflate/inflate(_:limit:)``
        /// cannot read back: `compression_decode_buffer` reports an empty
        /// result and a failure the same way, as zero. An instruction always
        /// carries its five numbers, so the protocol never asks.
        case nothingToDeflate
        /// Not an RFC 1950 stream: too short, or the two header bytes do not
        /// describe a deflate stream with a valid check value.
        case notZlib
        case inflateFailed
        /// Inflated past what we are willing to hold. A peer chooses how much
        /// its own payload expands to, so there has to be a ceiling.
        case tooLarge
        /// The bytes came back, and they are not the bytes that were sent.
        case checksumMismatch(expected: UInt32, got: UInt32)
    }

    /// A screen's worth of escape sequences is kilobytes; a megabyte is already
    /// far more than mosh has any reason to send, and small enough that holding
    /// one while it is checked costs nothing.
    static let defaultLimit = 1 << 20

    /// Inflates a complete zlib stream and verifies its Adler-32.
    static func inflate(_ frame: Data, limit: Int = defaultLimit) throws -> Data {
        guard frame.count >= 2 + 4 else { throw Failure.notZlib }

        // RFC 1950 §2.2: the low nibble of the first byte is the compression
        // method, which must be 8, and the two header bytes read as a
        // big-endian number must be a multiple of 31.
        let first = frame[frame.startIndex]
        let second = frame[frame.startIndex + 1]
        guard first & 0x0F == 8, (UInt16(first) << 8 | UInt16(second)) % 31 == 0 else {
            throw Failure.notZlib
        }

        let deflated = Data(frame.dropFirst(2).dropLast(4))
        let expected = frame.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        // A zlib stream does not carry its uncompressed size, so the only way
        // to size the destination is to try one and grow it. Doubling from a
        // guess that is generous for a screen repaint means the common case
        // inflates once; the loop exists for the frame that does not fit.
        //
        // WARNING: `compression_decode_buffer` truncates silently, measured on
        // 25/10/2026 — given 1000 bytes of room for a 1492-byte payload it
        // returns 1000 and reports success. So "it produced something" is not
        // the question; "it stopped before filling the buffer" is, because that
        // is the only sign the stream ended by itself. Without this the
        // checksum below would refuse a perfectly good frame that merely
        // needed a bigger buffer, which is a defect that reads as a corrupt
        // network.
        var capacity = min(limit, max(4096, deflated.count * 16))
        while true {
            if let inflated = Self.inflate(deflated, into: capacity), inflated.count < capacity {
                let got = adler32(inflated)
                guard got == expected else {
                    throw Failure.checksumMismatch(expected: expected, got: got)
                }
                return inflated
            }
            guard capacity < limit else { throw Failure.tooLarge }
            capacity = min(limit, capacity * 2)
        }
    }

    /// `nil` when the destination was too small *or* the stream was corrupt:
    /// `compression_decode_buffer` does not tell the two apart, which is why
    /// the caller grows the buffer before giving up.
    private static func inflate(_ deflated: Data, into capacity: Int) -> Data? {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = deflated.withUnsafeBytes { source in
            compression_decode_buffer(
                destination, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    /// The zlib stream mosh expects, assembled around Apple's raw DEFLATE: the
    /// two-byte header, the deflate data, and the Adler-32 of the *input*,
    /// big-endian.
    ///
    /// `0x78 0x9C` is what zlib itself writes at its default level, and the
    /// FLEVEL bits in it are informational — an inflater reads the method and
    /// the check value and ignores the rest.
    static func deflate(_ raw: Data) throws -> Data {
        guard !raw.isEmpty else { throw Failure.nothingToDeflate }
        var out = Data([0x78, 0x9C])

        // Even incompressible input grows by only a fraction of a per cent, so
        // the first guess is generous and the second is a formality.
        var capacity = raw.count + max(64, raw.count / 8)
        for _ in 0..<3 {
            if let deflated = Self.deflate(raw, into: capacity) {
                out.append(deflated)
                let checksum = adler32(raw)
                for shift in stride(from: 24, through: 0, by: -8) {
                    out.append(UInt8(truncatingIfNeeded: checksum >> UInt32(shift)))
                }
                return out
            }
            capacity *= 2
        }
        throw Failure.deflateFailed
    }

    private static func deflate(_ raw: Data, into capacity: Int) -> Data? {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = raw.withUnsafeBytes { source in
            compression_encode_buffer(
                destination, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    /// RFC 1950 §9. Nine lines, against a dependency for a checksum.
    static func adler32(_ data: Data) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in data {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        return (high << 16) | low
    }
}
