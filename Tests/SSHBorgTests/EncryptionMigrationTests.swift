// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import XCTest

@testable import SSHBorg

/// The encryption switch has to move what is already stored, not just record a
/// preference.
///
/// Until 14/08/2026 it recorded the preference and nothing else: every password
/// and private key saved before the switch was flipped stayed in the database in
/// the clear, under a settings screen announcing that they were encrypted. The
/// assertions that matter here are the ones about the *old* rows.
@MainActor
final class EncryptionMigrationTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var preferences: AppPreferences!

    /// The real wire format, with a fixed key instead of the Keychain's.
    ///
    /// An unsigned build cannot reach the Keychain at all — every request comes
    /// back `errSecMissingEntitlement` (-34018) — and the suite builds with
    /// `CODE_SIGNING_ALLOWED=NO`. `KeychainCryptoTests` solves the same problem
    /// the same way. What is under test here is the migration's decisions, not
    /// where the key is kept.
    private let fixedKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    private var cipher: EncryptionMigration.Cipher {
        EncryptionMigration.Cipher(
            seal: { [fixedKey] in try KeychainCrypto.seal($0, using: fixedKey) },
            open: { [fixedKey] in try KeychainCrypto.open($0, using: fixedKey) }
        )
    }

    /// Records that the key was thrown away, and when.
    private var deletedKey = false

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
        preferences = AppPreferences(
            defaults: UserDefaults(suiteName: "migration.\(UUID().uuidString)")!
        )
        preferences.keychainEncryption = false
    }

    private func enable() async throws {
        try await EncryptionMigration.enable(
            hosts: hosts, keys: keys, preferences: preferences, cipher: cipher
        )
    }

    private func disable() async throws {
        try await EncryptionMigration.disable(
            hosts: hosts, keys: keys, preferences: preferences, cipher: cipher,
            deleteKey: { self.deletedKey = true }
        )
    }

    private func makeHostWithPlaintextPassword() async throws -> Host {
        var host = Host(label: "server", hostname: "server.example", username: "someone")
        host.password = "hunter2"
        return try await hosts.save(host)
    }

    private func makeKeyWithPlaintextPEM() async throws -> SSHKey {
        var key = SSHKey(label: "laptop", keyType: "ed25519", publicKey: "ssh-ed25519 AAAA")
        key.privateKeyPem = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot really\n"
        return try await keys.save(key)
    }

    func testEnablingEncryptsWhatWasAlreadySaved() async throws {
        let host = try await makeHostWithPlaintextPassword()
        let key = try await makeKeyWithPlaintextPEM()

        try await enable()

        let hostID = try XCTUnwrap(host.id)
        let fetchedHost = try await hosts.fetch(id: hostID)
        let storedHost = try XCTUnwrap(fetchedHost)
        XCTAssertNil(storedHost.password, "the password was left in the clear")
        XCTAssertNotNil(storedHost.encryptedPassword)

        let allKeys = try await keys.fetchAll()
        let unwrappedKey = try XCTUnwrap(allKeys.first { $0.id == key.id })
        XCTAssertTrue(unwrappedKey.privateKeyPem.isEmpty, "the private key was left in the clear")
        XCTAssertNotNil(unwrappedKey.encryptedBlob)

        XCTAssertTrue(preferences.keychainEncryption)
    }

    /// What went in must come back out, or the switch is a shredder.
    func testEnablingKeepsTheCredentialsReadable() async throws {
        let host = try await makeHostWithPlaintextPassword()
        let key = try await makeKeyWithPlaintextPEM()
        let originalPEM = key.privateKeyPem

        try await enable()

        let hostID = try XCTUnwrap(host.id)
        let fetchedHost = try await hosts.fetch(id: hostID)
        let storedHost = try XCTUnwrap(fetchedHost)
        let storedBlob = try XCTUnwrap(storedHost.encryptedPassword)
        XCTAssertEqual(try KeychainCrypto.open(storedBlob, using: fixedKey), "hunter2")

        let allKeys = try await keys.fetchAll()
        let storedKey = try XCTUnwrap(allKeys.first { $0.id == key.id })
        let keyBlob = try XCTUnwrap(storedKey.encryptedBlob)
        XCTAssertEqual(try KeychainCrypto.open(keyBlob, using: fixedKey), originalPEM)
    }

    func testDisablingPutsThemBackInTheClear() async throws {
        let host = try await makeHostWithPlaintextPassword()
        let key = try await makeKeyWithPlaintextPEM()
        let originalPEM = key.privateKeyPem
        try await enable()

        try await disable()

        let hostID = try XCTUnwrap(host.id)
        let fetchedHost = try await hosts.fetch(id: hostID)
        let storedHost = try XCTUnwrap(fetchedHost)
        XCTAssertEqual(storedHost.password, "hunter2")
        XCTAssertNil(storedHost.encryptedPassword)

        let allKeys = try await keys.fetchAll()
        let storedKey = try XCTUnwrap(allKeys.first { $0.id == key.id })
        XCTAssertEqual(storedKey.privateKeyPem, originalPEM)
        XCTAssertNil(storedKey.encryptedBlob)

        XCTAssertFalse(preferences.keychainEncryption)
    }

    /// Disabling decrypts before it deletes the key. The other order destroys
    /// every blob permanently, which is the one mistake here with no way back.
    func testDisablingLeavesNothingUnreadable() async throws {
        _ = try await makeHostWithPlaintextPassword()
        try await enable()

        try await disable()

        XCTAssertTrue(deletedKey, "the encryption key outlived the data it protected")
        let stored = try await hosts.fetchAll()
        XCTAssertEqual(stored.first?.password, "hunter2")
    }

    /// A host with no password at all must not gain an encrypted empty string,
    /// which would look like a stored credential to every reader.
    func testHostsWithoutAPasswordAreLeftAlone() async throws {
        let bare = try await hosts.save(
            Host(label: "keys only", hostname: "server.example", username: "someone")
        )

        try await enable()

        let bareID = try XCTUnwrap(bare.id)
        let fetched = try await hosts.fetch(id: bareID)
        let stored = try XCTUnwrap(fetched)
        XCTAssertNil(stored.password)
        XCTAssertNil(stored.encryptedPassword)
    }
}
