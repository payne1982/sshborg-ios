// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import XCTest

@testable import SSHBorg

final class KeychainCryptoTests: XCTestCase {

    /// A fixed key, so these tests describe the wire format rather than whatever
    /// the Keychain happens to hold.
    private let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    func testRoundTrip() throws {
        let plaintext = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----"
        let blob = try KeychainCrypto.seal(plaintext, using: key)
        XCTAssertEqual(try KeychainCrypto.open(blob, using: key), plaintext)
    }

    func testNonASCIIRoundTrip() throws {
        let plaintext = "pässwörd — 日本語 — 🔐"
        let blob = try KeychainCrypto.seal(plaintext, using: key)
        XCTAssertEqual(try KeychainCrypto.open(blob, using: key), plaintext)
    }

    /// The layout must be `nonce(12) || ciphertext || tag(16)`, which is what
    /// Java's `Cipher("AES/GCM/NoPadding")` writes on Android. If CryptoKit ever
    /// changed `combined`, encrypted backups would stop crossing platforms.
    func testBlobLayoutMatchesAndroid() throws {
        let plaintext = "abcdefgh" // 8 bytes
        let blob = try KeychainCrypto.seal(plaintext, using: key)

        let data = try XCTUnwrap(Data(base64Encoded: blob))
        XCTAssertEqual(data.count, 12 + plaintext.utf8.count + 16)

        // Reassembling the box from the three slices must yield the same result,
        // proving the offsets are where we claim they are.
        let nonce = try AES.GCM.Nonce(data: data.prefix(12))
        let ciphertext = data.dropFirst(12).dropLast(16)
        let tag = data.suffix(16)

        let rebuilt = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(rebuilt, using: key)
        XCTAssertEqual(String(data: opened, encoding: .utf8), plaintext)
    }

    /// Base64 must have no line breaks, matching Android's `Base64.NO_WRAP`.
    func testBase64IsUnwrapped() throws {
        let plaintext = String(repeating: "x", count: 512)
        let blob = try KeychainCrypto.seal(plaintext, using: key)
        XCTAssertFalse(blob.contains("\n"))
        XCTAssertFalse(blob.contains("\r"))
    }

    func testWrongKeyIsRejected() throws {
        let blob = try KeychainCrypto.seal("secret", using: key)
        let otherKey = SymmetricKey(data: Data(repeating: 0x43, count: 32))

        XCTAssertThrowsError(try KeychainCrypto.open(blob, using: otherKey)) { error in
            XCTAssertEqual(error as? KeychainCrypto.CryptoError, .malformedBlob)
        }
    }

    func testTamperedBlobIsRejected() throws {
        let blob = try KeychainCrypto.seal("secret", using: key)
        var data = try XCTUnwrap(Data(base64Encoded: blob))
        data[data.count - 1] ^= 0xFF // corrupt the authentication tag

        XCTAssertThrowsError(try KeychainCrypto.open(data.base64EncodedString(), using: key))
    }

    func testGarbageInputIsRejected() {
        XCTAssertThrowsError(try KeychainCrypto.open("not base64 at all!!", using: key))
        XCTAssertThrowsError(try KeychainCrypto.open("", using: key))
    }

    // MARK: - Convenience accessors

    func testPrivateKeyPEMPrefersPlaintextWhenNotEncrypted() {
        let sshKey = SSHKey(label: "test", keyType: "ED25519", privateKeyPem: "PEM", publicKey: "ssh-ed25519 AAAA")
        XCTAssertEqual(KeychainCrypto.privateKeyPEM(for: sshKey), "PEM")
    }

    func testPrivateKeyPEMIsNilWhenNothingStored() {
        let sshKey = SSHKey(label: "test", keyType: "ED25519", privateKeyPem: "", publicKey: "ssh-ed25519 AAAA")
        XCTAssertNil(KeychainCrypto.privateKeyPEM(for: sshKey))
    }

    func testPasswordIsNilWhenEmpty() {
        let host = Host(label: "h", hostname: "example.com", username: "root", password: "")
        XCTAssertNil(KeychainCrypto.password(for: host))
    }
}
