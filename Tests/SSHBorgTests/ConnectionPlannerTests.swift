// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// Checks the translation from a stored host to connection parameters.
///
/// This is where "saved but inert" was living: the editor wrote jump hosts and
/// port forwards into the record and nothing turned them into anything. So the
/// assertions worth having are the ones that fail if a field stops being
/// carried across, not the ones that re-check the parsers — those have tests of
/// their own.
final class ConnectionPlannerTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var planner: ConnectionPlanner!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
        planner = ConnectionPlanner(hosts: hosts, keys: keys)
    }

    private func makeHost(_ configure: (inout Host) -> Void = { _ in }) -> Host {
        var host = Host(label: "target", hostname: "target.example", username: "someone")
        configure(&host)
        return host
    }

    private let auth = SSHAuth.password("secret")

    // MARK: - The fields that used to be dropped

    func testPortForwardingRulesReachTheParameters() async {
        let host = makeHost { $0.portForwardings = "8080:internal:80\n127.0.0.1:5432:db:5432" }

        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.portForwardings.count, 2)
        XCTAssertEqual(params.portForwardings.first?.localPort, 8080)
        XCTAssertEqual(params.portForwardings.first?.remoteHost, "internal")
        XCTAssertEqual(params.portForwardings.last?.bindAddress, "127.0.0.1")
    }

    func testSimpleJumpHostsReachTheParameters() async {
        let host = makeHost {
            $0.jumpMode = Host.JumpMode.simple.rawValue
            $0.jumpHosts = "bastion.example:2222,second.example"
        }

        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.jumpHosts.count, 2)
        XCTAssertEqual(params.jumpHosts.first?.host, "bastion.example")
        XCTAssertEqual(params.jumpHosts.first?.port, 2222)
        XCTAssertEqual(params.jumpHosts.last?.host, "second.example")
    }

    func testAgentForwardingCarriesTheStoredKeys() async throws {
        let generated = try SSHKeyGenerator.generate(type: .ed25519, comment: "phone")
        var key = SSHKey(
            label: "my key",
            keyType: SSHKey.KeyType.ed25519.rawValue,
            privateKeyPem: generated.privateKeyPEM,
            publicKey: generated.publicKeyLine
        )
        key = try await keys.save(key)

        let host = makeHost { $0.agentForwarding = true }
        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertTrue(params.agentForwarding)
        XCTAssertEqual(params.agentIdentities.count, 1)
        // The label travels as the comment, which is what `ssh-add -l` shows on
        // the far end — the only way the user can tell the keys apart there.
        XCTAssertEqual(params.agentIdentities.first?.comment, "my key")
    }

    /// Keys must not be offered to a host that did not ask for forwarding.
    func testKeysAreNotOfferedWithoutAgentForwarding() async throws {
        let generated = try SSHKeyGenerator.generate(type: .ed25519)
        _ = try await keys.save(
            SSHKey(
                label: "unused",
                keyType: SSHKey.KeyType.ed25519.rawValue,
                privateKeyPem: generated.privateKeyPEM,
                publicKey: generated.publicKeyLine
            )
        )

        let host = makeHost { $0.agentForwarding = false }
        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertTrue(params.agentIdentities.isEmpty)
    }

    // MARK: - Host-list jump mode

    func testHostListModeResolvesRecordsInOrder() async throws {
        let first = try await hosts.save(
            Host(label: "b1", hostname: "one.example", port: 2201, username: "alice")
        )
        let second = try await hosts.save(
            Host(label: "b2", hostname: "two.example", port: 2202, username: "bob")
        )

        let host = makeHost {
            $0.jumpMode = Host.JumpMode.hostList.rawValue
            // Deliberately not in insertion order: the chain follows the list.
            $0.jumpHostIdList = "\(second.id!),\(first.id!)"
        }

        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.jumpHosts.count, 2)
        XCTAssertEqual(params.jumpHosts.first?.host, "two.example")
        XCTAssertEqual(params.jumpHosts.first?.username, "bob")
        XCTAssertEqual(params.jumpHosts.last?.host, "one.example")
        XCTAssertEqual(params.jumpHosts.last?.port, 2201)
        // Carried so a newly seen key can be written back to that hop's record.
        XCTAssertEqual(params.jumpHosts.first?.hostId, second.id)
    }

    /// A hop whose record was deleted must not make the host unusable.
    func testHostListModeSkipsMissingRecords() async throws {
        let existing = try await hosts.save(
            Host(label: "b", hostname: "one.example", username: "alice")
        )

        let host = makeHost {
            $0.jumpMode = Host.JumpMode.hostList.rawValue
            $0.jumpHostIdList = "\(existing.id!),9999"
        }

        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.jumpHosts.count, 1)
        XCTAssertEqual(params.jumpHosts.first?.host, "one.example")
    }

    /// The two modes must not leak into each other: text left over from `simple`
    /// is not a chain once the user has switched to picking hosts.
    func testModesDoNotMix() async throws {
        let record = try await hosts.save(
            Host(label: "b", hostname: "picked.example", username: "alice")
        )

        let host = makeHost {
            $0.jumpMode = Host.JumpMode.hostList.rawValue
            $0.jumpHosts = "leftover.example"
            $0.jumpHostIdList = "\(record.id!)"
        }

        let params = await planner.params(for: host, auth: auth, hostKeyPolicy: .acceptOnce)

        XCTAssertEqual(params.jumpHosts.map(\.host), ["picked.example"])
    }

    // MARK: - Persisting the hops' host keys

    func testHostListModeWritesEachKeyToItsOwnRecord() async throws {
        let hop = try await hosts.save(
            Host(label: "b", hostname: "one.example", username: "alice")
        )
        let host = makeHost { $0.jumpMode = Host.JumpMode.hostList.rawValue }

        await planner.persistJumpHostKeys(
            [SSHSession.JumpHostKey(hostId: hop.id, knownHostsLine: "one.example ssh-ed25519 AAAA")],
            for: host
        )

        let reloaded = try await hosts.fetch(id: hop.id!)
        XCTAssertEqual(reloaded?.knownHostsEntry, "one.example ssh-ed25519 AAAA")
    }

    func testSimpleModeKeepsTheKeysOnTheHostItself() async throws {
        var host = makeHost { $0.jumpMode = Host.JumpMode.simple.rawValue }
        host = try await hosts.save(host)

        await planner.persistJumpHostKeys(
            [
                SSHSession.JumpHostKey(hostId: nil, knownHostsLine: "one ssh-ed25519 AAAA"),
                SSHSession.JumpHostKey(hostId: nil, knownHostsLine: "two ssh-ed25519 BBBB"),
            ],
            for: host
        )

        let reloaded = try await hosts.fetch(id: host.id!)
        XCTAssertEqual(reloaded?.jumpHostKeys, "one ssh-ed25519 AAAA\ntwo ssh-ed25519 BBBB")
    }

    /// Nothing collected means nothing written: a reconnection must not append
    /// the same lines again and grow the record without bound.
    func testNothingIsWrittenWhenNoNewKeysWereSeen() async throws {
        var host = makeHost { $0.jumpHostKeys = "existing ssh-ed25519 AAAA" }
        host = try await hosts.save(host)

        await planner.persistJumpHostKeys([], for: host)

        let reloaded = try await hosts.fetch(id: host.id!)
        XCTAssertEqual(reloaded?.jumpHostKeys, "existing ssh-ed25519 AAAA")
    }
}
