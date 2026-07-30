// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Exercises the SSH layer against a real server.
///
/// Skipped unless a target is configured, so the suite stays runnable anywhere:
///
///     xcodebuild test … \
///       TEST_RUNNER_SSHBORG_TEST_HOST=127.0.0.1 \
///       TEST_RUNNER_SSHBORG_TEST_USER=someone \
///       TEST_RUNNER_SSHBORG_TEST_PASSWORD=secret
///
/// Credentials deliberately come from the environment: nothing here may be
/// committed. `TEST_RUNNER_` is the prefix xcodebuild strips before handing a
/// variable to the test process.
final class SSHIntegrationTests: XCTestCase {

    private typealias Target = SSHTestCredentials.Target

    private func target() throws -> Target {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        return target
    }

    /// Reads a value the scheme forwards from a build setting.
    ///
    /// An undefined setting reaches us as the literal `$(NAME)` rather than as
    /// nothing, so that has to count as absent — otherwise the tests would try
    /// to connect to a host called `$(SSHBORG_TEST_HOST)` and fail instead of
    /// skipping.
    private static func setting(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name],
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    private func params(_ target: Target, policy: HostKeyPolicy = .acceptOnce) -> SSHConnectionParams {
        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = policy
        params.connectTimeout = 15
        return params
    }

    // MARK: - The happy path

    /// The one that matters: connect, get a shell, run a command, see its output.
    /// `isAlive()` is what the foreground path asks before deciding whether a
    /// session survived being suspended, so it has to be right in both
    /// directions. Getting a false negative would throw away a working shell;
    /// a false positive would leave a dead tab looking connected until the user
    /// typed into it.
    func testIsAliveAnswersBothWays() async throws {
        let target = try target()

        let session = try await SSHSession.connect(params(target))
        var alive = await session.isAlive()
        XCTAssertTrue(alive, "a session that just connected reported itself dead")

        // Still true with a shell open, which is when it actually gets asked —
        // the session is non-blocking by then and a keepalive can return EAGAIN.
        let channel = try await session.openShell(columns: 80, rows: 24)
        alive = await session.isAlive()
        XCTAssertTrue(alive, "a session with an open shell reported itself dead")

        channel.close()
        session.disconnect()
        // disconnect() hops onto the session queue, so give it a moment to land.
        try await Task.sleep(nanoseconds: 500_000_000)

        alive = await session.isAlive()
        XCTAssertFalse(alive, "a disconnected session still reported itself alive")
    }

    func testRunsACommandAndSeesItsOutput() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let channel = try await session.openShell(columns: 80, rows: 24)
        defer { channel.close() }

        let marker = "SSHBORG_MARKER_\(UUID().uuidString.prefix(8))"
        channel.send(Data("echo \(marker)\n".utf8))

        let output = try await collect(from: channel, until: marker, timeout: 20)
        XCTAssertTrue(
            output.contains(marker),
            "the shell never echoed the marker back; got:\n\(output)"
        )
    }

    func testHostKeyIsReportedAndIsStorable() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let key = session.hostKey
        XCTAssertFalse(key.base64Key.isEmpty)
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertNotEqual(key.algorithm, "unknown", "the host key algorithm was not recognised")

        // What we store must satisfy the matcher on the next connection.
        XCTAssertTrue(KnownHostsLine.matches(
            storedLine: key.knownHostsLine,
            algorithm: key.algorithm,
            base64Key: key.base64Key
        ))
    }

    /// Reconnecting with the key pinned from the first connection must succeed.
    func testPinnedHostKeyIsAccepted() async throws {
        let target = try target()

        let first = try await SSHSession.connect(params(target))
        let pinned = first.hostKey.knownHostsLine
        first.disconnect()

        let second = try await SSHSession.connect(params(target, policy: .requireMatch(pinned)))
        second.disconnect()
    }

    // MARK: - The paths that must fail

    /// An unknown key must stop the connection, not be trusted silently — and it
    /// must do so before any credential is sent.
    func testUnknownHostKeyIsRefused() async throws {
        let target = try target()

        do {
            let session = try await SSHSession.connect(params(target, policy: .promptIfUnknown))
            session.disconnect()
            XCTFail("an unknown host key was accepted without asking")
        } catch SSHError.unknownHostKey(let info) {
            XCTAssertTrue(info.fingerprint.hasPrefix("SHA256:"))
        }
    }

    /// The security-critical case: a key that differs from the stored one.
    func testChangedHostKeyIsRefused() async throws {
        let target = try target()
        let wrongLine = "\(target.host) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWRONGKEYWRONGKEYWRONGKEY"

        do {
            let session = try await SSHSession.connect(params(target, policy: .requireMatch(wrongLine)))
            session.disconnect()
            XCTFail("a mismatched host key was accepted")
        } catch SSHError.hostKeyMismatch(let info) {
            XCTAssertFalse(info.base64Key.isEmpty)
        }
    }

    func testWrongPasswordIsRejected() async throws {
        let target = try target()
        var wrong = params(target)
        wrong.auth = .password("definitely-not-the-password-\(UUID().uuidString)")

        do {
            let session = try await SSHSession.connect(wrong)
            session.disconnect()
            XCTFail("a wrong password was accepted")
        } catch {
            // Either mapping is fine; what matters is that it did not connect.
            XCTAssertTrue(
                error is SSHError,
                "expected an SSHError, got \(type(of: error))"
            )
        }
    }

    func testUnreachablePortFailsQuickly() async throws {
        let target = try target()
        var unreachable = params(target)
        unreachable.port = 1 // reserved, nothing listens
        unreachable.connectTimeout = 5

        do {
            let session = try await SSHSession.connect(unreachable)
            session.disconnect()
            XCTFail("connected to a port with no server")
        } catch {
            XCTAssertTrue(error is SSHError)
        }
    }

    // MARK: - Jump hosts

    /// The same machine serves as both bastion and destination: connect to it,
    /// have it open a tunnel back to itself, and run SSH through that. The
    /// tunnelling is real even though the endpoints coincide.
    ///
    /// Note these tests connect with `.acceptOnce`, which is what a user who has
    /// approved the fingerprint supplies. Without it a hop with no stored key
    /// correctly refuses, which is what the first run of these tests proved.
    private func hop(_ target: Target) -> JumpHost {
        JumpHost(
            host: target.host,
            port: target.port,
            username: target.username,
            knownHostsEntry: nil,
            auth: .password(target.password)
        )
    }

    func testConnectsThroughOneJumpHost() async throws {
        let target = try target()
        var params = params(target)
        params.jumpHosts = [hop(target)]

        let session = try await SSHSession.connect(params)
        defer { session.disconnect() }

        // A shell over the tunnel proves the whole path carries data, not just
        // that the handshake completed.
        let channel = try await session.openShell(columns: 80, rows: 24)
        defer { channel.close() }

        let marker = "JUMPED_\(UUID().uuidString.prefix(8))"
        channel.send(Data("echo \(marker)\n".utf8))

        let output = try await collect(from: channel, until: marker, timeout: 30)
        XCTAssertTrue(output.contains(marker), "nothing came back through the jump host:\n\(output)")
    }

    func testConnectsThroughTwoJumpHosts() async throws {
        let target = try target()
        var params = params(target)
        params.jumpHosts = [hop(target), hop(target)]

        let session = try await SSHSession.connect(params)
        defer { session.disconnect() }

        XCTAssertFalse(session.hostKey.base64Key.isEmpty)
    }

    /// Keys for hops seen for the first time come back so the caller can store
    /// them, which is what makes the second connection verifiable.
    func testUnseenJumpHostKeysAreReported() async throws {
        let target = try target()
        var params = params(target)
        params.jumpHosts = [hop(target)]

        let session = try await SSHSession.connect(params)
        defer { session.disconnect() }

        XCTAssertEqual(session.newJumpHostKeys.count, 1)
        let line = try XCTUnwrap(session.newJumpHostKeys.first?.knownHostsLine)
        XCTAssertFalse(line.isEmpty)
        XCTAssertNotNil(KnownHostsLine.parse(line))
    }

    /// A hop whose key was pinned must still connect on the next attempt.
    func testPinnedJumpHostKeyIsAccepted() async throws {
        let target = try target()

        var first = params(target)
        first.jumpHosts = [hop(target)]
        let discovery = try await SSHSession.connect(first)
        let pinned = try XCTUnwrap(discovery.newJumpHostKeys.first?.knownHostsLine)
        discovery.disconnect()

        var second = params(target)
        var pinnedHop = hop(target)
        pinnedHop.knownHostsEntry = pinned
        second.jumpHosts = [pinnedHop]

        let session = try await SSHSession.connect(second)
        session.disconnect()
    }

    /// A hop with no stored key must refuse under the default policy, exactly
    /// as the final host does. Trusting a bastion on sight would defeat the
    /// point of routing through one.
    func testUnknownJumpHostKeyIsRefusedByDefault() async throws {
        let target = try target()
        var params = params(target, policy: .promptIfUnknown)
        params.jumpHosts = [hop(target)]

        do {
            let session = try await SSHSession.connect(params)
            session.disconnect()
            XCTFail("an unknown jump host key was accepted without asking")
        } catch SSHError.unknownHostKey(let info) {
            XCTAssertTrue(info.fingerprint.hasPrefix("SHA256:"))
        }
    }

    /// A hop that cannot be reached must fail the whole chain, not fall through
    /// to a direct connection — that would silently bypass the bastion.
    func testUnreachableJumpHostFailsTheChain() async throws {
        let target = try target()
        var params = params(target)
        var deadHop = hop(target)
        deadHop.port = 1
        params.jumpHosts = [deadHop]
        params.connectTimeout = 5

        do {
            let session = try await SSHSession.connect(params)
            session.disconnect()
            XCTFail("the chain connected despite an unreachable jump host")
        } catch {
            XCTAssertTrue(error is SSHError)
        }
    }

    /// A hop presenting a key that does not match the stored one must stop the
    /// chain, exactly as the final host would.
    func testChangedJumpHostKeyIsRefused() async throws {
        let target = try target()
        var params = params(target)
        var wrongHop = hop(target)
        wrongHop.knownHostsEntry = "\(target.host) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWRONGWRONGWRONG"
        params.jumpHosts = [wrongHop]

        do {
            let session = try await SSHSession.connect(params)
            session.disconnect()
            XCTFail("a mismatched jump host key was accepted")
        } catch SSHError.hostKeyMismatch {
            // expected
        }
    }

    // MARK: - Resizing

    func testResizeIsAccepted() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let channel = try await session.openShell(columns: 80, rows: 24)
        defer { channel.close() }

        channel.resize(columns: 120, rows: 40)

        // The shell must still be alive and answering after the resize.
        let marker = "RESIZED_\(UUID().uuidString.prefix(6))"
        channel.send(Data("echo \(marker)\n".utf8))

        let output = try await collect(from: channel, until: marker, timeout: 20)
        XCTAssertTrue(output.contains(marker), "the shell stopped responding after a resize")
    }

    // MARK: - Helpers

    /// Accumulates output until `marker` shows up, or the deadline passes.
    ///
    /// The timeout has to cancel the iteration from the outside. Checking a
    /// deadline inside the loop would only be reached when the next chunk
    /// arrives, so a server that simply stops writing would hang the test
    /// forever instead of failing it.
    private func collect(
        from channel: SSHShellChannel,
        until marker: String,
        timeout: TimeInterval
    ) async throws -> String {
        let collector = Task { () -> String in
            var output = ""
            for await chunk in channel.output {
                if Task.isCancelled { return output }
                output += String(decoding: chunk, as: UTF8.self)

                // The echoed command line carries the marker too, so wait for a
                // second occurrence: the first is the echo, the second the result.
                if output.components(separatedBy: marker).count > 2 { return output }
            }
            return output
        }

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        defer { watchdog.cancel() }

        return await collector.value
    }
}
