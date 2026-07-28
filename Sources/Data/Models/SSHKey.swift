// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// A locally stored SSH key pair.
///
/// Mirrors the Android `SshKeyEntity`. Read the private key through
/// ``KeychainCrypto/privateKeyPEM(for:)`` rather than touching
/// ``privateKeyPEM`` directly: the key may live in ``encryptedBlob`` instead.
struct SSHKey: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {

    static let databaseTableName = "ssh_keys"

    var id: Int64?
    var label: String

    /// One of ``KeyType``, stored as a raw string for schema compatibility.
    var keyType: String

    /// Plaintext PEM. Empty when ``encryptedBlob`` is set.
    var privateKeyPem: String = ""

    /// OpenSSH public key line, e.g. `ssh-ed25519 AAAA...`.
    var publicKey: String

    /// Milliseconds since the Unix epoch.
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    /// AES-GCM blob, `Base64(nonce || ciphertext || tag)`, set when encryption
    /// is enabled. See ``KeychainCrypto``.
    var encryptedBlob: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SSHKey {

    enum KeyType: String, CaseIterable {
        case ed25519 = "ED25519"
        case ecdsa = "ECDSA"
        case rsa = "RSA"

        var displayName: String {
            switch self {
            case .ed25519: "Ed25519"
            case .ecdsa: "ECDSA"
            case .rsa: "RSA"
            }
        }
    }

    enum Columns {
        static let id = Column("id")
        static let label = Column("label")
    }

    /// Parsed ``keyType``, tolerating the lowercase spellings the Android key
    /// generator accepts as input.
    var parsedKeyType: KeyType? {
        KeyType(rawValue: keyType.uppercased())
    }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
    }

    /// True when the private key is stored encrypted rather than in plaintext.
    var isEncrypted: Bool {
        encryptedBlob != nil
    }
}
