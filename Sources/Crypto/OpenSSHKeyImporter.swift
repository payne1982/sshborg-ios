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
        /// Encrypted in a container this app cannot open: the older
        /// OpenSSL-encrypted PEM, a PKCS#8 `ENCRYPTED PRIVATE KEY`, a PuTTY
        /// `.ppk`. Each is a different mechanism from `openssh-key-v1`, and the
        /// answer to all three is the same — decrypt it with the tool that wrote
        /// it and import it again.
        case unsupportedEncryption
        /// The key was unlocked and what came back out was not the same key.
        /// Nothing is stored: see ``verified(_:against:)``.
        case reencodingFailed
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
            case .unsupportedEncryption:
                return String(localized: .keysImportErrorEncryption)
            case .reencodingFailed:
                return "This key could not be unlocked. Import it again, or decrypt it with the tool that created it."
            case .unsupportedAlgorithm(let name):
                return "Unsupported key algorithm: \(name)."
            case .malformed:
                return "The key file is damaged or incomplete."
            }
        }
    }

    /// Whether a stored key is encrypted, and so unusable: nothing supplies a
    /// passphrase at connection time, and nothing stores one. Only keys imported
    /// by a released version are in this state.
    /// See ``OpenSSHPrivateKeyFile/isEncrypted(pem:)``.
    static func isEncrypted(_ pem: String) -> Bool {
        OpenSSHPrivateKeyFile.isEncrypted(pem: pem.replacingOccurrences(of: "\r\n", with: "\n").trimmed)
    }

    private static let openSSHBegin = OpenSSHPrivateKeyFile.beginMarker
    private static let rsaBegin = "-----BEGIN RSA PRIVATE KEY-----"
    private static let pkcs8EncryptedBegin = "-----BEGIN ENCRYPTED PRIVATE KEY-----"
    private static let puttyMarker = "PuTTY-User-Key-File"

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
        // Encrypted, but in a container with its own scheme: PKCS#8 wraps the
        // key in DER with its own KDF, and PuTTY's format is PuTTY's own.
        // Neither can be unlocked here, and saying "not a private key" about a
        // file that plainly is one sends the user looking for the wrong problem.
        if normalised.contains(pkcs8EncryptedBegin) || normalised.hasPrefix(puttyMarker) {
            throw ImportError.unsupportedEncryption
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

        let publicKeyLine = SSHKeyGenerator.publicLine(
            algorithm: contents.algorithm,
            blob: contents.publicBlob,
            comment: contents.comment
        )

        // Unlocked once, here, and stored unlocked. The passphrase is used and
        // dropped — it is written nowhere — so a key protected by a passphrase
        // ends up exactly as safe as one generated in the app, and no better:
        // that is the whole trade, and it is the right way round, because the
        // passphrase is usually a secret shared with other keys and other
        // machines while the key is worth only itself.
        //
        // A key that arrived unencrypted is stored as it came, byte for byte.
        let stored = OpenSSHPrivateKeyFile.isEncrypted(pem: pem)
            ? try verified(contents.unencryptedPEM(), against: contents)
            : pem + "\n"

        return ImportedKey(
            privateKeyPEM: stored,
            publicKeyLine: publicKeyLine,
            type: try keyType(of: contents.algorithm),
            comment: contents.comment
        )
    }

    /// Reads back what would be stored and refuses it unless it is the same
    /// key, in the clear.
    ///
    /// Re-encoding is a small amount of code with a large blast radius: a
    /// mistake would file something that looks like an imported key and is not,
    /// and the user would find out at the first connection with the original
    /// file possibly already deleted. So the result is parsed again from its own
    /// text and compared field by field with what came out of the encrypted
    /// original — the public blob, every private field, the algorithm — and the
    /// import fails rather than storing anything that differs.
    private static func verified(
        _ pem: String,
        against original: OpenSSHPrivateKeyFile.Contents
    ) throws -> String {
        guard !OpenSSHPrivateKeyFile.isEncrypted(pem: pem),
              let reread = try? OpenSSHPrivateKeyFile.parse(pem: pem),
              reread.algorithm == original.algorithm,
              reread.publicBlob == original.publicBlob,
              reread.privateFields == original.privateFields
        else {
            throw ImportError.reencodingFailed
        }
        return pem
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
            throw ImportError.unsupportedEncryption
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
