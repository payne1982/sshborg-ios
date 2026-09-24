// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// An encrypted private key is unlocked once, at import, and stored unlocked.
///
/// Reported on Android as #18 and true here in the same way: the import asked
/// for the passphrase, used it to derive the public half and threw it away, then
/// stored the key still encrypted. Every connection afterwards handed libssh2 a
/// key it could not read, and failed with nothing on screen saying why.
///
/// The first fix kept the passphrase beside the key. The GitHub issue pointed
/// out why that is worse than unlocking: a passphrase is a human secret, usually
/// reused on other keys and other machines, while a private key is worth only
/// itself — and a key stored next to its own passphrase was never protected by
/// it anyway. So the passphrase is used once and dropped, and it is the key
/// that is stored, unlocked, exactly as a generated one is.
///
/// The fixtures are throwaway keys written by the real `ssh-keygen` for this
/// file, with their own `.pub` files as the judge: what the importer would store
/// is read back and its public half must match, byte for byte, the public key
/// OpenSSH itself derived.
@MainActor
final class KeyPassphraseTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var preferences: AppPreferences!
    private var model: KeysModel!

    // MARK: - Fixtures

    private let encryptedEd25519 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC0Xwfw4v
    lJKDn148+Q/Q61AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFpgB4BIgMx8yv8s
    b7JpQ8JwuZipvqJGXryWzQklBczWAAAAoBWS76rlF4Hus/N3QomgV3Z+egLClmcqERV1Ox
    dRbSUPCar65NBcfwFUdcth4mCEMQXUNVYSVNd0NoBJrt5gvdDh+y1KPy4EeQyUb3/AyEzD
    IGKnRYMOEKU8rB2xDxDqyVQCfCfWdYl0YVZr6ohDyld9sP9tKkHlnjCkgh0w9JoGBxfg4E
    ZSlRo0eFGqowrHxNyi9n44nZkIhL7RqdJjwMw=
    -----END OPENSSH PRIVATE KEY-----
    """

    private let encryptedEd25519Public =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFpgB4BIgMx8yv8sb7JpQ8JwuZipvqJGXryWzQklBczW fixture-encrypted"

    private let encryptedECDSA = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAk6ggr77
        eSRTn4z6waoldpAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBLn/4mnk13EP4TeFjVcAc4I155WakFV5Rmfc7+HWPJM/GLPDFnXn/X2z33
        ZjcgP/H3xDQP3ch6dUDlPMY+Q+I9oAAACwJHhB8Bf00/JKzhnP98Fe9uQEwhQTk5H5tCg5
        gES73T6PKEiM/6au0AuukD8YAvbI9lHhjJIRi88zFMAnBYFECdopNBllV4RtcoOYd9U1MG
        EgwZBDWyBmB30iq3Szl7PoMWSGPVrsCsRyxiW13WCk+0Z9z9+yHguJQmql102G2/89CBQA
        lCnWJJHdZMU3+AyMj2ZY6zx6xRCHKBwLuQByGG4c8jJBIPmzhYwygnDvXhk=
        -----END OPENSSH PRIVATE KEY-----
        """

    

    private let encryptedECDSAPublic =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLn/4mnk13EP4TeFjVcAc4I155WakFV5Rmfc7+HWPJM/GLPDFnXn/X2z33ZjcgP/H3xDQP3ch6dUDlPMY+Q+I9o= fixture-ecdsa-enc"

    private let encryptedRSA = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCpJfQelU
        104N9aFlqreoWqAAAAGAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQDOrJkg8rJt
        oK0EbTZ0ghxQk1AxUTOYk0nw05eW4Asx5CaCuuZsgTCDcKCG0zUkLnO//8RBZyg7TyY7gH
        tlt/4Fv5KwFrquoE4zeNXpoJnGeQQq3Kc5BOK8GLNxo9iyMp2hTn2BLF6aG7vU7AtyC03/
        pMHC///oKtum0E5U9dDohCXyco1wA0ckYmsZa38LbUjBrx/03FvhQXEiugeWfNpU/3M/z9
        +mywvpPIZ3LeLUU1I774WSnwyCCrofKZO6gH7J6dYEQRK5qwq6U2BB92AT7oBD7yTq/Jju
        Wjn6QxrbOaYZ+nadJWHeqq5X/S4BL7RR+vp6yLGXTrvjYtM67eojAAAD0DpLQh3vX/rAkD
        IMQi3Cyil4YuQTVTu1Bb6lFPO7x9+CBvqr58QyUSeoDvCKx7G/SRqcJ0P7znKOokRzYKyP
        foG3p9y1Eaj5XRsZzRLrgILuEiixpWE/vePpRzerQZxiuun1hACj7yTiRxOxLakMOwnOGZ
        KzaauTDSz+NJYlfp8SC+6sBwFc26zhTNx/5x13Du+H3UxPbLM1zD03ewQ/ZHUr/exB5XdQ
        Pds7CNkfo5NspzdvWRe+jLgCUqk/aBhPWr9yjE/FoS/u4g30O+9CbL3QE4ITnzckfb8X9f
        oCFDogc5P5jALKcEXTh4+CZ2LC/yy4wlX4WS+2Zgcum03eyCMVqpRGcmAil7XzSP5JTnRs
        CH72ufLod1TiQTYcUynxAM8mZLawAgl5WnLVzOjMP+93mX4lcr9RUjkEOdY2IWffFlikqk
        dQvfDjdZ2pQS1dMnCg6bZtnTcxUUHSo/ZwvrXgv/f9LUX9m61XytI05aYeqhFTZV9/GYCq
        gOsfF9p40ij6Wnn3XvUPU4y1nr7GQgTIi1VqPeJe7vtKRvfd19jHSWyn+sCw6KfIolGJaX
        pXxwBq2OzQmMwu8U1Mq6HN2hrsKwtJlNROj4jCAeOdwKr/kbowpcHc4mmeGshmVAuz/g6/
        i93pgHl2YMiGYogrjg98BYZelg72eSbuCdUCsc5ea2ye5yRb52owKS85jkTDVe/Kg043lF
        4DtSYhaPALb49ZNR2IC9R5lqyVToE3+5CImou/MZNYDZgNMpYmN/KnpUtvWNGV6K3IIbxu
        jVpBCa89IP85v0wtTZLxkryDlOU6vr//TBSgAkmESVZ6JLjAuSmGRpBquiHMTKP07P4kCU
        1YSrxMv5oWFlOyiH9uMvjdIUWhLFWKBbIW1y5B1B73xAghIg9LO4Y9ftqJXvkcNtyeGIjk
        xhsoaiMeIXrJpDpaRe1Ah5zAuLayqXDV5AnyLZCyNcDWIWFM7ait0JcjgodailImWI5oQa
        4eUDQlkKCzGnn+bFhpGxzHIe7xBV+93lWIlG8kY88rK3E9SpH7pKBTl7V4OQ1QXEe1DcTv
        B09YUjIxHMDAkK5rkS9hGmRpzBH8x377pVhxzgivloG1yeNismYs4CMNjhsA5l1S3SdF2L
        sKwNnrDQRl1qnEi41yHiJSdPJA9t9TWJbx14j6oUSGXSyEB7ZzhnI6ZxoIgV7sviQljXlj
        +0nezb3+wB2mdeyMP5onZFuiputt/FV0ZmkDDII2X+vopWYGxUg+f5CiPi7jz0LIB7q4eB
        ZFLehV2rOO4FJ4Ry1xn6JNdDCp+N0=
        -----END OPENSSH PRIVATE KEY-----
        """

    

    private let encryptedRSAPublic =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOrJkg8rJtoK0EbTZ0ghxQk1AxUTOYk0nw05eW4Asx5CaCuuZsgTCDcKCG0zUkLnO//8RBZyg7TyY7gHtlt/4Fv5KwFrquoE4zeNXpoJnGeQQq3Kc5BOK8GLNxo9iyMp2hTn2BLF6aG7vU7AtyC03/pMHC///oKtum0E5U9dDohCXyco1wA0ckYmsZa38LbUjBrx/03FvhQXEiugeWfNpU/3M/z9+mywvpPIZ3LeLUU1I774WSnwyCCrofKZO6gH7J6dYEQRK5qwq6U2BB92AT7oBD7yTq/JjuWjn6QxrbOaYZ+nadJWHeqq5X/S4BL7RR+vp6yLGXTrvjYtM67eoj fixture-rsa-enc"

    private let plainEd25519 = """
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
        // at all (-34018), and none of this is about where the at-rest key is
        // kept. `EncryptionMigrationTests` covers that side.
        preferences = AppPreferences(
            defaults: UserDefaults(suiteName: "passphrase.\(UUID().uuidString)")!
        )
        preferences.keychainEncryption = false
        model = KeysModel(repository: keys, preferences: preferences)
    }

    // MARK: - Unlocking

    /// Every key type `ssh-keygen` writes, with `ssh-keygen`'s own `.pub` as the
    /// judge of what came out.
    func testAnEncryptedKeyIsStoredUnlocked() throws {
        let cases = [
            ("ed25519", encryptedEd25519, encryptedEd25519Public),
            ("ecdsa", encryptedECDSA, encryptedECDSAPublic),
            ("rsa", encryptedRSA, encryptedRSAPublic),
        ]

        for (name, pem, publicLine) in cases {
            let imported = try OpenSSHKeyImporter.parse(pem, passphrase: passphrase)

            XCTAssertFalse(
                OpenSSHKeyImporter.isEncrypted(imported.privateKeyPEM),
                "\(name): the stored key is still encrypted"
            )
            XCTAssertEqual(imported.publicKeyLine, publicLine, "\(name): wrong public key")

            // And what was stored really is that key: read it back with no
            // passphrase and derive its public half again.
            let reread = try OpenSSHKeyImporter.parse(imported.privateKeyPEM)
            XCTAssertEqual(reread.publicKeyLine, publicLine, "\(name): the stored key is a different key")
            XCTAssertEqual(reread.type, imported.type)
        }
    }

    /// The private half has to survive too — a file whose public key matches and
    /// whose private fields do not is the one failure that would look fine here
    /// and fail on the server.
    func testTheUnlockedKeyKeepsItsPrivateFields() throws {
        let original = try OpenSSHPrivateKeyFile.parse(pem: encryptedEd25519, passphrase: passphrase)
        let imported = try OpenSSHKeyImporter.parse(encryptedEd25519, passphrase: passphrase)

        let stored = try OpenSSHPrivateKeyFile.parse(pem: imported.privateKeyPEM)
        XCTAssertEqual(stored.privateFields, original.privateFields)
        XCTAssertEqual(stored.publicBlob, original.publicBlob)
        XCTAssertEqual(stored.comment, original.comment)
    }

    /// A key that arrived in the clear is filed exactly as it arrived.
    func testAnUnencryptedKeyIsNotRewritten() throws {
        let imported = try OpenSSHKeyImporter.parse(plainEd25519)
        XCTAssertEqual(imported.privateKeyPEM, plainEd25519 + "\n")
    }

    func testTheWrongPassphraseStillFails() {
        XCTAssertThrowsError(try OpenSSHKeyImporter.parse(encryptedRSA, passphrase: "nope")) { error in
            XCTAssertEqual(error as? OpenSSHKeyImporter.ImportError, .wrongPassphrase)
        }
    }

    // MARK: - What cannot be unlocked

    /// PKCS#8 and PuTTY carry their own encryption, which is not this format's,
    /// and "that does not look like a private key" would send the user looking
    /// for the wrong problem.
    func testContainersThatCannotBeUnlockedSaySo() {
        let pkcs8 = """
        -----BEGIN ENCRYPTED PRIVATE KEY-----
        MIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQItest
        -----END ENCRYPTED PRIVATE KEY-----
        """
        let putty = """
        PuTTY-User-Key-File-3: ssh-ed25519
        Encryption: aes256-cbc
        """

        for text in [pkcs8, putty] {
            XCTAssertThrowsError(try OpenSSHKeyImporter.parse(text)) { error in
                XCTAssertEqual(error as? OpenSSHKeyImporter.ImportError, .unsupportedEncryption)
            }
        }
    }

    /// The older OpenSSL PEM encryption is the same answer: decrypt it where it
    /// was made.
    func testLegacyEncryptedPEMSaysTheSameThing() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF

        bm90IHJlYWxseSBhIGtleQ==
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHKeyImporter.parse(pem)) { error in
            XCTAssertEqual(error as? OpenSSHKeyImporter.ImportError, .unsupportedEncryption)
        }
    }

    // MARK: - Through the model

    func testImportingStoresAKeyThatCanAuthenticate() async throws {
        try await model.importKey(text: encryptedEd25519, label: "work", passphrase: passphrase)

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        let pem = try XCTUnwrap(KeychainCrypto.privateKeyPEM(for: stored))
        XCTAssertFalse(OpenSSHKeyImporter.isEncrypted(pem))
        XCTAssertFalse(model.needsPassphrase(stored), "a freshly imported key is flagged as unusable")

        var host = Host(label: "target", hostname: "target.example", username: "someone")
        host.keyId = stored.id
        let saved = try await hosts.save(host)

        let auth = await ConnectionPlanner(hosts: hosts, keys: keys).storedAuth(for: saved)
        guard case .publicKey(let carried, let secret) = auth else {
            return XCTFail("a host with a key must authenticate with it, got \(String(describing: auth))")
        }
        XCTAssertFalse(OpenSSHKeyImporter.isEncrypted(carried))
        XCTAssertNil(secret, "nothing should be supplying a passphrase any more")
    }

    /// Keys imported by a released version are still encrypted and still cannot
    /// authenticate, so the list has to keep marking them: nothing anywhere can
    /// unlock them, and the passphrase is only ever asked for at import.
    func testAKeyFromAReleasedVersionIsStillFlagged() async throws {
        var orphan = SSHKey(label: "old", keyType: "ED25519", publicKey: "ssh-ed25519 AAAA")
        orphan.privateKeyPem = encryptedEd25519
        let stored = try await keys.save(orphan)

        XCTAssertTrue(model.needsPassphrase(stored))
    }

    func testAGeneratedKeyIsNeverFlagged() async throws {
        try await model.generate(type: .ed25519, bits: nil, label: "fresh")

        let all = try await keys.fetchAll()
        let stored = try XCTUnwrap(all.first)
        XCTAssertFalse(model.needsPassphrase(stored))
    }
}
