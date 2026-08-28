// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Renaming a key changes its name. The question these pin down is what *else*
/// it is allowed to change, because the public line carries the label as its
/// comment and the private half must not be touched at all.
@MainActor
final class KeyRenameTests: XCTestCase {

    private var repository: SSHKeyRepository!
    private var model: KeysModel!

    override func setUpWithError() throws {
        let database = try AppDatabase.makeInMemory()
        repository = SSHKeyRepository(database)

        let suiteName = "key-rename-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        model = KeysModel(repository: repository, preferences: AppPreferences(defaults: defaults))
    }

    private func makeKey(label: String, comment: String?) -> SSHKey {
        // A real ed25519 public blob: `string "ssh-ed25519"` then a 32-byte
        // key. It has to decode as base64 or the fingerprint would be nil, and
        // the test that pins the fingerprint would pass by comparing nothing.
        let body = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
        return SSHKey(
            label: label,
            keyType: SSHKey.KeyType.ed25519.rawValue,
            privateKeyPem: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----",
            publicKey: comment.map { "\(body) \($0)" } ?? body
        )
    }

    // MARK: - The comment

    /// A generated key's comment is its label, so it follows the label.
    func testTheCommentFollowsTheLabelWhenItWasTheLabel() {
        let renamed = KeysModel.publicKey(
            "ssh-ed25519 AAAAB3 laptop",
            renamedFrom: "laptop",
            to: "nas backup"
        )
        XCTAssertEqual(renamed, "ssh-ed25519 AAAAB3 nas backup")
    }

    /// An imported key's comment is usually `user@host` and means something of
    /// its own. Renaming the key here must not overwrite it.
    func testACommentThatIsNotTheLabelIsLeftAlone() {
        let line = "ssh-ed25519 AAAAB3 payne@dev-host"
        XCTAssertEqual(
            KeysModel.publicKey(line, renamedFrom: "work key", to: "home key"),
            line
        )
    }

    func testAPublicLineWithNoCommentStaysWithoutOne() {
        let line = "ssh-ed25519 AAAAB3"
        XCTAssertEqual(KeysModel.publicKey(line, renamedFrom: "laptop", to: "desktop"), line)
    }

    /// The comment is everything after the second field, spaces and all — it
    /// must be matched and replaced whole, not just its first word.
    func testACommentWithSpacesIsMatchedWhole() {
        let renamed = KeysModel.publicKey(
            "ssh-ed25519 AAAAB3 my laptop key",
            renamedFrom: "my laptop key",
            to: "server"
        )
        XCTAssertEqual(renamed, "ssh-ed25519 AAAAB3 server")
    }

    // MARK: - Through the model

    func testRenamingStoresTheNewNameAndKeepsThePrivateHalf() async throws {
        let stored = try await repository.save(makeKey(label: "laptop", comment: "laptop"))

        try await model.rename(stored, to: "  nas  ")

        let all = try await repository.fetchAll()
        XCTAssertEqual(all.count, 1, "a rename inserted a second key instead of updating one")
        XCTAssertEqual(all[0].label, "nas", "the new name was not trimmed")
        XCTAssertEqual(all[0].privateKeyPem, stored.privateKeyPem)
        XCTAssertEqual(all[0].encryptedBlob, stored.encryptedBlob)
        XCTAssertTrue(all[0].publicKey.hasSuffix(" nas"))
    }

    /// The fingerprint is the key's identity on every server it is installed on.
    /// Renaming must not touch it, or the rename would silently lock the user
    /// out of the machines that key opens.
    func testTheFingerprintIsUnchanged() async throws {
        let stored = try await repository.save(makeKey(label: "laptop", comment: "laptop"))
        let before = stored.fingerprint

        try await model.rename(stored, to: "nas")

        let all = try await repository.fetchAll()
        XCTAssertNotNil(before)
        XCTAssertEqual(all[0].fingerprint, before)
    }

    /// A blank name is not a name. The alert cannot disable its own Save button
    /// as the field is typed into, so refusing here is the only guard there is.
    func testABlankNameIsRefused() async throws {
        let stored = try await repository.save(makeKey(label: "laptop", comment: "laptop"))

        try await model.rename(stored, to: "   ")

        let all = try await repository.fetchAll()
        XCTAssertEqual(all[0].label, "laptop")
    }
}
