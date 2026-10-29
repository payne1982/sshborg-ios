// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The line typed into a bastion's terminal to reach what is behind it.
///
/// Two things are being guarded. The shape — because the command is walked by
/// somebody else's ssh client, and a wrong flag is a failure on a machine we
/// cannot see — and the fact that it is typed into a *shell*, which is the part
/// that would otherwise go unnoticed until the day a host name holds a
/// semicolon.
final class BastionHopTests: XCTestCase {

    private typealias Endpoint = BastionHop.Endpoint

    func testTheBastionAloneNeedsNoJumpAtAll() {
        XCTAssertEqual(
            BastionHop.compose(target: Endpoint(user: "alice", host: "target.example.com")),
            "ssh alice@target.example.com"
        )
    }

    func testAPortThatIsNotTheDefaultIsCarriedAsAFlag() {
        XCTAssertEqual(
            BastionHop.compose(target: Endpoint(user: "alice", host: "target.example.com", port: 2222)),
            "ssh -p 2222 alice@target.example.com"
        )
    }

    func testTheHopsAfterTheBastionAreHandedToSshAsOneChain() {
        XCTAssertEqual(
            BastionHop.compose(
                target: Endpoint(user: "alice", host: "target", port: 2222),
                through: [
                    Endpoint(user: "bob", host: "mid.example.com"),
                    Endpoint(user: "carol", host: "inner.example.com", port: 2022),
                ]
            ),
            "ssh -J bob@mid.example.com,carol@inner.example.com:2022 -p 2222 alice@target"
        )
    }

    func testAnAddressWithColonsInItGetsTheBracketsSshAsksFor() {
        XCTAssertEqual(
            BastionHop.compose(
                target: Endpoint(user: "alice", host: "2001:db8::2"),
                through: [Endpoint(user: "bob", host: "2001:db8::1", port: 2022)]
            ),
            "ssh -J bob@[2001:db8::1]:2022 alice@2001:db8::2"
        )
    }

    func testBracketsAlreadyThereAreLeftAlone() {
        XCTAssertEqual(
            BastionHop.compose(
                target: Endpoint(user: "alice", host: "host"),
                through: [Endpoint(user: "bob", host: "[2001:db8::1]")]
            ),
            "ssh -J bob@[2001:db8::1] alice@host"
        )
    }

    /// The one that matters. Nothing composed here is quoted, so anything a
    /// shell would read as more than a name means **no line at all** — the
    /// caller then connects the ordinary way rather than typing half a command
    /// on somebody's bastion.
    func testANameAShellWouldReadAsSomethingElseComposesNothing() {
        for name in [
            "host; rm -rf /", "host$(id)", "host`id`", "host name", "host'quote",
            "host\"quote", "host|pipe", "host&background", "host\nnewline", "host>redirect",
            "host\\escape", "host#comment", "host{brace}", "host*glob", "host~tilde",
            "hóst", "",
        ] {
            XCTAssertNil(
                BastionHop.compose(target: Endpoint(user: "alice", host: name)),
                "a host name was accepted: \(name.debugDescription)"
            )
            XCTAssertNil(
                BastionHop.compose(target: Endpoint(user: name, host: "host")),
                "a user name was accepted: \(name.debugDescription)"
            )
            XCTAssertNil(
                BastionHop.compose(
                    target: Endpoint(user: "alice", host: "host"),
                    through: [Endpoint(user: "bob", host: name)]
                ),
                "a hop was accepted: \(name.debugDescription)"
            )
        }
    }

    /// The character set does not close this one by itself: `-oProxyCommand` is
    /// made entirely of characters a host name may legally contain, and a token
    /// beginning with a dash is an option to the client rather than a machine to
    /// reach.
    func testANameSshWouldReadAsAnOptionComposesNothing() {
        for name in ["-oProxyCommand=id", "-F", "-l", "--", "-"] {
            XCTAssertNil(
                BastionHop.compose(target: Endpoint(user: "alice", host: name)),
                "a host name was accepted: \(name)"
            )
            XCTAssertNil(
                BastionHop.compose(target: Endpoint(user: name, host: "host")),
                "a user name was accepted: \(name)"
            )
            XCTAssertNil(
                BastionHop.compose(
                    target: Endpoint(user: "alice", host: "host"),
                    through: [Endpoint(user: "bob", host: name)]
                ),
                "a hop was accepted: \(name)"
            )
        }

        // And a dash anywhere else is an ordinary character in an ordinary name.
        XCTAssertNotNil(BastionHop.compose(target: Endpoint(user: "alice", host: "web-01.example.com")))
        XCTAssertNotNil(BastionHop.compose(target: Endpoint(user: "a-b", host: "host")))
    }

    func testAPortOutsideTheRangeComposesNothing() {
        for port in [0, -1, 65536, 100000] {
            XCTAssertNil(
                BastionHop.compose(target: Endpoint(user: "alice", host: "host", port: port)),
                "port \(port) was accepted"
            )
            XCTAssertNil(
                BastionHop.compose(
                    target: Endpoint(user: "alice", host: "host"),
                    through: [Endpoint(user: "bob", host: "hop", port: port)]
                ),
                "a hop on port \(port) was accepted"
            )
        }
    }

    /// Every name this composes is one the user typed into the host form, so the
    /// shapes that actually turn up have to go through.
    func testTheNamesPeopleReallyUseGoThrough() {
        for host in [
            "example.com", "web-01.example.com", "192.168.1.10", "2001:db8::1",
            "fe80::1%en0", "[fe80::1%en0]", "host_name", "a.b.c.d.e.f", "HOST",
        ] {
            XCTAssertNotNil(
                BastionHop.compose(target: Endpoint(user: "root", host: host)),
                "a real host name was refused: \(host)"
            )
        }
    }

    // MARK: - Which arrangement the stored rows describe

    /// The whole decision is the first hop's own switch, and nothing on the
    /// host's row: a host whose first hop has mosh is walked from it, and one
    /// whose first hop has mosh off is tunnelled exactly as before.
    func testTheFirstHopsSwitchDecidesTheArrangement() async throws {
        let database = try AppDatabase.makeInMemory()
        let hosts = HostRepository(database)
        let keys = SSHKeyRepository(database)
        let planner = ConnectionPlanner(hosts: hosts, keys: keys)

        var bastion = Host(label: "bastion", hostname: "edge.example", username: "me")
        bastion.mosh = true
        let savedBastion = try await hosts.save(bastion)

        var middle = Host(label: "middle", hostname: "mid.example", username: "me")
        middle.port = 2222
        let savedMiddle = try await hosts.save(middle)

        var target = Host(label: "target", hostname: "inner.example", username: "you")
        target.jumpMode = Host.JumpMode.hostList.rawValue
        target.jumpHostIdList = Host.formatIDList([savedBastion.id!, savedMiddle.id!])
        let savedTarget = try await hosts.save(target)

        let walk = await planner.bastionWalk(for: savedTarget)
        XCTAssertEqual(walk?.bastion.id, savedBastion.id)
        XCTAssertEqual(walk?.line, "ssh -J me@mid.example:2222 you@inner.example")

        // The same chain with the switch off is nobody's bastion.
        var plain = savedBastion
        plain.mosh = false
        _ = try await hosts.save(plain)
        let tunnelled = await planner.bastionWalk(for: savedTarget)
        XCTAssertNil(tunnelled, "a chain whose first hop has mosh off must be tunnelled")
    }

    /// Typed text carries no switch to read, which is not a gap: a hop nobody
    /// has a record of is a hop nothing is known about.
    func testATypedChainIsNeverWalkedFromABastion() async throws {
        let database = try AppDatabase.makeInMemory()
        let hosts = HostRepository(database)
        let planner = ConnectionPlanner(hosts: hosts, keys: SSHKeyRepository(database))

        var target = Host(label: "target", hostname: "inner.example", username: "you")
        target.jumpMode = Host.JumpMode.simple.rawValue
        target.jumpHosts = "me@edge.example"
        let saved = try await hosts.save(target)

        let walk = await planner.bastionWalk(for: saved)
        XCTAssertNil(walk)
    }
}
