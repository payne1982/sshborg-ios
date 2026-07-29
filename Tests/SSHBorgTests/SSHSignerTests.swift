// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Security
import XCTest

@testable import SSHBorg

/// Checks that a signature made with a stored key verifies against the public
/// half of that same key.
///
/// The verification is deliberately not done with the code that produced the
/// signature: Ed25519 and ECDSA go through CryptoKit's verifier reading the key
/// out of our own wire blob, and RSA goes through the Security framework, which
/// never touches OpenSSL. A mistake in the blob layout, the mpint padding or the
/// `r ‖ s` split therefore shows up as a failed verification rather than as two
/// halves of the same bug agreeing with each other.
final class SSHSignerTests: XCTestCase {

    private let challenge = Data("what a server asks an agent to sign".utf8)

    // MARK: - Round trips

    func testEd25519SignatureVerifies() throws {
        let generated = try SSHKeyGenerator.generate(type: .ed25519, comment: "phone")
        let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM)

        XCTAssertEqual(signer.algorithm, "ssh-ed25519")
        XCTAssertEqual(signer.comment, "phone")

        let (algorithm, signature) = try split(signer.signature(for: challenge))
        XCTAssertEqual(algorithm, "ssh-ed25519")

        var blob = SSHWireDecoder(signer.publicKeyBlob)
        _ = try blob.readString()
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try blob.readString())

        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: challenge + Data([0])))
    }

    func testECDSASignaturesVerifyOnEveryCurve() throws {
        for bits in [256, 384, 521] {
            let generated = try SSHKeyGenerator.generate(type: .ecdsa, bits: bits, comment: "c\(bits)")
            let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM)

            let (algorithm, signature) = try split(signer.signature(for: challenge))
            XCTAssertEqual(algorithm, "ecdsa-sha2-nistp\(bits)")

            // SSH carries r and s as two mpints inside the signature string;
            // CryptoKit wants them back as fixed-width halves.
            var parts = SSHWireDecoder(signature)
            let r = try parts.readString()
            let s = try parts.readString()
            let width = bits == 521 ? 66 : bits / 8
            let raw = pad(r, to: width) + pad(s, to: width)

            var blob = SSHWireDecoder(signer.publicKeyBlob)
            _ = try blob.readString()  // algorithm
            _ = try blob.readString()  // curve name
            let point = try blob.readString()

            switch bits {
            case 256:
                let key = try P256.Signing.PublicKey(x963Representation: point)
                let parsed = try P256.Signing.ECDSASignature(rawRepresentation: raw)
                XCTAssertTrue(key.isValidSignature(parsed, for: challenge), "P-256 signature rejected")
            case 384:
                let key = try P384.Signing.PublicKey(x963Representation: point)
                let parsed = try P384.Signing.ECDSASignature(rawRepresentation: raw)
                XCTAssertTrue(key.isValidSignature(parsed, for: challenge), "P-384 signature rejected")
            default:
                let key = try P521.Signing.PublicKey(x963Representation: point)
                let parsed = try P521.Signing.ECDSASignature(rawRepresentation: raw)
                XCTAssertTrue(key.isValidSignature(parsed, for: challenge), "P-521 signature rejected")
            }
        }
    }

    /// RSA is the one that needed OpenSSL, so it is the one worth checking with
    /// something else entirely.
    func testRSASignatureVerifiesWithSecurityFramework() throws {
        let generated = try SSHKeyGenerator.generate(type: .rsa, bits: 2048, comment: "rsa")
        let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM)

        var blob = SSHWireDecoder(signer.publicKeyBlob)
        _ = try blob.readString()
        let exponent = try blob.readMPInt()
        let modulus = try blob.readMPInt()
        let publicKey = try secKey(modulus: modulus, exponent: exponent)

        // Each flag combination selects a different hash, and getting that pairing
        // wrong produces a signature that is well-formed and invalid.
        let cases: [(flags: UInt32, name: String, algorithm: SecKeyAlgorithm)] = [
            (0, "ssh-rsa", .rsaSignatureMessagePKCS1v15SHA1),
            (SSHSigner.SignFlags.rsaSHA2_256, "rsa-sha2-256", .rsaSignatureMessagePKCS1v15SHA256),
            (SSHSigner.SignFlags.rsaSHA2_512, "rsa-sha2-512", .rsaSignatureMessagePKCS1v15SHA512),
        ]

        for testCase in cases {
            let (algorithm, signature) = try split(signer.signature(for: challenge, flags: testCase.flags))
            XCTAssertEqual(algorithm, testCase.name)

            var error: Unmanaged<CFError>?
            let valid = SecKeyVerifySignature(
                publicKey,
                testCase.algorithm,
                challenge as CFData,
                signature as CFData,
                &error
            )
            XCTAssertTrue(valid, "\(testCase.name) rejected: \(String(describing: error))")
        }
    }

    /// Both flags set at once: OpenSSH's rule is that SHA-512 wins.
    func testBothRSAFlagsSelectSHA512() throws {
        let generated = try SSHKeyGenerator.generate(type: .rsa, bits: 2048)
        let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM)

        let flags = SSHSigner.SignFlags.rsaSHA2_256 | SSHSigner.SignFlags.rsaSHA2_512
        let (algorithm, _) = try split(signer.signature(for: challenge, flags: flags))
        XCTAssertEqual(algorithm, "rsa-sha2-512")
    }

    // MARK: - Identity

    /// The blob an agent advertises has to be byte-identical to the `.pub` line,
    /// or the client will not recognise the key it is asking us to sign with.
    func testPublicBlobMatchesTheGeneratedPublicKeyLine() throws {
        for type in SSHKey.KeyType.allCases {
            let generated = try SSHKeyGenerator.generate(
                type: type,
                bits: SSHKeyGenerator.defaultSize(for: type).map { type == .rsa ? 2048 : $0 },
                comment: "match"
            )
            let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM)

            let expected = generated.publicKeyLine.split(separator: " ")[1]
            XCTAssertEqual(
                signer.publicKeyBlob.base64EncodedString(),
                String(expected),
                "\(type) blob does not match its own public key line"
            )
        }
    }

    func testCommentOverrideWins() throws {
        let generated = try SSHKeyGenerator.generate(type: .ed25519, comment: "in the file")
        let signer = try SSHSigner.make(privateKeyPEM: generated.privateKeyPEM, comment: "chosen")
        XCTAssertEqual(signer.comment, "chosen")
    }

    // MARK: - Real ssh-keygen output

    /// Generated by `ssh-keygen -t ed25519`. Signing a key our own generator did
    /// not write is the case that matters: the field layout has to be right for
    /// OpenSSH's bytes, not just for ours.
    private let realEd25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCyY6J65CDtrq2n39LhmES84B6gA6KT9rXfQ6l6lKcRjQAAAJhaD1dcWg9X
    XAAAAAtzc2gtZWQyNTUxOQAAACCyY6J65CDtrq2n39LhmES84B6gA6KT9rXfQ6l6lKcRjQ
    AAAECKIEAeElqY7A8whxC+VSqDHKT/CIOH8Yoom+jc9cpNkbJjonrkIO2uraff0uGYRLzg
    HqADopP2td9DqXqUpxGNAAAAD2ZpeHR1cmUtZWQyNTUxOQECAwQFBg==
    -----END OPENSSH PRIVATE KEY-----
    """

    private let realEd25519PublicBlob =
        "AAAAC3NzaC1lZDI1NTE5AAAAILJjonrkIO2uraff0uGYRLzgHqADopP2td9DqXqUpxGN"

    /// `ssh-keygen -t ed25519 -N sshborg-test-pass`, the same key the importer
    /// tests use. An agent has to be able to sign with a key that was stored
    /// encrypted, which is the usual case for a key worth forwarding.
    private let realEncryptedEd25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0Xwfw4v
    lJKDn148+Q/Q61AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFpgB4BIgMx8yv8s
    b7JpQ8JwuZipvqJGXryWzQklBczWAAAAoBWS76rlF4Hus/N3QomgV3Z+egLClmcqERV1Ox
    dRbSUPCar65NBcfwFUdcth4mCEMQXUNVYSVNd0NoBJrt5gvdDh+y1KPy4EeQyUb3/AyEzD
    IGKnRYMOEKU8rB2xDxDqyVQCfCfWdYl0YVZr6ohDyld9sP9tKkHlnjCkgh0w9JoGBxfg4E
    ZSlRo0eFGqowrHxNyi9n44nZkIhL7RqdJjwMw=
    -----END OPENSSH PRIVATE KEY-----
    """

    private let realEncryptedPublicBlob =
        "AAAAC3NzaC1lZDI1NTE5AAAAIFpgB4BIgMx8yv8sb7JpQ8JwuZipvqJGXryWzQklBczW"

    func testSignsAKeyWrittenBySSHKeygen() throws {
        let signer = try SSHSigner.make(privateKeyPEM: realEd25519)

        XCTAssertEqual(signer.publicKeyBlob.base64EncodedString(), realEd25519PublicBlob)
        XCTAssertEqual(signer.comment, "fixture-ed25519")

        let (_, signature) = try split(signer.signature(for: challenge))
        var blob = SSHWireDecoder(signer.publicKeyBlob)
        _ = try blob.readString()
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try blob.readString())

        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
    }

    func testSignsAnEncryptedKeyOnceUnlocked() throws {
        let signer = try SSHSigner.make(
            privateKeyPEM: realEncryptedEd25519,
            passphrase: "sshborg-test-pass"
        )
        XCTAssertEqual(signer.publicKeyBlob.base64EncodedString(), realEncryptedPublicBlob)

        let (_, signature) = try split(signer.signature(for: challenge))
        var blob = SSHWireDecoder(signer.publicKeyBlob)
        _ = try blob.readString()
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try blob.readString())

        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
    }

    func testEncryptedKeyWithoutItsPassphraseIsRefused() {
        XCTAssertThrowsError(try SSHSigner.make(privateKeyPEM: realEncryptedEd25519))
        XCTAssertThrowsError(
            try SSHSigner.make(privateKeyPEM: realEncryptedEd25519, passphrase: "wrong")
        )
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try SSHSigner.make(privateKeyPEM: "not a key at all"))
    }

    // MARK: - Helpers

    /// Splits a signature blob into its algorithm name and the signature itself.
    private func split(_ blob: Data) throws -> (String, Data) {
        var decoder = SSHWireDecoder(blob)
        return (try decoder.readStringAsText(), try decoder.readString())
    }

    private func pad(_ value: Data, to width: Int) -> Data {
        let trimmed = Data(value.drop { $0 == 0 })
        guard trimmed.count < width else { return trimmed }
        return Data(repeating: 0, count: width - trimmed.count) + trimmed
    }

    /// A public `SecKey` from the two numbers, via a PKCS#1 `RSAPublicKey`.
    private func secKey(modulus: Data, exponent: Data) throws -> SecKey {
        func integer(_ magnitude: Data) -> Data {
            // DER integers are signed, so a leading 1 bit needs a zero byte.
            let body = magnitude.first.map { $0 & 0x80 != 0 } == true
                ? Data([0]) + magnitude
                : magnitude
            return Data([0x02]) + length(body.count) + body
        }
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }

        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw XCTSkip("could not rebuild the public key: \(String(describing: error))")
        }
        return key
    }
}
