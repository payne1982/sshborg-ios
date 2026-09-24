// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// An encrypted private key has to keep its passphrase, or it can never
/// authenticate.
///
/// Reported on Android as #18 and true here in exactly the same way: the import
/// asked for the passphrase, used it to derive the public half and threw it
/// away, then stored the key still encrypted. Every connection afterwards built
/// `.publicKey(privateKeyPEM:passphrase:)` with `nil`, and libssh2 cannot read
/// an encrypted key without one — so the attempt failed with nothing on screen
/// saying why.
///
/// The fixture is the same throwaway key `OpenSSHKeyImporterTests` uses, which
/// real `ssh-keygen` wrote.
@MainActor
final class KeyPassphraseTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var preferences: AppPreferences!
    private var model: KeysModel!

    private let encryptedPrivate = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0Xwfw4v
    lJKDn148+Q/Q61AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFpgB4BIgMx8yv8s
    b7JpQ8JwuZipvqJGXryWzQklBczWAAAAoBWS76rlF4Hus/N3QomgV3Z+egLClmcqERV1Ox
    dRbSUPCar65NBcfwFUdcth4mCEMQXUNVYSVNd0NoBJrt5gvdDh+y1KPy4EeQyUb3/AyEzD
    IGKnRYMOEKU8rB2xDxDqyVQCfCfWdYl0YVZr6ohDyld9sP9tKkHlnjCkgh0w9JoGBxfg4E
    ZSlRo0eFGqowrHxNyi9n44nZkIhL7RqdJjwMw=
    -----END OPENSSH PRIVATE KEY-----
    """

    private let plainPrivate = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCyY6J65CDtrq2n39LhmES84B6gA6KT9rXfQ6l6lKcRjQAAAJhaD1dcWg9X
    XAAAAAtzc2gtZWQyNTUxOQAAACCyY6J65CDtrq2n39LhmES84B6gA6KT9rXfQ6l6lKcRjQ
    AAAECKIEAeElqY7A8whxC+VSqDHKT/CIOH8Yoom+jc9cpNkbJjonrkIO2uraff0uGYRLzg
    HqADopP2td9DqXqUpxGNAAAAD2ZpeHR1cmUtZWQyNTUxOQECAwQFBg==
    -----END OPENSSH PRIVATE KEY-----
    """

    private let passphrase = "sshborg-test-pass"

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
        // Encryption off throughout: an unsigned build cannot reach the Keychain
        // at all (-34018), and what is under test is which column the passphrase
        // lands in, not where the encryption key is kept. The encrypted side of
        // the same question is `EncryptionMigrationTests`, with a fixed cipher.
        preferences = AppPreferences(
            defaults: UserDefaults(suiteName: "passphrase.\(UUID().uuidString)")!
        )
        preferences.keychainEncryption = false
        model = KeysModel(repository: keys, preferences: preferences)
    }

    // MARK: - Importing

    func testAnEncryptedKeyKeepsItsPassphrase() async throws {
        try await model.importKey(text: encryptedPrivate, label: "work", passphrase: passphrase)

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertEqual(KeychainCrypto.passphrase(for: stored), passphrase)
        // And the key itself is filed exactly as it arrived, still encrypted:
        // the passphrase is kept precisely because the material is not decrypted.
        XCTAssertTrue(OpenSSHKeyImporter.isEncrypted(stored.privateKeyPem))
    }

    /// A passphrase typed for a key that turns out not to need one is a secret
    /// stored for nothing — very likely the user's passphrase for something else.
    func testAPassphraseForAnUnencryptedKeyIsNotStored() async throws {
        try await model.importKey(text: plainPrivate, label: "laptop", passphrase: "typed-by-mistake")

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertNil(KeychainCrypto.passphrase(for: stored))
        XCTAssertNil(stored.passphrase)
    }

    func testAGeneratedKeyHasNoPassphrase() async throws {
        try await model.generate(type: .ed25519, bits: nil, label: "fresh")

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertNil(KeychainCrypto.passphrase(for: stored))
        XCTAssertFalse(model.needsPassphrase(stored))
    }

    // MARK: - The warning on the list

    /// Every encrypted key imported before this fix looks exactly like a working
    /// one, so the list has to say which ones cannot connect.
    func testAKeyImportedWithoutItsPassphraseIsFlagged() async throws {
        var orphan = SSHKey(label: "old", keyType: "ED25519", publicKey: "ssh-ed25519 AAAA")
        orphan.privateKeyPem = encryptedPrivate
        let stored = try await keys.save(orphan)

        XCTAssertTrue(model.needsPassphrase(stored))
    }

    func testAKeyImportedWithItsPassphraseIsNotFlagged() async throws {
        try await model.importKey(text: encryptedPrivate, label: "work", passphrase: passphrase)

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertFalse(model.needsPassphrase(stored))
    }

    func testAPlainKeyIsNeverFlagged() async throws {
        try await model.importKey(text: plainPrivate, label: "laptop")

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertFalse(model.needsPassphrase(stored))
    }

    // MARK: - Connecting

    /// The defect itself: the passphrase reaching the authentication.
    func testStoredAuthCarriesThePassphrase() async throws {
        try await model.importKey(text: encryptedPrivate, label: "work", passphrase: passphrase)
        let all = try await keys.fetchAll()
        let key = try XCTUnwrap(all.first)

        var host = Host(label: "target", hostname: "target.example", username: "someone")
        host.keyId = key.id
        let saved = try await hosts.save(host)

        let auth = await ConnectionPlanner(hosts: hosts, keys: keys).storedAuth(for: saved)

        guard case .publicKey(_, let carried) = auth else {
            return XCTFail("a host with a key must authenticate with it, got \(String(describing: auth))")
        }
        XCTAssertEqual(carried, passphrase)
    }

    /// Agent forwarding offers every key the app holds, and an encrypted one is
    /// no more signable there than anywhere else.
    func testForwardedIdentitiesCarryThePassphrase() async throws {
        try await model.importKey(text: encryptedPrivate, label: "work", passphrase: passphrase)

        var host = Host(label: "target", hostname: "target.example", username: "someone")
        host.agentForwarding = true

        let params = await ConnectionPlanner(hosts: hosts, keys: keys)
            .params(for: host, auth: .password("x"), hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.agentIdentities.count, 1)
        XCTAssertEqual(params.agentIdentities.first?.passphrase, passphrase)
    }

    // MARK: - Reading the header

    func testIsEncryptedReadsTheHeaderWithoutAPassphrase() {
        XCTAssertTrue(OpenSSHKeyImporter.isEncrypted(encryptedPrivate))
        XCTAssertFalse(OpenSSHKeyImporter.isEncrypted(plainPrivate))
        // Nothing readable: "unreadable", not "missing passphrase".
        XCTAssertFalse(OpenSSHKeyImporter.isEncrypted("not a key at all"))
    }

    func testTheImporterSaysWhetherTheKeyWasEncrypted() throws {
        let encrypted = try OpenSSHKeyImporter.parse(encryptedPrivate, passphrase: passphrase)
        XCTAssertTrue(encrypted.isEncrypted)

        let plain = try OpenSSHKeyImporter.parse(plainPrivate, passphrase: "irrelevant")
        XCTAssertFalse(plain.isEncrypted)
    }
}
