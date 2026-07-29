// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Exercises local port forwarding against a real server.
///
/// The rule points at the server's own SSH port, so a full SSH session can be
/// opened *through* the forward. That proves the tunnel carries a real protocol
/// in both directions, which reading a banner would not.
final class PortForwardingIntegrationTests: XCTestCase {

    private struct Target {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    private func target() throws -> Target {
        func setting(_ name: String) -> String? {
            guard let value = ProcessInfo.processInfo.environment[name],
                  !value.isEmpty, !value.hasPrefix("$(")
            else { return nil }
            return value
        }

        guard let host = setting("SSHBORG_TEST_HOST"),
              let username = setting("SSHBORG_TEST_USER"),
              let password = setting("SSHBORG_TEST_PASSWORD")
        else {
            throw XCTSkip("No SSH target configured; set SSHBORG_TEST_HOST, _USER and _PASSWORD.")
        }

        return Target(
            host: host,
            port: Int(setting("SSHBORG_TEST_PORT") ?? "22") ?? 22,
            username: username,
            password: password
        )
    }

    private func params(_ target: Target) -> SSHConnectionParams {
        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15
        return params
    }

    /// A high port unlikely to be taken, different per test run.
    private func ephemeralPort() -> Int {
        Int.random(in: 42_000...52_000)
    }

    func testForwardCarriesAFullSSHSession() async throws {
        let target = try target()
        let localPort = ephemeralPort()

        let rule = PortForwarding(
            bindAddress: "127.0.0.1",
            localPort: localPort,
            remoteHost: "127.0.0.1",
            remotePort: target.port
        )

        let forwarder = try await PortForwarder.start([rule], params: params(target))
        defer { forwarder.stop() }

        // Give the listener a moment to reach .ready.
        try await Task.sleep(nanoseconds: 500_000_000)

        let listening = forwarder.status.first { $0.rule.localPort == localPort }
        XCTAssertEqual(listening?.isListening, true, "listener did not start: \(listening?.failure ?? "no reason given")")

        // Now connect to the local end of the tunnel as if it were the server.
        var throughTunnel = params(target)
        throughTunnel.hostname = "127.0.0.1"
        throughTunnel.port = localPort

        let session = try await SSHSession.connect(throughTunnel)
        defer { session.disconnect() }

        let channel = try await session.openShell(columns: 80, rows: 24)
        defer { channel.close() }

        // Split by empty quotes in what is typed, so the echo of the command
        // line reads `FORWARD''ED_x` and only the shell's own output contains
        // the marker. Counting occurrences instead is not safe: a PTY echoes
        // the line and the shell redraws it, so the marker can appear twice
        // before the command has run — which is exactly how the agent
        // forwarding tests came to read the prompt instead of the output.
        let id = UUID().uuidString.prefix(8)
        let marker = "FORWARDED_\(id)"
        channel.send(Data("echo FORWARD''ED_\(id)\n".utf8))

        var output = ""
        let collector = Task { () -> String in
            var text = ""
            for await chunk in channel.output {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains(marker) { return text }
            }
            return text
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            collector.cancel()
        }
        output = await collector.value
        watchdog.cancel()

        XCTAssertTrue(output.contains(marker), "nothing came back through the forwarded port:\n\(output)")
    }

    /// Several rules must all come up, not just the first.
    func testSeveralRulesListenAtOnce() async throws {
        let target = try target()
        let first = ephemeralPort()
        let second = first + 1

        let rules = [first, second].map {
            PortForwarding(bindAddress: "127.0.0.1", localPort: $0, remoteHost: "127.0.0.1", remotePort: target.port)
        }

        let forwarder = try await PortForwarder.start(rules, params: params(target))
        defer { forwarder.stop() }

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(forwarder.status.filter(\.isListening).count, 2)
    }

    /// A port an app may not bind must be reported, not silently dropped: the
    /// user needs to know the rule is not in effect.
    func testPrivilegedPortIsReportedAsFailed() async throws {
        let target = try target()
        let rule = PortForwarding(
            bindAddress: "127.0.0.1",
            localPort: 80, // below 1024, refused to an unprivileged process
            remoteHost: "127.0.0.1",
            remotePort: target.port
        )

        let forwarder = try await PortForwarder.start([rule], params: params(target))
        defer { forwarder.stop() }

        try await Task.sleep(nanoseconds: 1_000_000_000)

        let status = try XCTUnwrap(forwarder.status.first)
        XCTAssertFalse(status.isListening, "port 80 should not have been bound")
    }

    func testStopReleasesTheListeners() async throws {
        let target = try target()
        let localPort = ephemeralPort()
        let rule = PortForwarding(
            bindAddress: "127.0.0.1",
            localPort: localPort,
            remoteHost: "127.0.0.1",
            remotePort: target.port
        )

        let forwarder = try await PortForwarder.start([rule], params: params(target))
        try await Task.sleep(nanoseconds: 500_000_000)
        forwarder.stop()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Binding the same port again is the real proof it was released.
        let second = try await PortForwarder.start([rule], params: params(target))
        defer { second.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(second.status.first?.isListening, true, "the port was not released by stop()")
    }
}
