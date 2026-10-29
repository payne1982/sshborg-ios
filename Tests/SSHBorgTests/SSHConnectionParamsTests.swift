// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// These parsers read strings the user typed and strings restored from a
/// backup, and both are stored in the exact same format as on Android. They are
/// pure logic, so unlike the rest of the SSH layer they can be pinned down
/// without a server.
final class SSHConnectionParamsTests: XCTestCase {

    // MARK: - Port forwarding

    func testThreePartForwardingUsesLoopbackBind() {
        let rules = PortForwarding.parseList("8080:localhost:80")
        XCTAssertEqual(rules, [
            PortForwarding(bindAddress: "127.0.0.1", localPort: 8080, remoteHost: "localhost", remotePort: 80)
        ])
    }

    func testFourPartForwardingUsesExplicitBind() {
        let rules = PortForwarding.parseList("0.0.0.0:5432:db.internal:5432")
        XCTAssertEqual(rules, [
            PortForwarding(bindAddress: "0.0.0.0", localPort: 5432, remoteHost: "db.internal", remotePort: 5432)
        ])
    }

    func testMultipleRulesOnSeparateLines() {
        let rules = PortForwarding.parseList("8080:localhost:80\n3306:db:3306")
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[1].remoteHost, "db")
    }

    /// A malformed line must be skipped rather than failing the connection.
    func testUnparsableLinesAreSkipped() {
        let rules = PortForwarding.parseList("""
        8080:localhost:80
        this is not a rule
        notaport:host:80

        3306:db:3306
        """)
        XCTAssertEqual(rules.map(\.localPort), [8080, 3306])
    }

    /// The Android parser tolerates a leading `-L`, so this one must too.
    func testLeadingDashLIsAccepted() {
        let rules = PortForwarding.parseList("-L 8080:localhost:80")
        XCTAssertEqual(rules.first?.localPort, 8080)
    }

    func testEmptyInputYieldsNoRules() {
        XCTAssertTrue(PortForwarding.parseList(nil).isEmpty)
        XCTAssertTrue(PortForwarding.parseList("").isEmpty)
        XCTAssertTrue(PortForwarding.parseList("   \n  ").isEmpty)
    }

    // MARK: - Jump hosts

    func testBareHostDefaultsToPort22() {
        let hops = JumpHost.parseList("bastion.example.com", knownHostKeys: nil)
        XCTAssertEqual(hops.count, 1)
        XCTAssertEqual(hops[0].host, "bastion.example.com")
        XCTAssertEqual(hops[0].port, 22)
        XCTAssertNil(hops[0].username)
    }

    func testUsernameAndPortAreParsed() {
        let hops = JumpHost.parseList("admin@bastion:2222", knownHostKeys: nil)
        XCTAssertEqual(hops[0].username, "admin")
        XCTAssertEqual(hops[0].host, "bastion")
        XCTAssertEqual(hops[0].port, 2222)
    }

    func testChainKeepsOrder() {
        let hops = JumpHost.parseList("first:22, second:2222 ,third", knownHostKeys: nil)
        XCTAssertEqual(hops.map(\.host), ["first", "second", "third"])
        XCTAssertEqual(hops.map(\.port), [22, 2222, 22])
    }

    /// A dotted hostname must never be mangled by the port split, and a
    /// non-numeric or out-of-range suffix is not a port.
    func testHostnamesAreNotMistakenForPorts() {
        XCTAssertEqual(
            JumpHost.parseList("server.example.com", knownHostKeys: nil).first?.host,
            "server.example.com"
        )
        XCTAssertEqual(
            JumpHost.parseList("host:notaport", knownHostKeys: nil).first?.host,
            "host:notaport"
        )
        XCTAssertEqual(
            JumpHost.parseList("host:99999", knownHostKeys: nil).first?.host,
            "host:99999"
        )
    }

    func testStoredKeysAreMatchedToTheRightHop() {
        let blob = """
        bastion ssh-ed25519 AAAAFIRST
        [other]:2222 ssh-rsa AAAASECOND
        """

        let hops = JumpHost.parseList("bastion,other:2222,unknown", knownHostKeys: blob)

        XCTAssertEqual(hops[0].knownHostsEntry, "bastion ssh-ed25519 AAAAFIRST")
        XCTAssertEqual(hops[1].knownHostsEntry, "[other]:2222 ssh-rsa AAAASECOND")
        XCTAssertNil(hops[2].knownHostsEntry, "a hop with no stored key must connect on trust-on-first-use")
    }

    func testEmptyJumpChain() {
        XCTAssertTrue(JumpHost.parseList(nil, knownHostKeys: nil).isEmpty)
        XCTAssertTrue(JumpHost.parseList("", knownHostKeys: nil).isEmpty)
        XCTAssertTrue(JumpHost.parseList(" , , ", knownHostKeys: nil).isEmpty)
    }

    // MARK: - Which family to try first

    /// A preference and never a filter: every resolved address is still tried,
    /// the preferred family simply goes first. A host that only has one of the
    /// two must still connect, which is what a filter would break.
    func testThePreferredFamilyGoesFirstAndNothingIsDropped() {
        let families = [AF_INET6, AF_INET, AF_INET6]

        XCTAssertEqual(
            SSHSocket.attemptOrder(of: families, preferring: .auto),
            [0, 1, 2],
            "no preference must leave the resolver's own order alone"
        )
        XCTAssertEqual(SSHSocket.attemptOrder(of: families, preferring: .ipv4), [1, 0, 2])
        XCTAssertEqual(SSHSocket.attemptOrder(of: families, preferring: .ipv6), [0, 2, 1])
    }

    /// Asking for a family a name does not have is not an error: there is
    /// nothing to put first, and the rest is tried in order.
    func testAPreferenceForAFamilyThatIsNotThereChangesNothing() {
        XCTAssertEqual(SSHSocket.attemptOrder(of: [AF_INET], preferring: .ipv6), [0])
        XCTAssertEqual(SSHSocket.attemptOrder(of: [], preferring: .ipv4), [])
    }

    /// Anything else in the column means no preference, which is what a database
    /// written before the setting existed has to keep doing.
    func testAnUnreadableColumnMeansNoPreference() {
        XCTAssertEqual(SSHSocket.AddressPreference(column: nil), .auto)
        XCTAssertEqual(SSHSocket.AddressPreference(column: ""), .auto)
        XCTAssertEqual(SSHSocket.AddressPreference(column: "IPv4"), .auto)
        XCTAssertEqual(SSHSocket.AddressPreference(column: "ipv4"), .ipv4)
        XCTAssertEqual(SSHSocket.AddressPreference(column: "ipv6"), .ipv6)
    }
}
