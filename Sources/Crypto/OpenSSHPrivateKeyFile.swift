// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Opens an `openssh-key-v1` file and hands back its parts.
///
/// Two callers need this and they need different things from it:
/// ``OpenSSHKeyImporter`` wants the public half and the comment so a key can be
/// filed, while ``SSHSigner`` wants the private fields so it can sign. The
/// container walk itself — magic, cipher, KDF, the two check integers, the
/// per-algorithm field layout — is identical for both, and duplicating it is how
/// the two copies end up disagreeing about a malformed file.
///
/// The layout is OpenSSH's `PROTOCOL.key`; ``SSHKeyGenerator/openSSHPrivateKey``
/// writes the same structure.
enum OpenSSHPrivateKeyFile {

    struct Contents {
        /// The public key blob, exactly as it appears base64-encoded in a `.pub`.
        let publicBlob: Data
        /// Algorithm name, read from ``publicBlob``.
        let algorithm: String
        /// The algorithm's private fields, in file order, still wire-encoded.
        /// Ed25519 has two, ECDSA three, RSA six — see ``fieldCount(for:)``.
        let privateFields: [Data]
        let comment: String
    }

    enum ParseError: Error, Equatable {
        case notOpenSSHFormat
        case malformed
        case passphraseRequired
        case wrongPassphrase
        case unsupportedAlgorithm(String)
    }

    static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"

    private static let magic = Data("openssh-key-v1\0".utf8)

    static func parse(pem: String, passphrase: String? = nil) throws -> Contents {
        guard pem.contains(beginMarker) else { throw ParseError.notOpenSSHFormat }

        let blob = try base64Body(of: pem)
        guard blob.count > magic.count, blob.prefix(magic.count) == magic else {
            throw ParseError.malformed
        }

        var decoder = SSHWireDecoder(blob.dropFirst(magic.count))

        let cipher: String
        let kdf: String
        let kdfOptions: Data
        let publicBlob: Data
        var section: Data

        do {
            cipher = try decoder.readStringAsText()
            kdf = try decoder.readStringAsText()
            kdfOptions = try decoder.readString()

            guard try decoder.readUInt32() == 1 else { throw ParseError.malformed }

            publicBlob = try decoder.readString()
            section = try decoder.readString()
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.malformed
        }

        let isEncrypted = cipher != "none" || kdf != "none"
        if isEncrypted {
            guard let passphrase, !passphrase.isEmpty else {
                throw ParseError.passphraseRequired
            }
            do {
                section = try OpenSSHKeyDecryptor.decrypt(
                    section: section,
                    cipherName: cipher,
                    kdfName: kdf,
                    kdfOptions: kdfOptions,
                    passphrase: passphrase
                )
            } catch {
                throw ParseError.wrongPassphrase
            }
        }

        let algorithm = try algorithmName(of: publicBlob)
        let (fields, comment) = try readPrivateSection(section, wasEncrypted: isEncrypted)

        return Contents(
            publicBlob: publicBlob,
            algorithm: algorithm,
            privateFields: fields,
            comment: comment
        )
    }

    /// Number of wire strings the private half carries for an algorithm.
    ///
    /// RSA's six are `n, e, d, iqmp, p, q` — note that this is not the order
    /// PKCS#1 uses, and not the order anything else in this project uses either.
    static func fieldCount(for algorithm: String) throws -> Int {
        switch algorithm {
        case "ssh-ed25519": return 2                                // public, private
        case let name where name.hasPrefix("ecdsa-sha2-"): return 3 // curve, point, scalar
        case "ssh-rsa": return 6
        default: throw ParseError.unsupportedAlgorithm(algorithm)
        }
    }

    static func algorithmName(of publicBlob: Data) throws -> String {
        var decoder = SSHWireDecoder(publicBlob)
        guard let name = try? decoder.readStringAsText(), !name.isEmpty else {
            throw ParseError.malformed
        }
        return name
    }

    static func keyType(of algorithm: String) throws -> SSHKey.KeyType {
        switch algorithm {
        case "ssh-ed25519": return .ed25519
        case "ssh-rsa": return .rsa
        case let name where name.hasPrefix("ecdsa-sha2-"): return .ecdsa
        default: throw ParseError.unsupportedAlgorithm(algorithm)
        }
    }

    /// Everything between the BEGIN and END lines, base64-decoded.
    static func base64Body(of pem: String) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty && !$0.contains(":") }
            .joined()

        guard let data = Data(base64Encoded: body), !data.isEmpty else {
            throw ParseError.malformed
        }
        return data
    }

    // MARK: - Private half

    private static func readPrivateSection(
        _ section: Data,
        wasEncrypted: Bool
    ) throws -> (fields: [Data], comment: String) {
        var decoder = SSHWireDecoder(section)

        do {
            let first = try decoder.readUInt32()
            let second = try decoder.readUInt32()
            // The two check integers are how a wrong passphrase is told from a
            // damaged file: garbage plaintext almost never produces a match.
            guard first == second else {
                throw wasEncrypted ? ParseError.wrongPassphrase : ParseError.malformed
            }

            let algorithm = try decoder.readStringAsText()
            var fields: [Data] = []
            for _ in 0..<(try fieldCount(for: algorithm)) {
                fields.append(try decoder.readString())
            }

            return (fields, try decoder.readStringAsText())
        } catch let error as ParseError {
            throw error
        } catch {
            throw ParseError.malformed
        }
    }
}
