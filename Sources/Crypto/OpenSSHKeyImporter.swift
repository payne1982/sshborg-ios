// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads an existing private key well enough to file it: what type it is, what
/// its public half is, and what comment it carries.
///
/// This is the inverse of ``SSHKeyGenerator`` and shares its decoder. Note that
/// SSHBorg never needs to *use* the parsed material — libssh2 is handed the PEM
/// text and does its own parsing at authentication time. Everything here exists
/// so the key list can show something meaningful and so the public key can be
/// copied to a server.
enum OpenSSHKeyImporter {

    struct ImportedKey {
        /// Line-ending-normalised original text, which is what gets stored and
        /// later handed to libssh2 verbatim.
        let privateKeyPEM: String
        let publicKeyLine: String
        let type: SSHKey.KeyType
        let comment: String
    }

    enum ImportError: LocalizedError, Equatable {
        case notAPrivateKey
        /// Encrypted, and no passphrase was supplied.
        case passphraseRequired
        /// A passphrase was supplied and it did not work.
        case wrongPassphrase
        /// The older OpenSSL-encrypted PEM form, which is a different mechanism.
        case legacyEncryptedPEM
        case unsupportedAlgorithm(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notAPrivateKey:
                return "That does not look like a private key. Paste the file that has no .pub extension."
            case .passphraseRequired:
                return "This key is protected by a passphrase. Enter it to import the key."
            case .wrongPassphrase:
                return "That passphrase does not unlock this key."
            case .legacyEncryptedPEM:
                return "This key uses the older OpenSSL encryption, which is not supported. Convert it with: ssh-keygen -p -f <key>"
            case .unsupportedAlgorithm(let name):
                return "Unsupported key algorithm: \(name)."
            case .malformed:
                return "The key file is damaged or incomplete."
            }
        }
    }

    private static let openSSHBegin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let rsaBegin = "-----BEGIN RSA PRIVATE KEY-----"

    // MARK: - Entry point

    static func parse(_ text: String, passphrase: String? = nil) throws -> ImportedKey {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").trimmed

        if normalised.contains(openSSHBegin) {
            return try parseOpenSSH(normalised, passphrase: passphrase)
        }
        if normalised.contains(rsaBegin) {
            return try parsePKCS1RSA(normalised)
        }
        if normalised.hasPrefix("ssh-") || normalised.hasPrefix("ecdsa-") {
            // A public key was pasted by mistake — a common slip worth naming.
            throw ImportError.notAPrivateKey
        }
        throw ImportError.notAPrivateKey
    }

    // MARK: - openssh-key-v1

    private static func parseOpenSSH(_ pem: String, passphrase: String?) throws -> ImportedKey {
        let blob = try base64Body(of: pem)

        let magic = Data("openssh-key-v1\0".utf8)
        guard blob.count > magic.count, blob.prefix(magic.count) == magic else {
            throw ImportError.malformed
        }

        var decoder = SSHWireDecoder(blob.dropFirst(magic.count))

        do {
            let cipher = try decoder.readStringAsText()
            let kdf = try decoder.readStringAsText()
            let kdfOptions = try decoder.readString()

            let keyCount = try decoder.readUInt32()
            guard keyCount == 1 else { throw ImportError.malformed }

            let publicBlob = try decoder.readString()
            var section = try decoder.readString()

            // Anything other than "none" means the private half is encrypted.
            if cipher != "none" || kdf != "none" {
                guard let passphrase, !passphrase.isEmpty else {
                    throw ImportError.passphraseRequired
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
                    throw ImportError.wrongPassphrase
                }
            }

            let type = try algorithmType(of: publicBlob)
            // The two check integers are how a wrong passphrase is told from a
            // damaged file: garbage plaintext almost never produces a match.
            let comment = try readComment(from: section, wasEncrypted: cipher != "none")

            return ImportedKey(
                privateKeyPEM: pem + "\n",
                publicKeyLine: SSHKeyGenerator.publicLine(
                    algorithm: try algorithmName(of: publicBlob),
                    blob: publicBlob,
                    comment: comment
                ),
                type: type,
                comment: comment
            )
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.malformed
        }
    }

    /// The comment sits after the key material, so reaching it means walking the
    /// per-algorithm fields first.
    private static func readComment(from section: Data, wasEncrypted: Bool = false) throws -> String {
        var decoder = SSHWireDecoder(section)

        let first = try decoder.readUInt32()
        let second = try decoder.readUInt32()
        guard first == second else {
            throw wasEncrypted ? ImportError.wrongPassphrase : ImportError.malformed
        }

        let algorithm = try decoder.readStringAsText()

        switch algorithm {
        case "ssh-ed25519":
            _ = try decoder.readString()   // public
            _ = try decoder.readString()   // private
        case let name where name.hasPrefix("ecdsa-sha2-"):
            _ = try decoder.readString()   // curve
            _ = try decoder.readString()   // point
            _ = try decoder.readString()   // scalar
        case "ssh-rsa":
            for _ in 0..<6 { _ = try decoder.readString() }  // n, e, d, iqmp, p, q
        default:
            throw ImportError.unsupportedAlgorithm(algorithm)
        }

        return try decoder.readStringAsText()
    }

    private static func algorithmName(of publicBlob: Data) throws -> String {
        var decoder = SSHWireDecoder(publicBlob)
        return try decoder.readStringAsText()
    }

    private static func algorithmType(of publicBlob: Data) throws -> SSHKey.KeyType {
        let name = try algorithmName(of: publicBlob)

        switch name {
        case "ssh-ed25519": return .ed25519
        case "ssh-rsa": return .rsa
        case let value where value.hasPrefix("ecdsa-sha2-"): return .ecdsa
        default: throw ImportError.unsupportedAlgorithm(name)
        }
    }

    // MARK: - PKCS#1 RSA

    /// The older `BEGIN RSA PRIVATE KEY` form, which `ssh-keygen -m PEM` still
    /// writes and which plenty of stored keys use.
    private static func parsePKCS1RSA(_ pem: String) throws -> ImportedKey {
        // Legacy PEM encryption is announced in headers rather than in the body.
        guard !pem.contains("Proc-Type:"), !pem.contains("ENCRYPTED") else {
            throw ImportError.legacyEncryptedPEM
        }

        let der = try base64Body(of: pem)

        let components: RSAPrivateKeyDER.Components
        do {
            components = try RSAPrivateKeyDER.parse(der)
        } catch {
            throw ImportError.malformed
        }

        var publicBlob = SSHWireEncoder()
        publicBlob.write(string: "ssh-rsa")
        publicBlob.write(mpint: components.publicExponent)
        publicBlob.write(mpint: components.modulus)

        return ImportedKey(
            privateKeyPEM: pem + "\n",
            publicKeyLine: SSHKeyGenerator.publicLine(
                algorithm: "ssh-rsa",
                blob: publicBlob.data,
                comment: ""
            ),
            type: .rsa,
            comment: ""
        )
    }

    // MARK: - Armour

    /// Everything between the BEGIN and END lines, base64-decoded.
    private static func base64Body(of pem: String) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty && !$0.contains(":") }
            .joined()

        guard let data = Data(base64Encoded: body), !data.isEmpty else {
            throw ImportError.malformed
        }
        return data
    }
}
