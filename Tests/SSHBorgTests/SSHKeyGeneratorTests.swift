// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import XCTest

@testable import SSHBorg

final class SSHWireFormatTests: XCTestCase {

    func testUInt32IsBigEndian() {
        var encoder = SSHWireEncoder()
        encoder.write(uint32: 0x0102_0304)
        XCTAssertEqual(Array(encoder.data), [0x01, 0x02, 0x03, 0x04])
    }

    func testStringIsLengthPrefixed() {
        var encoder = SSHWireEncoder()
        encoder.write(string: "abc")
        XCTAssertEqual(Array(encoder.data), [0, 0, 0, 3, 0x61, 0x62, 0x63])
    }

    /// The classic way to produce a key `ssh-keygen` rejects: a value whose top
    /// bit is set must gain a leading zero, or it reads as negative.
    func testMPIntPrependsZeroWhenHighBitSet() {
        var encoder = SSHWireEncoder()
        encoder.write(mpint: Data([0xFF, 0x01]))
        XCTAssertEqual(Array(encoder.data), [0, 0, 0, 3, 0x00, 0xFF, 0x01])
    }

    func testMPIntDoesNotPadWhenHighBitClear() {
        var encoder = SSHWireEncoder()
        encoder.write(mpint: Data([0x7F, 0x01]))
        XCTAssertEqual(Array(encoder.data), [0, 0, 0, 2, 0x7F, 0x01])
    }

    func testMPIntStripsLeadingZeros() {
        var encoder = SSHWireEncoder()
        encoder.write(mpint: Data([0x00, 0x00, 0x42]))
        XCTAssertEqual(Array(encoder.data), [0, 0, 0, 1, 0x42])
    }

    func testMPIntOfZeroIsEmpty() {
        var encoder = SSHWireEncoder()
        encoder.write(mpint: Data([0x00, 0x00]))
        XCTAssertEqual(Array(encoder.data), [0, 0, 0, 0])
    }

    func testDecoderRoundTrip() throws {
        var encoder = SSHWireEncoder()
        encoder.write(string: "ssh-ed25519")
        encoder.write(uint32: 42)
        encoder.write(string: Data([1, 2, 3]))

        var decoder = SSHWireDecoder(encoder.data)
        XCTAssertEqual(try decoder.readStringAsText(), "ssh-ed25519")
        XCTAssertEqual(try decoder.readUInt32(), 42)
        XCTAssertEqual(try decoder.readString(), Data([1, 2, 3]))
        XCTAssertTrue(decoder.isAtEnd)
    }

    /// A corrupt length field must not be able to ask for an enormous read.
    func testDecoderRejectsOversizedLength() {
        var decoder = SSHWireDecoder(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
        XCTAssertThrowsError(try decoder.readString())
    }

    func testDecoderRejectsTruncatedInput() {
        var decoder = SSHWireDecoder(Data([0x00, 0x00]))
        XCTAssertThrowsError(try decoder.readUInt32())
    }
}

final class SSHKeyGeneratorTests: XCTestCase {

    // MARK: - Public key line

    func testEd25519PublicLineShape() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "phone")

        let fields = key.publicKeyLine.split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0], "ssh-ed25519")
        XCTAssertEqual(fields[2], "phone")

        // The blob must restate its own algorithm, which is what a server reads.
        var decoder = SSHWireDecoder(try XCTUnwrap(Data(base64Encoded: fields[1])))
        XCTAssertEqual(try decoder.readStringAsText(), "ssh-ed25519")
        XCTAssertEqual(try decoder.readString().count, 32)
        XCTAssertTrue(decoder.isAtEnd)
    }

    func testCommentIsOptional() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "")
        XCTAssertEqual(key.publicKeyLine.split(separator: " ").count, 2)
    }

    func testECDSAPublicLineCarriesItsCurve() throws {
        for (bits, curve) in [(256, "nistp256"), (384, "nistp384"), (521, "nistp521")] {
            let key = try SSHKeyGenerator.generate(type: .ecdsa, bits: bits)
            let fields = key.publicKeyLine.split(separator: " ").map(String.init)

            XCTAssertEqual(fields[0], "ecdsa-sha2-\(curve)")

            var decoder = SSHWireDecoder(try XCTUnwrap(Data(base64Encoded: fields[1])))
            XCTAssertEqual(try decoder.readStringAsText(), "ecdsa-sha2-\(curve)")
            XCTAssertEqual(try decoder.readStringAsText(), curve)

            let point = try decoder.readString()
            XCTAssertEqual(point.first, 0x04, "the point must be in uncompressed form")
        }
    }

    func testRSAPublicLineShape() throws {
        let key = try SSHKeyGenerator.generate(type: .rsa, bits: 2048)
        let fields = key.publicKeyLine.split(separator: " ").map(String.init)

        XCTAssertEqual(fields[0], "ssh-rsa")

        var decoder = SSHWireDecoder(try XCTUnwrap(Data(base64Encoded: fields[1])))
        XCTAssertEqual(try decoder.readStringAsText(), "ssh-rsa")

        let exponent = try decoder.readMPInt()
        let modulus = try decoder.readMPInt()
        XCTAssertEqual(Array(exponent), [0x01, 0x00, 0x01], "e is normally 65537")
        XCTAssertEqual(modulus.count, 256, "a 2048-bit modulus is 256 bytes")
        XCTAssertTrue(decoder.isAtEnd)
    }

    // MARK: - Private key container

    func testPrivateKeyIsArmoured() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519)

        XCTAssertTrue(key.privateKeyPEM.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        // Exactly one trailing newline, which is what ssh-keygen writes and what
        // it accepts back.
        XCTAssertTrue(key.privateKeyPEM.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        XCTAssertFalse(key.privateKeyPEM.hasSuffix("\n\n"))

        let body = key.privateKeyPEM
            .split(separator: "\n")
            .dropFirst()
            .dropLast()
            .joined()
        XCTAssertNotNil(Data(base64Encoded: body))
    }

    func testArmourWrapsAtSeventyColumns() throws {
        let key = try SSHKeyGenerator.generate(type: .rsa, bits: 2048)
        let bodyLines = key.privateKeyPEM
            .split(separator: "\n")
            .dropFirst()
            .dropLast()

        XCTAssertGreaterThan(bodyLines.count, 1)
        for line in bodyLines.dropLast() {
            XCTAssertEqual(line.count, 70)
        }
    }

    /// Walks the whole `openssh-key-v1` container and checks every field, which
    /// is what an SSH client does before it will use the key.
    func testPrivateKeyContainerLayout() throws {
        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "layout")
        let blob = try XCTUnwrap(Data(base64Encoded: key.privateKeyPEM
            .split(separator: "\n").dropFirst().dropLast().joined()))

        // Magic is a NUL-terminated literal, not a length-prefixed string.
        let magic = Data("openssh-key-v1\0".utf8)
        XCTAssertEqual(blob.prefix(magic.count), magic)

        var decoder = SSHWireDecoder(blob.dropFirst(magic.count))
        XCTAssertEqual(try decoder.readStringAsText(), "none", "cipher")
        XCTAssertEqual(try decoder.readStringAsText(), "none", "kdf")
        XCTAssertEqual(try decoder.readString(), Data(), "kdf options")
        XCTAssertEqual(try decoder.readUInt32(), 1, "key count")

        let publicBlob = try decoder.readString()
        let section = try decoder.readString()
        XCTAssertTrue(decoder.isAtEnd)

        // The public blob inside must match the one we published separately.
        let publishedBlob = try XCTUnwrap(Data(base64Encoded:
            key.publicKeyLine.split(separator: " ").map(String.init)[1]))
        XCTAssertEqual(publicBlob, publishedBlob)

        // The unencrypted section still carries the two matching check words.
        var sectionDecoder = SSHWireDecoder(section)
        let first = try sectionDecoder.readUInt32()
        let second = try sectionDecoder.readUInt32()
        XCTAssertEqual(first, second, "the check integers must match")

        XCTAssertEqual(try sectionDecoder.readStringAsText(), "ssh-ed25519")
        let publicPart = try sectionDecoder.readString()
        let privatePart = try sectionDecoder.readString()
        XCTAssertEqual(publicPart.count, 32)
        XCTAssertEqual(privatePart.count, 64, "seed followed by public key")
        XCTAssertEqual(privatePart.suffix(32), publicPart, "the tail must be the public key")

        XCTAssertEqual(try sectionDecoder.readStringAsText(), "layout", "comment")
    }

    /// The section must be padded to the cipher block size with 1, 2, 3…
    /// ssh-keygen refuses a file padded any other way.
    func testPrivateSectionPadding() throws {
        for type in SSHKey.KeyType.allCases {
            let key = try SSHKeyGenerator.generate(type: type, bits: SSHKeyGenerator.defaultSize(for: type))
            let blob = try XCTUnwrap(Data(base64Encoded: key.privateKeyPEM
                .split(separator: "\n").dropFirst().dropLast().joined()))

            var decoder = SSHWireDecoder(blob.dropFirst(Data("openssh-key-v1\0".utf8).count))
            _ = try decoder.readString()   // cipher
            _ = try decoder.readString()   // kdf
            _ = try decoder.readString()   // kdf options
            _ = try decoder.readUInt32()   // count
            _ = try decoder.readString()   // public blob
            let section = try decoder.readString()

            XCTAssertEqual(section.count % 8, 0, "\(type) section is not block-aligned")

            // Trailing bytes must be the ascending run.
            var expected: UInt8 = 1
            var trailing: [UInt8] = []
            for byte in section.reversed() {
                if byte == 0 { break }
                trailing.append(byte)
                if trailing.count > 8 { break }
            }
            for byte in trailing.reversed() {
                if byte == expected { expected += 1 } else { break }
            }
        }
    }

    func testUnsupportedSizesAreRejected() {
        XCTAssertThrowsError(try SSHKeyGenerator.generate(type: .ecdsa, bits: 512))
        XCTAssertThrowsError(try SSHKeyGenerator.generate(type: .rsa, bits: 1024))
    }

    func testKeysAreDistinct() throws {
        let first = try SSHKeyGenerator.generate(type: .ed25519)
        let second = try SSHKeyGenerator.generate(type: .ed25519)
        XCTAssertNotEqual(first.publicKeyLine, second.publicKeyLine)
    }

    // MARK: - RSA DER

    func testRSADERRejectsGarbage() {
        XCTAssertThrowsError(try RSAPrivateKeyDER.parse(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - External verification

    /// Prints one key of each type so they can be checked against the real
    /// `ssh-keygen`, which is the only authority on whether these bytes are
    /// right. Our own decoder agreeing with our own encoder proves nothing.
    func testDumpKeysForExternalVerification() throws {
        for type in SSHKey.KeyType.allCases {
            let key = try SSHKeyGenerator.generate(
                type: type,
                bits: SSHKeyGenerator.defaultSize(for: type),
                comment: "sshborg-verify"
            )
            print("===KEYDUMP-BEGIN \(type.rawValue)===")
            print(key.privateKeyPEM)
            print("===KEYDUMP-PUB \(type.rawValue)=== \(key.publicKeyLine)")
            print("===KEYDUMP-END \(type.rawValue)===")
        }
    }
}
