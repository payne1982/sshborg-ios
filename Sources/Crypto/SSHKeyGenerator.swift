// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import Security

/// Generates SSH key pairs and writes them in OpenSSH's formats.
///
/// On Android this came free: BouncyCastle serialises `openssh-key-v1` and JSch
/// writes PEM. Apple ships neither, so both formats are written here by hand
/// against RFC 4253 and OpenSSH's `PROTOCOL.key`. That makes this the most
/// exacting code in the project, and the tests check the resulting bytes rather
/// than just round-tripping them through our own reader.
enum SSHKeyGenerator {

    struct GeneratedKey {
        /// PEM-armoured `openssh-key-v1`, what goes in `~/.ssh/id_…`.
        let privateKeyPEM: String
        /// One line, `ssh-ed25519 AAAA… comment`, for `authorized_keys`.
        let publicKeyLine: String
        let type: SSHKey.KeyType
    }

    enum GeneratorError: LocalizedError {
        case unsupportedSize(Int)
        case rsaGenerationFailed(String)
        case malformedKeyMaterial

        var errorDescription: String? {
            switch self {
            case .unsupportedSize(let bits):
                return "\(bits) is not a supported key size."
            case .rsaGenerationFailed(let detail):
                return "Could not generate an RSA key: \(detail)"
            case .malformedKeyMaterial:
                return "The generated key could not be encoded."
            }
        }
    }

    // MARK: - Entry point

    /// Sizes offered per type. For ECDSA the number selects the curve, which is
    /// the same convention `ssh-keygen -b` uses.
    static func supportedSizes(for type: SSHKey.KeyType) -> [Int] {
        switch type {
        case .ed25519: []          // one size only
        case .ecdsa: [256, 384, 521]
        case .rsa: [2048, 3072, 4096]
        }
    }

    static func defaultSize(for type: SSHKey.KeyType) -> Int? {
        switch type {
        case .ed25519: nil
        case .ecdsa: 256
        case .rsa: 4096            // same default as the Android generator
        }
    }

    static func generate(
        type: SSHKey.KeyType,
        bits: Int? = nil,
        comment: String = ""
    ) throws -> GeneratedKey {
        switch type {
        case .ed25519:
            return try generateEd25519(comment: comment)
        case .ecdsa:
            return try generateECDSA(bits: bits ?? 256, comment: comment)
        case .rsa:
            return try generateRSA(bits: bits ?? 4096, comment: comment)
        }
    }

    // MARK: - Ed25519

    private static func generateEd25519(comment: String) throws -> GeneratedKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicBytes = privateKey.publicKey.rawRepresentation
        let seed = privateKey.rawRepresentation

        var publicBlob = SSHWireEncoder()
        publicBlob.write(string: "ssh-ed25519")
        publicBlob.write(string: publicBytes)

        var privateFields = SSHWireEncoder()
        privateFields.write(string: "ssh-ed25519")
        privateFields.write(string: publicBytes)
        // OpenSSH stores seed and public key together as the "private" field,
        // which is what libsodium calls the secret key.
        privateFields.write(string: seed + publicBytes)

        return GeneratedKey(
            privateKeyPEM: armour(
                openSSHPrivateKey(publicBlob: publicBlob.data, privateFields: privateFields.data, comment: comment)
            ),
            publicKeyLine: publicLine(algorithm: "ssh-ed25519", blob: publicBlob.data, comment: comment),
            type: .ed25519
        )
    }

    // MARK: - ECDSA

    private static func generateECDSA(bits: Int, comment: String) throws -> GeneratedKey {
        let curveName: String
        let rawPrivate: Data
        let x963Public: Data

        switch bits {
        case 256:
            let key = P256.Signing.PrivateKey()
            curveName = "nistp256"
            rawPrivate = key.rawRepresentation
            x963Public = key.publicKey.x963Representation
        case 384:
            let key = P384.Signing.PrivateKey()
            curveName = "nistp384"
            rawPrivate = key.rawRepresentation
            x963Public = key.publicKey.x963Representation
        case 521:
            let key = P521.Signing.PrivateKey()
            curveName = "nistp521"
            rawPrivate = key.rawRepresentation
            x963Public = key.publicKey.x963Representation
        default:
            throw GeneratorError.unsupportedSize(bits)
        }

        let algorithm = "ecdsa-sha2-\(curveName)"

        var publicBlob = SSHWireEncoder()
        publicBlob.write(string: algorithm)
        publicBlob.write(string: curveName)
        // x963 is already the uncompressed point form OpenSSH wants: 0x04 || X || Y.
        publicBlob.write(string: x963Public)

        var privateFields = SSHWireEncoder()
        privateFields.write(string: algorithm)
        privateFields.write(string: curveName)
        privateFields.write(string: x963Public)
        privateFields.write(mpint: rawPrivate)

        return GeneratedKey(
            privateKeyPEM: armour(
                openSSHPrivateKey(publicBlob: publicBlob.data, privateFields: privateFields.data, comment: comment)
            ),
            publicKeyLine: publicLine(algorithm: algorithm, blob: publicBlob.data, comment: comment),
            type: .ecdsa
        )
    }

    // MARK: - RSA

    private static func generateRSA(bits: Int, comment: String) throws -> GeneratedKey {
        guard supportedSizes(for: .rsa).contains(bits) else {
            throw GeneratorError.unsupportedSize(bits)
        }

        // CryptoKit has no RSA, so this is the Security framework's job.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GeneratorError.rsaGenerationFailed(message)
        }

        guard let der = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GeneratorError.rsaGenerationFailed(message)
        }

        let components = try RSAPrivateKeyDER.parse(der)

        var publicBlob = SSHWireEncoder()
        publicBlob.write(string: "ssh-rsa")
        publicBlob.write(mpint: components.publicExponent)
        publicBlob.write(mpint: components.modulus)

        var privateFields = SSHWireEncoder()
        privateFields.write(string: "ssh-rsa")
        privateFields.write(mpint: components.modulus)
        privateFields.write(mpint: components.publicExponent)
        privateFields.write(mpint: components.privateExponent)
        // OpenSSH's order here is n, e, d, iqmp, p, q — not the DER order.
        privateFields.write(mpint: components.coefficient)
        privateFields.write(mpint: components.prime1)
        privateFields.write(mpint: components.prime2)

        return GeneratedKey(
            privateKeyPEM: armour(
                openSSHPrivateKey(publicBlob: publicBlob.data, privateFields: privateFields.data, comment: comment)
            ),
            publicKeyLine: publicLine(algorithm: "ssh-rsa", blob: publicBlob.data, comment: comment),
            type: .rsa
        )
    }

    // MARK: - Container

    /// Builds the `openssh-key-v1` container around one unencrypted key.
    ///
    /// Layout, from OpenSSH's `PROTOCOL.key`:
    ///
    ///     "openssh-key-v1\0" | ciphername | kdfname | kdfoptions
    ///     | uint32 keycount | string publickey | string encrypted-section
    ///
    /// With no passphrase the "encrypted" section is stored in the clear, but it
    /// still carries the two matching check integers a reader uses to tell a
    /// wrong passphrase from a corrupt file.
    static func openSSHPrivateKey(publicBlob: Data, privateFields: Data, comment: String) -> Data {
        var body = SSHWireEncoder()
        body.write(raw: Data("openssh-key-v1\0".utf8))
        body.write(string: "none")   // cipher
        body.write(string: "none")   // kdf
        body.write(string: Data())   // kdf options
        body.write(uint32: 1)        // one key
        body.write(string: publicBlob)

        var section = SSHWireEncoder()
        let checkInt = UInt32.random(in: 0...UInt32.max)
        section.write(uint32: checkInt)
        section.write(uint32: checkInt)
        section.write(raw: privateFields)
        section.write(string: comment)

        // Pad to the cipher's block size with 1, 2, 3… For "none" the block size
        // is 8, and ssh-keygen rejects a file padded any other way.
        let blockSize = 8
        var padding: UInt8 = 1
        while section.data.count % blockSize != 0 {
            section.write(raw: Data([padding]))
            padding += 1
        }

        body.write(string: section.data)
        return body.data
    }

    /// Wraps a key blob in the PEM armour, 70 base64 characters per line.
    static func armour(_ blob: Data) -> String {
        let base64 = blob.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { start -> String in
            let from = base64.index(base64.startIndex, offsetBy: start)
            let to = base64.index(from, offsetBy: min(70, base64.count - start))
            return String(base64[from..<to])
        }

        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(lines.joined(separator: "\n"))
        -----END OPENSSH PRIVATE KEY-----

        """
    }

    static func publicLine(algorithm: String, blob: Data, comment: String) -> String {
        let line = "\(algorithm) \(blob.base64EncodedString())"
        let trimmedComment = comment.trimmed
        return trimmedComment.isEmpty ? line : "\(line) \(trimmedComment)"
    }
}

/// Just enough DER to read a PKCS#1 `RSAPrivateKey`, which is what
/// `SecKeyCopyExternalRepresentation` hands back for an RSA key.
///
/// The structure is a flat SEQUENCE of nine INTEGERs, so this does not need to
/// be a general DER parser — and deliberately is not one.
enum RSAPrivateKeyDER {

    struct Components {
        let modulus: Data          // n
        let publicExponent: Data   // e
        let privateExponent: Data  // d
        let prime1: Data           // p
        let prime2: Data           // q
        let coefficient: Data      // iqmp
    }

    enum ParseError: Error, Equatable {
        case notASequence
        case truncated
        case unexpectedFieldCount(Int)
    }

    static func parse(_ der: Data) throws -> Components {
        var reader = Reader(der)

        guard try reader.readTag() == 0x30 else { throw ParseError.notASequence }
        let length = try reader.readLength()
        var body = Reader(try reader.read(count: length))

        var integers: [Data] = []
        while !body.isAtEnd {
            guard try body.readTag() == 0x02 else { throw ParseError.truncated }
            let intLength = try body.readLength()
            // Leading zeros are DER's sign padding, not part of the magnitude.
            integers.append(Data(try body.read(count: intLength).drop { $0 == 0 }))
        }

        // version, n, e, d, p, q, dp, dq, iqmp
        guard integers.count == 9 else {
            throw ParseError.unexpectedFieldCount(integers.count)
        }

        return Components(
            modulus: integers[1],
            publicExponent: integers[2],
            privateExponent: integers[3],
            prime1: integers[4],
            prime2: integers[5],
            coefficient: integers[8]
        )
    }

    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        mutating func readTag() throws -> UInt8 {
            guard offset < data.endIndex else { throw ParseError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readLength() throws -> Int {
            guard offset < data.endIndex else { throw ParseError.truncated }
            let first = data[offset]
            offset += 1

            if first & 0x80 == 0 { return Int(first) }

            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, offset + byteCount <= data.endIndex else {
                throw ParseError.truncated
            }

            var length = 0
            for index in 0..<byteCount {
                length = (length << 8) | Int(data[offset + index])
            }
            offset += byteCount
            return length
        }

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.endIndex else { throw ParseError.truncated }
            defer { offset += count }
            return Data(data[offset..<(offset + count)])
        }
    }
}
