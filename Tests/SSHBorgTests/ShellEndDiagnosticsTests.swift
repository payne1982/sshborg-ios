// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// What the SSH layer actually reports for each way a shell can end.
///
/// Three endings look the same from the app's side unless the channel is asked
/// precisely: leaving with `exit`, having the shell killed, and having the
/// session killed out from under it. Getting that wrong closed a tab that should
/// have stayed, so the distinguishing values are pinned here rather than
/// inferred.
final class ShellEndDiagnosticsTests: XCTestCase {

    private func target() throws -> SSHTestCredentials.Target {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        return target
    }

    /// Held for the length of a test.
    ///
    /// The first run of this file had it as a local, and every ending came back
    /// as `session teardown` with no status and no signal: the session was
    /// deallocated the moment the helper returned, and tore the channel down
    /// before the server's exit message could be read. The app keeps its session
    /// in a property, so a test that does not is measuring itself.
    private var session: SSHSession?

    private func openShell() async throws -> SSHShellChannel {
        let target = try target()
        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15

        let session = try await SSHSession.connect(params)
        self.session = session
        return try await session.openShell(columns: 80, rows: 24)
    }

    /// Drains the channel until it finishes, so the exit values are final.
    private func drain(_ channel: SSHShellChannel) async {
        for await _ in channel.output {}
    }

    private func report(_ channel: SSHShellChannel, _ what: String) {
        print("=== \(what): status=\(String(describing: channel.exitStatus)) "
              + "reason=\(String(describing: channel.finishReason)) ===")
    }

    func testLeavingWithExit() async throws {
        let channel = try await openShell()
        channel.send(Data("exit\n".utf8))
        await drain(channel)
        report(channel, "exit")

        XCTAssertNotNil(channel.exitStatus, "a normal exit sent no status")
        XCTAssertEqual(channel.finishReason, "eof")
    }

    func testTheShellItselfBeingKilled() async throws {
        let channel = try await openShell()
        channel.send(Data("kill -9 $$\n".utf8))
        await drain(channel)
        report(channel, "kill shell")

        // Indistinguishable from `exit` at this level, which is the point: the
        // status reads 0 either way, and libssh2 offers no "was a status even
        // sent" to separate them. Reading `exit-signal` would, and was removed
        // on purpose — see the note in TerminalSession.handleStreamEnded.
        XCTAssertNotNil(channel.exitStatus)
        XCTAssertEqual(channel.finishReason, "eof")
    }

    /// The case that was reported: the session killed from the server, which
    /// takes sshd with it. No exit-status and no exit-signal can arrive, because
    /// there is nothing left to send them — so the only honest reading is the
    /// channel's own account of how its stream ended.
    func testTheSessionBeingKilledFromTheServer() async throws {
        let channel = try await openShell()
        channel.send(Data("kill -9 $PPID\n".utf8))
        await drain(channel)
        report(channel, "kill session")

        XCTAssertNotEqual(
            channel.finishReason, "eof",
            "a session killed at the server looked like an orderly close"
        )
    }
}
