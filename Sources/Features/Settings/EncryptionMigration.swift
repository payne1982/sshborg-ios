// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Moves what is already stored across when the encryption setting is turned on
/// or off. Ported from the Android `SettingsViewModel`'s
/// `enableKeystoreEncryption` / `disableKeystoreEncryption`.
///
/// Without this the switch is a label rather than a setting: turning it on left
/// every password and private key already saved sitting in the database in
/// plaintext, under a settings screen announcing that they were encrypted.
/// Only later saves were affected, which is the worst of both — the promise is
/// made immediately and kept only for data that does not exist yet.
///
/// **Order matters in both directions**, and it is the order Android uses:
///
/// - Enabling writes every row first and sets the flag *last*. Interrupted
///   halfway, some rows are encrypted and the flag is still off — and a reader
///   prefers the encrypted column when it is there, so nothing is lost and
///   running it again finishes the job.
/// - Disabling decrypts every row first, then deletes the key, then clears the
///   flag. Deleting the key first would make every remaining blob permanently
///   unreadable, which is the one failure here that cannot be undone.
enum EncryptionMigration {

    /// How to encrypt and decrypt one string.
    ///
    /// Injected so this can be tested without the Keychain, which an unsigned
    /// build cannot reach at all: it answers `errSecMissingEntitlement` (-34018)
    /// to every request, and the whole suite runs with `CODE_SIGNING_ALLOWED=NO`.
    /// `KeychainCryptoTests` sidesteps the same wall by testing the wire format
    /// against a fixed key; this does the same for the migration's own decisions,
    /// which are the interesting part — what gets rewritten, what is left alone,
    /// and in what order.
    struct Cipher {
        var seal: (String) throws -> String
        var open: (String) throws -> String

        static let keychain = Cipher(
            seal: { try KeychainCrypto.encrypt($0) },
            open: { try KeychainCrypto.decrypt($0) }
        )
    }

    /// Encrypts everything still held in the clear.
    static func enable(
        hosts: HostRepository,
        keys: SSHKeyRepository,
        preferences: AppPreferences,
        cipher: Cipher = .keychain
    ) async throws {
        for var key in try await keys.fetchAll() where key.encryptedBlob == nil {
            guard !key.privateKeyPem.isEmpty else { continue }
            key.encryptedBlob = try cipher.seal(key.privateKeyPem)
            key.privateKeyPem = ""
            _ = try await keys.save(key)
        }

        for var host in try await hosts.fetchAll() where host.encryptedPassword == nil {
            guard let password = host.password, !password.isEmpty else { continue }
            host.encryptedPassword = try cipher.seal(password)
            host.password = nil
            _ = try await hosts.save(host)
        }

        preferences.keychainEncryption = true
    }

    /// Puts everything back in the clear and throws the key away.
    static func disable(
        hosts: HostRepository,
        keys: SSHKeyRepository,
        preferences: AppPreferences,
        cipher: Cipher = .keychain,
        deleteKey: () throws -> Void = KeychainCrypto.deleteKey
    ) async throws {
        for var key in try await keys.fetchAll() {
            guard let blob = key.encryptedBlob else { continue }
            key.privateKeyPem = try cipher.open(blob)
            key.encryptedBlob = nil
            _ = try await keys.save(key)
        }

        for var host in try await hosts.fetchAll() {
            guard let blob = host.encryptedPassword else { continue }
            host.password = try cipher.open(blob)
            host.encryptedPassword = nil
            _ = try await hosts.save(host)
        }

        try deleteKey()
        preferences.keychainEncryption = false
    }
}
