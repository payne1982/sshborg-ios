// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import OpenSSL

/// Signs a challenge with a stored private key, in the format SSH expects.
///
/// This exists for agent forwarding and nothing else. Ordinary public-key
/// authentication never comes through here: libssh2 is handed the PEM and signs
/// internally. An agent, though, is asked to sign bytes chosen by a *remote*
/// server, so the private key has to be usable in-process.
///
/// Ed25519 and ECDSA are CryptoKit's. RSA is OpenSSL's, and not by preference:
/// `SecKeyCreateWithData` wants a PKCS#1 `RSAPrivateKey`, which carries `dp` and
/// `dq`, and `openssh-key-v1` stores neither. Recovering them means computing
/// `d mod (p-1)` on numbers thousands of bits wide, so it would mean writing a
/// bignum. OpenSSL is already linked — libssh2's own crypto backend is this same
/// library — so this borrows its arithmetic rather than adding any code to the
/// binary.
struct SSHSigner {

    /// The public key blob, as it appears base64-encoded in a `.pub` file. This
    /// is what an agent client matches a signing request against.
    let publicKeyBlob: Data

    let comment: String

    private let key: PrivateKey

    private enum PrivateKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        /// `n, e, d, p, q`, each a raw big-endian magnitude.
        case rsa(modulus: Data, publicExponent: Data, privateExponent: Data, prime1: Data, prime2: Data)
    }

    enum SignerError: LocalizedError, Equatable {
        case unsupportedAlgorithm(String)
        case malformedKeyMaterial
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let name):
                return "Cannot sign with a \(name) key."
            case .malformedKeyMaterial:
                return "The stored key could not be read."
            case .signingFailed(let detail):
                return "Signing failed: \(detail)"
            }
        }
    }

    /// Flag bits an agent client sets on a signing request, from OpenSSH's
    /// `PROTOCOL.agent`. They only mean anything for RSA, where they choose the
    /// hash — the SHA-1 default is what `ssh-rsa` means, and every server built
    /// this decade prefers one of the other two.
    enum SignFlags {
        static let rsaSHA2_256: UInt32 = 0x02
        static let rsaSHA2_512: UInt32 = 0x04
    }

    // MARK: - Loading

    /// Reads a stored private key. `comment` overrides the one in the file, which
    /// is what lets the key list's label reach the remote `ssh-add -l`.
    static func make(
        privateKeyPEM: String,
        passphrase: String? = nil,
        comment: String? = nil
    ) throws -> SSHSigner {
        let pem = privateKeyPEM.replacingOccurrences(of: "\r\n", with: "\n")

        if pem.contains("-----BEGIN RSA PRIVATE KEY-----") {
            return try makePKCS1RSA(pem, comment: comment ?? "")
        }

        let contents = try OpenSSHPrivateKeyFile.parse(pem: pem, passphrase: passphrase)
        let fields = contents.privateFields

        let key: PrivateKey
        switch contents.algorithm {
        case "ssh-ed25519":
            // The private field is seed ‖ public key, libsodium's "secret key"
            // layout. CryptoKit wants the 32-byte seed alone.
            guard fields.count == 2, fields[1].count >= 32 else {
                throw SignerError.malformedKeyMaterial
            }
            guard let parsed = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: fields[1].prefix(32)
            ) else {
                throw SignerError.malformedKeyMaterial
            }
            key = .ed25519(parsed)

        case let name where name.hasPrefix("ecdsa-sha2-"):
            guard fields.count == 3 else { throw SignerError.malformedKeyMaterial }
            key = try makeECDSA(algorithm: name, scalar: fields[2])

        case "ssh-rsa":
            // n, e, d, iqmp, p, q — `iqmp` is recomputed by OpenSSL, so it is
            // read past rather than kept.
            guard fields.count == 6 else { throw SignerError.malformedKeyMaterial }
            key = .rsa(
                modulus: magnitude(fields[0]),
                publicExponent: magnitude(fields[1]),
                privateExponent: magnitude(fields[2]),
                prime1: magnitude(fields[4]),
                prime2: magnitude(fields[5])
            )

        default:
            throw SignerError.unsupportedAlgorithm(contents.algorithm)
        }

        return SSHSigner(
            publicKeyBlob: contents.publicBlob,
            comment: comment ?? contents.comment,
            key: key
        )
    }

    private static func makeECDSA(algorithm: String, scalar: Data) throws -> PrivateKey {
        let raw = magnitude(scalar)

        // CryptoKit's rawRepresentation is fixed-width, and an mpint is not: a
        // scalar whose top byte happens to be zero arrives one byte short and is
        // rejected unless it is padded back out.
        func padded(to width: Int) throws -> Data {
            guard raw.count <= width else { throw SignerError.malformedKeyMaterial }
            return Data(repeating: 0, count: width - raw.count) + raw
        }

        switch algorithm {
        case "ecdsa-sha2-nistp256":
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: try padded(to: 32)) else {
                throw SignerError.malformedKeyMaterial
            }
            return .p256(key)
        case "ecdsa-sha2-nistp384":
            guard let key = try? P384.Signing.PrivateKey(rawRepresentation: try padded(to: 48)) else {
                throw SignerError.malformedKeyMaterial
            }
            return .p384(key)
        case "ecdsa-sha2-nistp521":
            guard let key = try? P521.Signing.PrivateKey(rawRepresentation: try padded(to: 66)) else {
                throw SignerError.malformedKeyMaterial
            }
            return .p521(key)
        default:
            throw SignerError.unsupportedAlgorithm(algorithm)
        }
    }

    private static func makePKCS1RSA(_ pem: String, comment: String) throws -> SSHSigner {
        guard !pem.contains("Proc-Type:"), !pem.contains("ENCRYPTED") else {
            throw SignerError.unsupportedAlgorithm("encrypted PEM")
        }

        let der = try OpenSSHPrivateKeyFile.base64Body(of: pem)
        guard let components = try? RSAPrivateKeyDER.parse(der) else {
            throw SignerError.malformedKeyMaterial
        }

        var publicBlob = SSHWireEncoder()
        publicBlob.write(string: "ssh-rsa")
        publicBlob.write(mpint: components.publicExponent)
        publicBlob.write(mpint: components.modulus)

        return SSHSigner(
            publicKeyBlob: publicBlob.data,
            comment: comment,
            key: .rsa(
                modulus: components.modulus,
                publicExponent: components.publicExponent,
                privateExponent: components.privateExponent,
                prime1: components.prime1,
                prime2: components.prime2
            )
        )
    }

    /// Strips an mpint's sign padding, leaving the bare big-endian magnitude.
    private static func magnitude(_ field: Data) -> Data {
        Data(field.drop { $0 == 0 })
    }

    // MARK: - Signing

    /// The full SSH signature blob: `string algorithm | string signature`.
    ///
    /// `flags` comes straight from the agent request and only affects RSA.
    func signature(for data: Data, flags: UInt32 = 0) throws -> Data {
        var blob = SSHWireEncoder()

        switch key {
        case .ed25519(let key):
            blob.write(string: "ssh-ed25519")
            blob.write(string: try key.signature(for: data))

        case .p256(let key):
            blob.write(string: "ecdsa-sha2-nistp256")
            blob.write(string: Self.ecdsaSignature(raw: try key.signature(for: data).rawRepresentation))
        case .p384(let key):
            blob.write(string: "ecdsa-sha2-nistp384")
            blob.write(string: Self.ecdsaSignature(raw: try key.signature(for: data).rawRepresentation))
        case .p521(let key):
            blob.write(string: "ecdsa-sha2-nistp521")
            blob.write(string: Self.ecdsaSignature(raw: try key.signature(for: data).rawRepresentation))

        case .rsa(let n, let e, let d, let p, let q):
            let (algorithm, signature) = try Self.rsaSignature(
                data: data, flags: flags,
                modulus: n, publicExponent: e, privateExponent: d, prime1: p, prime2: q
            )
            blob.write(string: algorithm)
            blob.write(string: signature)
        }

        return blob.data
    }

    /// The algorithm name this signer's ``signature(for:flags:)`` will emit, so
    /// a caller can report it without signing anything.
    var algorithm: String {
        switch key {
        case .ed25519: "ssh-ed25519"
        case .p256: "ecdsa-sha2-nistp256"
        case .p384: "ecdsa-sha2-nistp384"
        case .p521: "ecdsa-sha2-nistp521"
        case .rsa: "ssh-rsa"
        }
    }

    /// SSH wraps an ECDSA signature as two mpints inside one string, where
    /// CryptoKit hands back the fixed-width `r ‖ s` concatenation.
    private static func ecdsaSignature(raw: Data) -> Data {
        let half = raw.count / 2
        var inner = SSHWireEncoder()
        inner.write(mpint: Data(raw.prefix(half)))
        inner.write(mpint: Data(raw.suffix(from: raw.startIndex + half)))
        return inner.data
    }

    // MARK: - RSA through OpenSSL

    private static func rsaSignature(
        data: Data,
        flags: UInt32,
        modulus: Data,
        publicExponent: Data,
        privateExponent: Data,
        prime1: Data,
        prime2: Data
    ) throws -> (algorithm: String, signature: Data) {
        let algorithm: String
        let digestName: String
        if flags & SignFlags.rsaSHA2_512 != 0 {
            algorithm = "rsa-sha2-512"
            digestName = "SHA512"
        } else if flags & SignFlags.rsaSHA2_256 != 0 {
            algorithm = "rsa-sha2-256"
            digestName = "SHA256"
        } else {
            algorithm = "ssh-rsa"
            digestName = "SHA1"
        }

        guard let rsa = RSA_new() else { throw SignerError.signingFailed("RSA_new") }
        defer { RSA_free(rsa) }

        // RSA_set0_* takes ownership of the BIGNUMs on success, so they must not
        // be freed here — and must be freed if the call never happens.
        guard let n = bignum(modulus), let e = bignum(publicExponent), let d = bignum(privateExponent) else {
            throw SignerError.malformedKeyMaterial
        }
        guard RSA_set0_key(rsa, n, e, d) == 1 else {
            BN_free(n); BN_free(e); BN_free(d)
            throw SignerError.signingFailed("RSA_set0_key")
        }

        // The factors are optional for correctness but are what makes signing
        // use the CRT path, which is roughly four times faster — and an agent
        // signs on a remote server's schedule, not the user's.
        if let p = bignum(prime1), let q = bignum(prime2) {
            if RSA_set0_factors(rsa, p, q) != 1 {
                BN_free(p); BN_free(q)
            }
        }

        guard let pkey = EVP_PKEY_new() else { throw SignerError.signingFailed("EVP_PKEY_new") }
        defer { EVP_PKEY_free(pkey) }

        guard EVP_PKEY_set1_RSA(pkey, rsa) == 1 else {
            throw SignerError.signingFailed("EVP_PKEY_set1_RSA")
        }

        guard let digest = EVP_get_digestbyname(digestName) else {
            throw SignerError.signingFailed("no \(digestName) digest")
        }

        guard let context = EVP_MD_CTX_new() else { throw SignerError.signingFailed("EVP_MD_CTX_new") }
        defer { EVP_MD_CTX_free(context) }

        guard EVP_DigestSignInit(context, nil, digest, nil, pkey) == 1 else {
            throw SignerError.signingFailed("EVP_DigestSignInit")
        }

        var length = 0
        let signed: Data? = data.withUnsafeBytes { raw -> Data? in
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            guard EVP_DigestSign(context, nil, &length, base, raw.count) == 1, length > 0 else {
                return nil
            }
            var buffer = [UInt8](repeating: 0, count: length)
            guard EVP_DigestSign(context, &buffer, &length, base, raw.count) == 1 else {
                return nil
            }
            return Data(buffer.prefix(length))
        }

        guard let signed else { throw SignerError.signingFailed("EVP_DigestSign") }
        return (algorithm, signed)
    }

    /// `BIGNUM` is an opaque struct, so Swift imports every `BIGNUM *` as a bare
    /// `OpaquePointer` rather than as a typed pointer.
    private static func bignum(_ magnitude: Data) -> OpaquePointer? {
        magnitude.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return BN_bin2bn(base, Int32(raw.count), nil)
        }
    }
}
