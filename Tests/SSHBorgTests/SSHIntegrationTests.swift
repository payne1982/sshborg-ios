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

    // MARK: - A terminal slower than the network

    /// Output nobody is taking stops being read, and none of it is lost.
    ///
    /// Ten megabytes, more than the backlog limit and the channel's window
    /// together, while nothing reads `output` for three seconds: what waits stays
    /// at the limit, give or take one read, and then every byte arrives. An audit
    /// on 30/10/2026 proposed ending the session past a budget; SSH's own flow
    /// control makes that unnecessary, and this is the claim that it does.
    func testOutputNobodyTakesStopsBeingReadAndNoneOfItIsLost() async throws {
        let session = try await SSHSession.connect(params(try target()))
        defer { session.disconnect() }
        let channel = try await session.openShell(columns: 80, rows: 24)
        defer { channel.close() }

        let total = 10_000_000
        let marker = "FLOOD_END_\(UUID().uuidString.prefix(6))"
        // Echo off first, on its own line and given time to take effect, so the
        // command line below is not echoed into the count or the marker.
        channel.send(Data("stty -echo\n".utf8))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        channel.send(Data("head -c \(total) /dev/zero | tr '\\000' Q; echo; echo \(marker)\n".utf8))

        try await Task.sleep(nanoseconds: 3_000_000_000)
        let waiting = channel.waitingOutput
        XCTAssertGreaterThan(waiting, 0, "nothing arrived while nobody was reading")
        XCTAssertLessThanOrEqual(
            waiting, 4 * 1024 * 1024 + 32 * 1024,
            "the channel kept reading for a terminal that was not taking anything"
        )

        let collector = Task { () -> (count: Int, ended: Bool, tail: String) in
            var count = 0
            var tail = ""
            for await chunk in channel.output {
                if Task.isCancelled { break }
                count += chunk.reduce(0) { $0 + ($1 == UInt8(ascii: "Q") ? 1 : 0) }
                // Longer than a coloured prompt, which follows the marker.
                tail = String((tail + String(decoding: chunk.suffix(512), as: UTF8.self)).suffix(512))
                if tail.contains(marker) { return (count, true, tail) }
            }
            return (count, false, tail)
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            collector.cancel()
        }
        defer { watchdog.cancel() }

        let result = await collector.value
        XCTAssertTrue(result.ended, "the output never finished arriving: \(result.tail.debugDescription)")
        XCTAssertEqual(result.count, total, "bytes were lost while the channel was held back")
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

    // MARK: - Running one command, and starting a mosh server with it

    /// The exec channel, which the app had no way to open until mosh needed one.
    func testOneCommandRunsAndItsOutputComesBack() async throws {
        let session = try await SSHSession.connect(params(try target()))
        defer { session.disconnect() }

        let marker = "EXEC_\(UUID().uuidString.prefix(8))"
        let answer = try await session.execute("echo \(marker)")

        XCTAssertTrue(
            answer.output.contains(marker),
            "the command said \(answer.output.debugDescription)"
        )
        XCTAssertEqual(answer.exitStatus, 0)
    }

    /// Standard error is read too, because for a command that failed it is the
    /// whole of the diagnosis — and the exit status comes back with it.
    func testACommandThatFailsReportsWhatItSaidAndHowItEnded() async throws {
        let session = try await SSHSession.connect(params(try target()))
        defer { session.disconnect() }

        let answer = try await session.execute("sshborg-no-such-program-exists")

        XCTAssertNotEqual(answer.exitStatus, 0)
        XCTAssertEqual(
            MoshBootstrap.reason(for: answer.output, exitStatus: answer.exitStatus),
            .notInstalled,
            "what the shell said was \(answer.output.debugDescription)"
        )
    }

    /// **The gate for the bootstrap**, and the part of phase 6 that needed no
    /// device: it logs in over SSH, starts a real `mosh-server`, reads the
    /// handover — and then uses the same SSH session again, which is the whole
    /// reason for not closing it. The stock mosh client does close it, and loses
    /// SFTP, the agent and the port forwardings with it.
    ///
    /// The server left behind gives itself up: nothing connects to it, and a
    /// `mosh-server` that no client reaches exits on its own after sixty
    /// seconds. That is also why this test cannot go on to drive the session —
    /// the lab does that, and needs the handover by hand.
    /// The address the socket actually reached, numerically.
    ///
    /// Mosh is the only caller and the reason it exists: `mosh-server -s`
    /// listens on the one address the SSH connection arrived on, so resolving
    /// the name a second time to find it is a guess. What this pins is that the
    /// answer is an address and not the name that was dialled — the two are the
    /// same string when a test target is given by IP, which is why the name is
    /// also rejected as an answer only when it is not one.
    func testTheDialledAddressIsTheOneTheSocketReached() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let address = try XCTUnwrap(session.dialledAddress, "a direct session reported no peer")
        XCTAssertFalse(address.isEmpty)
        // Numeric: either dotted quad or a colon in it. `getnameinfo` with
        // NI_NUMERICHOST never gives a name back, and that is the whole promise.
        let numeric = address.contains(":")
            || address.split(separator: ".").allSatisfy { UInt8($0) != nil }
        XCTAssertTrue(numeric, "\(address) is not a numeric address")
    }

    func testTheBootstrapStartsAMoshServerAndLeavesTheSSHSessionAlone() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        // A short timeout on the server's side: this one is never going to be
        // connected to, and an hour of a shell waiting on fatberry for a test is
        // not a tidy thing to leave behind.
        let handover: MoshHandover
        do {
            handover = try await MoshBootstrap.start(
                on: session, dialled: target.host, networkTimeout: 30
            )
        } catch let unavailable as MoshBootstrap.Unavailable {
            throw XCTSkip(
                "no mosh on \(target.host): \(unavailable.reason) — \(unavailable.detail ?? "")"
            )
        }

        XCTAssertEqual(handover.host, target.host)
        XCTAssertTrue((1...65535).contains(handover.port))
        // 22 base64 characters with the padding left off, which is the sixteen
        // bytes `MoshCrypto` insists on.
        XCTAssertEqual(handover.key.count, 22)
        XCTAssertNoThrow(try MoshCrypto(printableKey: handover.key))

        // And the session is still ours.
        let after = try await session.execute("echo still-here")
        XCTAssertTrue(after.output.contains("still-here"), "the exec channel took the session with it")
        let alive = await session.isAlive()
        XCTAssertTrue(alive)
    }

    // MARK: - An approval is for one key

    /// A hop approved with one key refuses another. The approval here is a key
    /// the hop does not have, which is what an attacker swapping the machine in
    /// between two attempts looks like from this side — and before 29/10/2026
    /// the chain inherited "the target was accepted" and took it anyway.
    func testAHopApprovedForOneKeyRefusesAnother() async throws {
        let target = try target()
        var params = params(target, policy: .promptIfUnknown)
        params.jumpHosts = [hop(target)]
        let marker = KnownHostsLine.marker(host: target.host, port: target.port)
        params.approvedHostKeys[marker] = "\(marker) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNvbWVib2R5IGVsc2UncyBrZXkgaGVyZSE="

        do {
            let session = try await SSHSession.connect(params)
            session.disconnect()
            XCTFail("the chain connected through a hop that presented a different key")
        } catch SSHError.hostKeyMismatch {
            // The right refusal.
        } catch {
            XCTFail("refused for the wrong reason: \(error)")
        }
    }

    // MARK: - One command, with a deadline and a ceiling

    /// A command that prints for ever and never says what we are waiting for is
    /// stopped by the ceiling, in a fraction of the time the deadline allows.
    /// It used to be kept alive by its own output, because libssh2's timeout is
    /// per read.
    func testACommandThatNeverStopsTalkingIsCutOff() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let started = Date()
        do {
            _ = try await session.execute("yes", timeout: 10) { _ in false }
            XCTFail("`yes` finished")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 8, "it ran into the deadline instead")
        }
        let alive = await session.isAlive()
        XCTAssertTrue(alive, "cutting the command off took the session with it")
    }

    /// The error stream arrives with the output, in order, and cannot stall the
    /// call by filling up while we wait for the other one.
    func testTheErrorStreamArrivesWithTheOutput() async throws {
        let target = try target()
        let session = try await SSHSession.connect(params(target))
        defer { session.disconnect() }

        let answer = try await session.execute(
            "head -c 16000 /dev/zero | tr '\\0' e 1>&2; echo DONE-AFTER-STDERR", timeout: 20
        ) { $0.contains("DONE-AFTER-STDERR") }
        XCTAssertTrue(answer.output.contains("DONE-AFTER-STDERR"))
    }
}
