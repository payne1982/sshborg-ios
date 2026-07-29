// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads an existing private key well enough to file it: what type it is, what
/// its public half is, and what comment it carries.
///
/// This is the inverse of ``SSHKeyGenerator``, and the container walk it needs
/// lives in ``OpenSSHPrivateKeyFile``. Nothing here looks at the private half:
/// for authentication libssh2 is handed the PEM text and parses it itself, and
/// the one place that does need the private material — ``SSHSigner``, for agent
/// forwarding — reads it from the shared parser directly.
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

    private static let openSSHBegin = OpenSSHPrivateKeyFile.beginMarker
    private static let rsaBegin = "-----BEGIN RSA PRIVATE KEY-----"

    /// Restates a parser failure in the words the key-import screen shows.
    ///
    /// The two enums are kept separate on purpose: the parser reports what the
    /// bytes were, this reports what the user should do about it.
    private static func imported(_ error: OpenSSHPrivateKeyFile.ParseError) -> ImportError {
        switch error {
        case .notOpenSSHFormat: .notAPrivateKey
        case .malformed: .malformed
        case .passphraseRequired: .passphraseRequired
        case .wrongPassphrase: .wrongPassphrase
        case .unsupportedAlgorithm(let name): .unsupportedAlgorithm(name)
        }
    }

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
        let contents: OpenSSHPrivateKeyFile.Contents
        do {
            contents = try OpenSSHPrivateKeyFile.parse(pem: pem, passphrase: passphrase)
        } catch let error as OpenSSHPrivateKeyFile.ParseError {
            throw imported(error)
        }

        return ImportedKey(
            privateKeyPEM: pem + "\n",
            publicKeyLine: SSHKeyGenerator.publicLine(
                algorithm: contents.algorithm,
                blob: contents.publicBlob,
                comment: contents.comment
            ),
            type: try keyType(of: contents.algorithm),
            comment: contents.comment
        )
    }

    private static func keyType(of algorithm: String) throws -> SSHKey.KeyType {
        do {
            return try OpenSSHPrivateKeyFile.keyType(of: algorithm)
        } catch let error as OpenSSHPrivateKeyFile.ParseError {
            throw imported(error)
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
        do {
            return try OpenSSHPrivateKeyFile.base64Body(of: pem)
        } catch let error as OpenSSHPrivateKeyFile.ParseError {
            throw imported(error)
        }
    }
}
