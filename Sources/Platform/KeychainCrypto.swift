// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Security

/// Encrypts and decrypts private key material and passwords with an AES-256-GCM
/// key held in the Keychain.
///
/// This is the iOS counterpart of the Android `KeystoreManager`, and the blob
/// format is **byte-identical** on both platforms:
///
///     Base64(nonce[12] || ciphertext || tag[16])
///
/// which is exactly what `AES.GCM.SealedBox.combined` produces and what Java's
/// `Cipher("AES/GCM/NoPadding")` writes, since Java appends the 16-byte tag to
/// the ciphertext. That equivalence is what lets an encrypted backup move
/// between an Android phone and an iPhone, and it is covered by a test.
///
/// The key itself is a Keychain generic password with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: it never leaves the device
/// and is unreadable while locked. Note this is *not* stored in the Secure
/// Enclave — the Enclave only holds P-256 keys, never symmetric ones, so an
/// AES key cannot live there on any iOS device.
enum KeychainCrypto {

    private static let service = "com.sshborg.key-encryption"

    /// Same identifier as the Android Keystore alias, for traceability.
    private static let account = "sshborg_key_encryption_v1"

    enum CryptoError: LocalizedError, Equatable {
        case keychainFailure(OSStatus)
        case malformedBlob
        case missingKey

        var errorDescription: String? {
            switch self {
            case .keychainFailure(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            case .malformedBlob:
                return "The encrypted data is malformed or was produced by another key."
            case .missingKey:
                return "No encryption key exists on this device."
            }
        }
    }

    // MARK: - Key management

    static func hasKey() -> Bool {
        (try? loadKey()) != nil
    }

    /// Removes the encryption key. Anything still encrypted with it becomes
    /// permanently unreadable, so callers must decrypt first.
    static func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychainFailure(status)
        }
    }

    private static func loadKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CryptoError.missingKey }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            throw CryptoError.missingKey
        default:
            throw CryptoError.keychainFailure(status)
        }
    }

    private static func getOrCreateKey() throws -> SymmetricKey {
        if let existing = try? loadKey() { return existing }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another task created the key between our read and this write.
            return try loadKey()
        default:
            throw CryptoError.keychainFailure(status)
        }
    }

    // MARK: - Encrypt and decrypt

    /// Encrypts `plaintext` with this device's key.
    static func encrypt(_ plaintext: String) throws -> String {
        try seal(plaintext, using: try getOrCreateKey())
    }

    /// Decrypts a blob produced by ``encrypt(_:)`` on either platform.
    static func decrypt(_ blob: String) throws -> String {
        try open(blob, using: try loadKey())
    }

    // The two functions below carry the wire format and take an explicit key, so
    // that cross-platform compatibility can be tested against a fixed key
    // without involving the Keychain.

    /// Produces `Base64(nonce || ciphertext || tag)`.
    static func seal(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoError.malformedBlob }
        return combined.base64EncodedString()
    }

    /// Reads `Base64(nonce || ciphertext || tag)`.
    static func open(_ blob: String, using key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: blob) else { throw CryptoError.malformedBlob }

        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard let string = String(data: plaintext, encoding: .utf8) else {
                throw CryptoError.malformedBlob
            }
            return string
        } catch is CryptoKitError {
            // Wrong key, truncated blob or a failed authentication tag.
            throw CryptoError.malformedBlob
        }
    }

    // MARK: - Convenience

    /// Returns the private key PEM for `key`, decrypting when necessary, or
    /// `nil` when neither an encrypted blob nor a plaintext PEM is usable.
    /// Mirrors `KeystoreManager.getPrivateKeyPem`.
    static func privateKeyPEM(for key: SSHKey) -> String? {
        if let blob = key.encryptedBlob {
            return try? decrypt(blob)
        }
        return key.privateKeyPem.isEmpty ? nil : key.privateKeyPem
    }

    /// Returns the password for `host`, decrypting when necessary.
    static func password(for host: Host) -> String? {
        if let blob = host.encryptedPassword {
            return try? decrypt(blob)
        }
        guard let password = host.password, !password.isEmpty else { return nil }
        return password
    }
}
