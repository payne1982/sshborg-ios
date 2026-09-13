// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Which algorithms are offered, with and without the legacy option.
///
/// The contract is Android's: JSch's default lists plus `applyLegacyCiphers`.
/// The website's guide documents one list for both apps, so a difference here
/// is a sentence on the site that is false for one of them.
final class SSHAlgorithmsTests: XCTestCase {

    /// The cipher list libssh2 1.11.1 reports with the OpenSSL backend, in its
    /// order.
    private let libssh2Ciphers = [
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com", "aes128-gcm@openssh.com",
        "aes256-ctr", "aes192-ctr", "aes128-ctr",
        "aes256-cbc", "rijndael-cbc@lysator.liu.se", "aes192-cbc", "aes128-cbc",
        "blowfish-cbc", "arcfour128", "arcfour", "cast128-cbc", "3des-cbc",
    ]

    /// And its host key list. There is no `ssh-dss`: this build of OpenSSL
    /// leaves DSA out, so libssh2 compiles its DSA support away — found by this
    /// very test, which first assumed otherwise. A DSA-only server is therefore
    /// out of reach from iOS even with the legacy option, where Android reaches
    /// it; the website's guide says so.
    private let libssh2HostKeys = [
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "ecdsa-sha2-nistp256-cert-v01@openssh.com", "ecdsa-sha2-nistp384-cert-v01@openssh.com",
        "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        "ssh-ed25519", "ssh-ed25519-cert-v01@openssh.com",
        "rsa-sha2-512", "rsa-sha2-256", "rsa-sha2-512-cert-v01@openssh.com", "rsa-sha2-256-cert-v01@openssh.com",
        "ssh-rsa", "ssh-rsa-cert-v01@openssh.com",
    ]

    /// The strings in Android's `SshManager.applyLegacyCiphers`, copied as they
    /// are there.
    func testTheLegacySetsAreAndroids() {
        XCTAssertEqual(SSHAlgorithms.legacyCiphers, Set("aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc".split(separator: ",").map(String.init)))
        XCTAssertEqual(
            SSHAlgorithms.legacyKeyExchanges,
            Set("diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1".split(separator: ",").map(String.init))
        )
        XCTAssertEqual(SSHAlgorithms.legacyHostKeys, ["ssh-dss"])
    }

    func testByDefaultNoCBCCipherIsOffered() {
        let offered = SSHAlgorithms.preference(supported: libssh2Ciphers, legacy: SSHAlgorithms.legacyCiphers, allowLegacy: false)
        XCTAssertEqual(offered, [
            "chacha20-poly1305@openssh.com",
            "aes256-gcm@openssh.com", "aes128-gcm@openssh.com",
            "aes256-ctr", "aes192-ctr", "aes128-ctr",
        ])
    }

    /// The four Android adds, at the back and in libssh2's order — and nothing
    /// Android does not have.
    func testTheLegacyOptionAddsExactlyAndroidsCiphers() {
        let offered = SSHAlgorithms.preference(supported: libssh2Ciphers, legacy: SSHAlgorithms.legacyCiphers, allowLegacy: true)
        XCTAssertEqual(Array(offered.suffix(4)), ["aes256-cbc", "aes192-cbc", "aes128-cbc", "3des-cbc"])
        for name in ["blowfish-cbc", "cast128-cbc", "arcfour", "arcfour128", "rijndael-cbc@lysator.liu.se"] {
            XCTAssertFalse(offered.contains(name), "\(name) is offered with the legacy option")
        }
    }

    /// `ssh-rsa` and its certificate were offered — the certificate even without
    /// the option. Android's JSch offers neither.
    func testSHA1RSAHostKeysAreNeverOffered() {
        for allowLegacy in [false, true] {
            let offered = SSHAlgorithms.preference(supported: libssh2HostKeys, legacy: SSHAlgorithms.legacyHostKeys, allowLegacy: allowLegacy)
            XCTAssertFalse(offered.contains("ssh-rsa"), "allowLegacy = \(allowLegacy)")
            XCTAssertFalse(offered.contains("ssh-rsa-cert-v01@openssh.com"), "allowLegacy = \(allowLegacy)")
            XCTAssertTrue(offered.contains("rsa-sha2-256"), "RSA keys must still work, signed with SHA-2")
        }
    }

    /// Where a library does have DSA, it is offered only with the option — the
    /// Android rule, kept so that a future OpenSSL build with DSA behaves right.
    func testDSAWouldBeLegacyOnly() {
        let withDSA = libssh2HostKeys + ["ssh-dss"]
        for allowLegacy in [false, true] {
            let offered = SSHAlgorithms.preference(supported: withDSA, legacy: SSHAlgorithms.legacyHostKeys, allowLegacy: allowLegacy)
            XCTAssertEqual(offered.contains("ssh-dss"), allowLegacy)
        }
    }

    /// The lists above are what the shipped libssh2 really reports. If an update
    /// changes them, this fails — which is the moment to decide where each new
    /// name belongs, rather than having it offered by default without anyone
    /// choosing to.
    func testTheFixturesAreWhatThisBuildReports() {
        XCTAssertEqual(SSHAlgorithms.supportedByThisBuild(.cipher), libssh2Ciphers)
        XCTAssertEqual(SSHAlgorithms.supportedByThisBuild(.hostKey), libssh2HostKeys)
    }

    /// Every name the lists mention exists in this build, so none of them is a
    /// typo that silently filters nothing. `ssh-dss` is the one known absence.
    func testEveryLegacyNameIsOneLibssh2Knows() {
        let known = Set(SSHAlgorithms.supportedByThisBuild(.cipher))
            .union(SSHAlgorithms.supportedByThisBuild(.hostKey))
            .union(SSHAlgorithms.supportedByThisBuild(.keyExchange))
        let legacy = SSHAlgorithms.legacyCiphers.union(SSHAlgorithms.legacyKeyExchanges).union(SSHAlgorithms.legacyHostKeys)
        XCTAssertEqual(legacy.subtracting(known), ["ssh-dss"])
    }

    func testTheNeverOfferedAndLegacySetsDoNotOverlap() {
        let legacy = SSHAlgorithms.legacyCiphers.union(SSHAlgorithms.legacyKeyExchanges).union(SSHAlgorithms.legacyHostKeys)
        XCTAssertTrue(legacy.isDisjoint(with: SSHAlgorithms.neverOffered))
    }
}
