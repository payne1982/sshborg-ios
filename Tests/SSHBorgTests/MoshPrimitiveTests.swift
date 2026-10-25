// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// Phase 0 of the mosh plan: the two primitives the protocol needs and the
/// platform does not give us, answered with numbers rather than with a reading.
///
/// Android's mosh runs on BouncyCastle's `OCBBlockCipher` and
/// `java.util.zip.Inflater`. Neither has an equivalent here — CryptoKit does
/// AES-GCM and not OCB, and `Compression` does raw DEFLATE and not the zlib
/// wrapper mosh sends — while everything else in that package is plain logic
/// that translates. So these two were the only things that could still have
/// cost real work, and this is where they stop being a question.
///
/// The vectors are RFC 7253's own, read from the RFC rather than remembered:
/// the appendix's first, second, fifth and eighth tuples, which are an empty
/// message, a partial block, exactly one block, and one and a half. Four
/// lengths because OCB's awkwardness is all at the edges — the final partial
/// block is what a wrong implementation gets wrong, and an empty plaintext is
/// tag-only.
final class MoshPrimitiveTests: XCTestCase {

    // MARK: - AES-128-OCB

    private static let key = Data(hex("000102030405060708090A0B0C0D0E0F"))

    private struct Vector {
        let nonce: Data
        let aad: Data
        let plaintext: Data
        let sealed: Data
    }

    private static let vectors: [Vector] = [
        Vector(
            nonce: Data(hex("BBAA99887766554433221100")),
            aad: Data(),
            plaintext: Data(),
            sealed: Data(hex("785407BFFFC8AD9EDCC5520AC9111EE6"))
        ),
        Vector(
            nonce: Data(hex("BBAA99887766554433221101")),
            aad: Data(hex("0001020304050607")),
            plaintext: Data(hex("0001020304050607")),
            sealed: Data(hex("6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009"))
        ),
        Vector(
            nonce: Data(hex("BBAA99887766554433221104")),
            aad: Data(hex("000102030405060708090A0B0C0D0E0F")),
            plaintext: Data(hex("000102030405060708090A0B0C0D0E0F")),
            sealed: Data(hex("571D535B60B277188BE5147170A9A22C3AD7A4FF3835B8C5701C1CCEC8FC3358"))
        ),
        Vector(
            nonce: Data(hex("BBAA99887766554433221107")),
            aad: Data(hex("000102030405060708090A0B0C0D0E0F1011121314151617")),
            plaintext: Data(hex("000102030405060708090A0B0C0D0E0F1011121314151617")),
            sealed: Data(hex(
                "1CA2207308C87C010756104D8840CE1952F09673A448A122"
                + "C92C62241051F57356D7F3C90BB0E07F"
            ))
        ),
    ]

    func testSealingReproducesTheRFCVectors() throws {
        for (index, vector) in Self.vectors.enumerated() {
            let sealed = try MoshOCB.seal(
                plaintext: vector.plaintext,
                aad: vector.aad,
                key: Self.key,
                nonce: vector.nonce
            )
            XCTAssertEqual(sealed, vector.sealed, "vector \(index): \(Self.hexText(sealed))")
        }
    }

    func testOpeningTheRFCVectorsGivesThePlaintextBack() throws {
        for (index, vector) in Self.vectors.enumerated() {
            let opened = try MoshOCB.open(
                sealed: vector.sealed,
                aad: vector.aad,
                key: Self.key,
                nonce: vector.nonce
            )
            XCTAssertEqual(opened, vector.plaintext, "vector \(index)")
        }
    }

    /// The half that matters more than the other: a datagram somebody has
    /// touched must not open. The ciphertext, the associated data — which is
    /// where mosh's sequence number travels — and the nonce, each bent by one
    /// bit, must all three come back as nothing.
    func testATamperedDatagramDoesNotOpen() throws {
        let vector = Self.vectors[3]

        var bentBody = Data(vector.sealed)
        bentBody[5] ^= 0x01
        XCTAssertNil(
            try MoshOCB.open(sealed: bentBody, aad: vector.aad, key: Self.key, nonce: vector.nonce),
            "a flipped ciphertext byte authenticated"
        )

        var bentTag = Data(vector.sealed)
        bentTag[bentTag.count - 1] ^= 0x01
        XCTAssertNil(
            try MoshOCB.open(sealed: bentTag, aad: vector.aad, key: Self.key, nonce: vector.nonce),
            "a flipped tag byte authenticated"
        )

        var bentAAD = Data(vector.aad)
        bentAAD[0] ^= 0x01
        XCTAssertNil(
            try MoshOCB.open(sealed: vector.sealed, aad: bentAAD, key: Self.key, nonce: vector.nonce),
            "a flipped associated-data byte authenticated"
        )

        XCTAssertNil(
            try MoshOCB.open(
                sealed: vector.sealed,
                aad: vector.aad,
                key: Self.key,
                nonce: Data(Self.hex("BBAA99887766554433221108"))
            ),
            "the wrong nonce authenticated"
        )
    }

    /// Interoperability is a round trip through *our* code too, not only
    /// against four fixed vectors: the lengths that matter are 0, 1, 15, 16, 17
    /// and a whole screen, because that is where the block edges are.
    func testEveryAwkwardLengthSurvivesARoundTrip() throws {
        let nonce = Data(Self.hex("BBAA99887766554433221100"))
        for length in [0, 1, 15, 16, 17, 31, 32, 1280] {
            let plaintext = Data((0..<length).map { UInt8($0 % 251) })
            let sealed = try MoshOCB.seal(
                plaintext: plaintext, aad: Data([0xAA, 0xBB]), key: Self.key, nonce: nonce
            )
            XCTAssertEqual(sealed.count, length + MoshOCB.tagLength, "length \(length)")

            let opened = try MoshOCB.open(
                sealed: sealed, aad: Data([0xAA, 0xBB]), key: Self.key, nonce: nonce
            )
            XCTAssertEqual(opened, plaintext, "length \(length)")
        }
    }

    // MARK: - The zlib payload

    /// The fixture is a 24-row repaint — absolute cursor moves, colour changes
    /// and runs of the same character, which is the shape of what mosh sends —
    /// compressed by zlib itself, so this is the real format and not our idea
    /// of it.
    func testAZlibPayloadInflatesAndItsChecksumAgrees() throws {
        let expected = Self.repaint
        XCTAssertEqual(expected.count, 1492, "the fixture was built differently")

        let frame = try XCTUnwrap(Data(base64Encoded: Self.compressedRepaint))
        XCTAssertEqual(frame.count, 189)
        XCTAssertEqual(Array(frame.prefix(2)), [0x78, 0x9C], "not a zlib stream")

        XCTAssertEqual(try MoshDeflate.inflate(frame), expected)
        XCTAssertEqual(MoshDeflate.adler32(expected), 0x55BA_2F27, "not zlib's checksum")
    }

    /// Fragments put back in the wrong order inflate to something, or to
    /// nothing, but not to a payload whose checksum is the one in the frame.
    /// That is the property the fragment assembly will rely on, so it is held
    /// here rather than assumed there.
    func testAFrameWhoseChecksumDisagreesIsRefused() throws {
        var frame = try XCTUnwrap(Data(base64Encoded: Self.compressedRepaint))
        // The trailer, not the body: a bent body usually fails to inflate at
        // all, which would prove the wrong thing.
        frame[frame.count - 1] ^= 0x01

        XCTAssertThrowsError(try MoshDeflate.inflate(frame)) { error in
            guard case MoshDeflate.Failure.checksumMismatch(let expected, let got) = error else {
                return XCTFail("refused for the wrong reason: \(error)")
            }
            XCTAssertEqual(expected, 0x55BA_2F26)
            XCTAssertEqual(got, 0x55BA_2F27)
        }
    }

    func testSomethingThatIsNotAZlibStreamIsRefusedBeforeInflating() {
        XCTAssertThrowsError(try MoshDeflate.inflate(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .notZlib)
        }
        XCTAssertThrowsError(try MoshDeflate.inflate(Data([0x78]))) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .notZlib)
        }
    }

    /// The ceiling exists because a peer decides how far its own payload
    /// expands. 189 bytes that want 1492 are refused by a limit of 1000 rather
    /// than quietly allocating whatever it takes.
    ///
    /// This one found a real defect rather than confirming anything: it failed
    /// with `checksumMismatch`, because `compression_decode_buffer` had filled
    /// the 1000 bytes it was given and called that success, and the checksum
    /// was then quite right to refuse the truncation. The cure and the
    /// reasoning are in the inflater; what it means here is that a frame
    /// needing a bigger buffer now gets one instead of being called corrupt.
    func testAPayloadLargerThanTheLimitIsRefused() {
        let frame = Data(base64Encoded: Self.compressedRepaint)!
        XCTAssertThrowsError(try MoshDeflate.inflate(frame, limit: 1000)) {
            XCTAssertEqual($0 as? MoshDeflate.Failure, .tooLarge)
        }
    }

    /// The other side of the same coin: a payload far bigger than the first
    /// guess must inflate, not be refused. A hundred thousand identical bytes
    /// compress 826 to 1, so the opening guess of four kilobytes is five
    /// doublings short — which is exactly the path that was broken until the
    /// test above said so. Fast bulk output really does look like this.
    func testAPayloadThatOutgrowsTheFirstGuessStillInflates() throws {
        let frame = try XCTUnwrap(Data(base64Encoded: Self.compressedRun))

        let inflated = try MoshDeflate.inflate(frame)

        XCTAssertEqual(inflated.count, 100_000)
        XCTAssertEqual(inflated, Data(repeating: 0x2D, count: 100_000))
        XCTAssertEqual(MoshDeflate.adler32(inflated), 0x637FAE1D)
    }

    // MARK: - Fixtures

    private static func hex(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private static func hexText(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    /// Built rather than embedded, so what it is stays readable: home, clear,
    /// then twenty-four absolutely positioned coloured rows.
    private static var repaint: Data {
        var text = "\u{1B}[H\u{1B}[2J"
        for row in 1...24 {
            text += "\u{1B}[\(row);1H\u{1B}[0;3\(row % 8)m"
            text += String(format: "line %2d ", row)
            text += String(repeating: "-", count: 40)
        }
        text += "\u{1B}[1;1H"
        return Data(text.utf8)
    }

    /// `zlib.compress()` of a hundred thousand hyphens, which is what fast
    /// bulk output compresses like.
    private static let compressedRun =
        "eJztwTEBAAAAwqBE61/PGh5AAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAK8GY3+u"
        + "HQ=="

    /// `zlib.compress()` of the above, which is the call mosh makes.
    private static let compressedRepaint = """
        eJyV1LsNwzAUQ9FB3HiBACL1s+EFgqzgOkWAJPuXcfFewypUpeaouYSW876cfCwnDly3clR83q/v\
        c12x3v481wOJGZgGrolr4GrglrgFbgbuiXvgbuCReAQeBp6JZ+Bp4C1xCbwZeNfOu4FRJDSKoyGl\
        4WwMlNRwRoYqreGsDE1iw5kZutSGszMMyQ1naJjSG87SsGlvZ2rYtbezNRbpTWdrhPSm9Z9RetPZ\
        Gqv0prM1NulNa2sX/gFVui8n
        """
}
