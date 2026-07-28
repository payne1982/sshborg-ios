// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Backs the key list: streams the stored keys and performs the operations the
/// screen offers. Counterpart of the Android `KeysViewModel`.
@MainActor
@Observable
final class KeysModel {

    private(set) var keys: [SSHKey] = []

    @ObservationIgnored private let repository: SSHKeyRepository
    @ObservationIgnored private let preferences: AppPreferences

    init(repository: SSHKeyRepository, preferences: AppPreferences) {
        self.repository = repository
        self.preferences = preferences
    }

    func observe() async {
        do {
            for try await value in repository.observeAll() {
                keys = value
            }
        } catch {
            // The stream ended; the list keeps showing what it last had rather
            // than blanking out.
        }
    }

    // MARK: - Creating

    func generate(type: SSHKey.KeyType, bits: Int?, label: String) async throws {
        let generated = try SSHKeyGenerator.generate(type: type, bits: bits, comment: label)

        try await store(
            label: label,
            type: generated.type,
            privateKeyPEM: generated.privateKeyPEM,
            publicKeyLine: generated.publicKeyLine
        )
    }

    func importKey(text: String, label: String) async throws {
        let imported = try OpenSSHKeyImporter.parse(text)

        try await store(
            // Fall back to the key's own comment when the user left the name
            // blank, which is usually what they meant.
            label: label.trimmed.isEmpty ? fallbackLabel(for: imported) : label.trimmed,
            type: imported.type,
            privateKeyPEM: imported.privateKeyPEM,
            publicKeyLine: imported.publicKeyLine
        )
    }

    private func fallbackLabel(for imported: OpenSSHKeyImporter.ImportedKey) -> String {
        imported.comment.trimmed.isEmpty
            ? "Imported \(imported.type.displayName)"
            : imported.comment.trimmed
    }

    /// Writes a key, honouring the at-rest encryption setting.
    ///
    /// The two fields are mutually exclusive, exactly as on Android: either the
    /// PEM sits in `privateKeyPem` or its ciphertext sits in `encryptedBlob`,
    /// never both, so there is never a stale plaintext copy left behind.
    private func store(
        label: String,
        type: SSHKey.KeyType,
        privateKeyPEM: String,
        publicKeyLine: String
    ) async throws {
        var key = SSHKey(
            label: label.trimmed,
            keyType: type.rawValue,
            publicKey: publicKeyLine
        )

        if preferences.keychainEncryption {
            key.encryptedBlob = try KeychainCrypto.encrypt(privateKeyPEM)
            key.privateKeyPem = ""
        } else {
            key.privateKeyPem = privateKeyPEM
            key.encryptedBlob = nil
        }

        try await repository.save(key)
    }

    // MARK: - Removing

    /// How many hosts point at this key, so the confirmation can say what will
    /// break. Those hosts survive the deletion and fall back to password auth.
    func hostCount(using key: SSHKey) async -> Int {
        guard let id = key.id else { return 0 }
        return (try? await repository.hostCount(usingKeyId: id)) ?? 0
    }

    func delete(_ key: SSHKey) async {
        try? await repository.delete(key)
    }
}

extension SSHKey {

    /// The OpenSSH-style fingerprint of the public half, the same string
    /// `ssh-keygen -l` prints.
    var fingerprint: String? {
        let fields = publicKey.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            return nil
        }
        return KnownHostsLine.fingerprint(forKeyBlob: blob)
    }

    /// Just the algorithm and the base64, without the trailing comment, for
    /// copying into `authorized_keys` when the comment is not wanted.
    var publicKeyWithoutComment: String {
        publicKey.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
