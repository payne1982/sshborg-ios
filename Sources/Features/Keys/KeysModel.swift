// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Perception

/// Backs the key list: streams the stored keys and performs the operations the
/// screen offers. Counterpart of the Android `KeysViewModel`.
@MainActor
@Perceptible
final class KeysModel {

    private(set) var keys: [SSHKey] = []

    /// The keys that cannot authenticate as they stand: encrypted, with no
    /// passphrase stored. Recomputed whenever the list changes, which is how the
    /// warning disappears the moment such a key is imported again.
    private(set) var keysNeedingPassphrase: Set<Int64> = []

    @PerceptionIgnored private let repository: SSHKeyRepository
    @PerceptionIgnored private let preferences: AppPreferences

    init(repository: SSHKeyRepository, preferences: AppPreferences) {
        self.repository = repository
        self.preferences = preferences
    }

    func observe() async {
        do {
            for try await value in repository.observeAll() {
                keys = value
                keysNeedingPassphrase = Set(
                    value.compactMap { key in needsPassphrase(key) ? key.id : nil }
                )
            }
        } catch {
            // The stream ended; the list keeps showing what it last had rather
            // than blanking out.
        }
    }

    // MARK: - Creating

    func generate(type: SSHKey.KeyType, bits: Int?, label: String) async throws {
        let generated = try SSHKeyGenerator.generate(type: type, bits: bits, comment: Self.comment(for: label))

        try await store(
            label: label,
            type: generated.type,
            privateKeyPEM: generated.privateKeyPEM,
            publicKeyLine: generated.publicKeyLine,
            // The generator writes an unencrypted key, so there is nothing to
            // unlock; the app has never offered to protect one with a
            // passphrase, on either platform.
            passphrase: nil
        )
    }

    func importKey(text: String, label: String, passphrase: String? = nil) async throws {
        let imported = try OpenSSHKeyImporter.parse(text, passphrase: passphrase)

        try await store(
            // Fall back to the key's own comment when the user left the name
            // blank, which is usually what they meant.
            label: label.trimmed.isEmpty ? fallbackLabel(for: imported) : label.trimmed,
            type: imported.type,
            privateKeyPEM: imported.privateKeyPEM,
            publicKeyLine: imported.publicKeyLine,
            // The key is filed exactly as it arrived, so an encrypted one is
            // only usable if its passphrase is kept with it: at connection time
            // there is nobody to ask. A passphrase typed for a key that turns
            // out not to need one is dropped rather than stored for nothing.
            passphrase: imported.isEncrypted ? passphrase.flatMap({ $0.isEmpty ? nil : $0 }) : nil
        )
    }

    /// Whether `key` cannot authenticate as it stands: encrypted, with no
    /// passphrase stored — which is every encrypted key imported before the app
    /// began keeping one.
    ///
    /// The passphrase is only ever taken at import, so there is nothing to
    /// repair from the list; this is what the warning beside such a key is for.
    func needsPassphrase(_ key: SSHKey) -> Bool {
        guard !key.hasStoredPassphrase else { return false }
        guard let pem = KeychainCrypto.privateKeyPEM(for: key) else { return false }
        return OpenSSHKeyImporter.isEncrypted(pem)
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
    /// never both, so there is never a stale plaintext copy left behind. The
    /// passphrase, when there is one, is stored the same way in its own pair of
    /// columns.
    private func store(
        label: String,
        type: SSHKey.KeyType,
        privateKeyPEM: String,
        publicKeyLine: String,
        passphrase: String?
    ) async throws {
        var key = SSHKey(
            label: label.trimmed,
            keyType: type.rawValue,
            publicKey: publicKeyLine
        )

        if preferences.keychainEncryption {
            key.encryptedBlob = try KeychainCrypto.encrypt(privateKeyPEM)
            key.privateKeyPem = ""
            // A credential of its own, and treated like the host passwords: the
            // setting that encrypts the key material encrypts this too.
            key.encryptedPassphrase = try passphrase.map { try KeychainCrypto.encrypt($0) }
            key.passphrase = nil
        } else {
            key.privateKeyPem = privateKeyPEM
            key.encryptedBlob = nil
            key.passphrase = passphrase
            key.encryptedPassphrase = nil
        }

        try await repository.save(key)
    }

    // MARK: - Renaming

    /// Changes a key's name. Nothing else about the key moves: the private half
    /// is not touched, decrypted or re-encrypted, so a rename cannot lose it.
    ///
    /// One thing goes with the label, which Android does not do. A generated
    /// key's public line carries the label as its comment — the generator says
    /// so on screen — and leaving it behind would make that sentence false the
    /// first time anyone renames a key. It is rewritten *only* when the comment
    /// is still exactly the old label, so a comment that came from an imported
    /// file, usually a `user@host` worth keeping, is left alone.
    ///
    /// The fingerprint does not change, so a key already in an `authorized_keys`
    /// somewhere keeps working; only what a future copy of the public line says
    /// about itself is different.
    func rename(_ key: SSHKey, to newLabel: String) async throws {
        let trimmed = newLabel.trimmed
        guard !trimmed.isEmpty, trimmed != key.label else { return }

        var updated = key
        updated.label = trimmed
        updated.publicKey = Self.publicKey(key.publicKey, renamedFrom: key.label, to: trimmed)
        try await repository.save(updated)
    }

    /// Rewrites the comment of an OpenSSH public line, when it is the old label.
    ///
    /// A public line is `type base64 [comment]`, and the comment may contain
    /// spaces — so it is split at most twice and the remainder taken whole.
    ///
    /// The comment counts as "the old label" in either spelling: as typed, or
    /// normalised by ``comment(for:)``. New keys carry the normalised form, but
    /// keys generated before this app normalised anything carry the label with
    /// its spaces intact — and accepting only one of the two would quietly stop
    /// the comment following the label for exactly the names that have a space
    /// in them. The replacement is always written normalised.
    static func publicKey(_ line: String, renamedFrom old: String, to new: String) -> String {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let existing = fields.count == 3 ? String(fields[2]).trimmed : nil
        guard let existing, existing == old.trimmed || existing == comment(for: old) else { return line }

        return "\(fields[0]) \(fields[1]) \(comment(for: new))"
    }

    /// The label as it goes into a public key's comment: one token, with runs
    /// of whitespace collapsed to underscores.
    ///
    /// Matching Android, which normalises for a reason worth keeping. The
    /// comment is the free-text tail of the line, so spaces in it are legal —
    /// but every tool that reads `authorized_keys` by splitting on whitespace
    /// sees a name with a space as several fields, and `ssh-keygen -l` prints
    /// only what it takes to be the comment. The name shown in the app keeps
    /// its spaces; only the embedded copy is normalised.
    static func comment(for label: String) -> String {
        label
            .trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
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
