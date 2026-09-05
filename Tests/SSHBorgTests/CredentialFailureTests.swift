// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Being told *why* a connection could not use its key.
///
/// Three different failures used to look identical from the outside. A host with
/// nothing saved, a host whose key record had gone, and a host whose key would
/// not come back out of the Keychain all ended at the password prompt — the last
/// two with nothing on screen saying why, on a host the user had deliberately
/// configured with a key.
///
/// Underneath, two of them were the same `SSHError.invalidPrivateKey`, whose
/// text offers "it may be corrupt, or the passphrase may be wrong" about a
/// passphrase nobody was ever asked for.
///
/// No server needed: `connect()` resolves the credential before it opens a
/// socket, so everything here happens long before the network.
@MainActor
final class CredentialFailureTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
    }

    /// A host with no key and nothing saved is a fair question, and stays one.
    func testNothingSavedStillAsksForAPassword() async throws {
        let host = Host(label: "bare", hostname: "example.invalid", username: "user")
        let session = TerminalSession(host: try await hosts.save(host), hosts: hosts, keys: keys)

        await session.connect()

        XCTAssertEqual(
            session.phase, .needsPassword,
            "with nothing stored there is nothing to report — asking is the right answer"
        )

        session.disconnect()
    }

    /// Why `keyNotFound` is a defensive branch and not a state a user reaches.
    ///
    /// The schema will not allow a host to point at a key that is not there:
    /// `keyId` references `ssh_keys` with `onDelete: .setNull`, so deleting a
    /// key empties the column on every host using it rather than leaving a
    /// dangling id — and the foreign key refuses to insert one in the first
    /// place. That invariant is what this pins. If it is ever relaxed, the
    /// branch stops being defensive and its message starts being read.
    func testDeletingAKeyEmptiesItsHostsRatherThanDanglingThem() async throws {
        let key = try await keys.save(
            SSHKey(label: "temp", keyType: "ed25519", privateKeyPem: "", publicKey: "ssh-ed25519 AAAA")
        )
        var host = Host(label: "keyed", hostname: "example.invalid", username: "user")
        host.keyId = key.id
        let saved = try await hosts.save(host)
        XCTAssertNotNil(saved.keyId)

        try await keys.delete(key)

        let reloaded = try await hosts.fetch(id: try XCTUnwrap(saved.id))
        XCTAssertNil(
            reloaded?.keyId,
            "the host has to fall back to password auth, not point at a key that is gone"
        )

        // And what that means at the connection: a fair question, not an error.
        let session = TerminalSession(host: try XCTUnwrap(reloaded), hosts: hosts, keys: keys)
        await session.connect()
        XCTAssertEqual(session.phase, .needsPassword)
        session.disconnect()
    }

    /// The three failures are three errors, and each says its own thing.
    func testTheKeyErrorsAreDistinctAndSayDifferentThings() {
        let messages = [SSHError.invalidPrivateKey, .keyNotFound, .keyUnreadable]
            .compactMap(\.errorDescription)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(Set(messages).count, 3, "two of these used to be the same case")

        // Only the parse failure has any business mentioning a passphrase: it is
        // the one case where key material was actually handed to libssh2.
        XCTAssertTrue(SSHError.invalidPrivateKey.errorDescription!.contains("passphrase"))
        XCTAssertFalse(SSHError.keyNotFound.errorDescription!.contains("passphrase"))
        XCTAssertFalse(SSHError.keyUnreadable.errorDescription!.contains("passphrase"))
    }
}
