// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    private struct Target {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    private func target() throws -> Target {
        guard let host = Self.setting("SSHBORG_TEST_HOST"),
              let username = Self.setting("SSHBORG_TEST_USER"),
              let password = Self.setting("SSHBORG_TEST_PASSWORD")
        else {
            throw XCTSkip("No SSH target configured; set SSHBORG_TEST_HOST, _USER and _PASSWORD.")
        }

        return Target(
            host: host,
            port: Self.setting("SSHBORG_TEST_PORT").flatMap(Int.init) ?? 22,
            username: username,
            password: password
        )
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
