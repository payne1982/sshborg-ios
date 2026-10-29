// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftTerm
import XCTest

@testable import SSHBorg

/// The road a mosh session takes through the app, end to end, against a real
/// server: the switch is read, `mosh-server` is started over the SSH session
/// that is already open, the handover is believed only if a datagram comes back,
/// and what the shell says arrives in our own emulator.
///
/// Unlike the lab, nothing here is started by hand and there is no one-server,
/// one-test rule: each test starts its own server over its own SSH session, and
/// closing the session says goodbye to it.
///
/// Skips with the integration suite, because it needs a host — and a host with
/// mosh on it for the second test, which is the only one that cannot be arranged
/// from this side.
@MainActor
final class MoshRoadTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var target: SSHTestCredentials.Target!

    override func setUpWithError() throws {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        self.target = target
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
    }

    /// A host with mosh on, and no credentials stored: the key and the password
    /// are asked for in that order, as `FirstConnectionQuestionsTests` pins, and
    /// the third attempt is the one that reaches the mosh question.
    private func connectedSession(moshCommand: String? = nil) async throws -> TerminalSession {
        var host = Host(label: "mosh", hostname: target.host, username: target.username)
        host.port = target.port
        host.mosh = true
        host.moshCommand = moshCommand
        let saved = try await hosts.save(host)

        let session = TerminalSession(host: saved, hosts: hosts, keys: keys)
        XCTAssertTrue(
            session.barWouldHideOutput,
            "a tab for a mosh host must keep the title bar out of the way before it knows better"
        )

        await session.connect()
        await session.connect(acceptHostKey: true)
        await session.connect(password: target.password)
        return session
    }

    /// Mosh asked for and not to be had: the session says why and offers the two
    /// answers, and carrying on over SSH costs nothing because the session that
    /// started the server is still open.
    ///
    /// Deterministic on any host, which is the point of naming a program that
    /// cannot exist: the four reasons are otherwise a matter of what happens to
    /// be installed.
    func testAMoshHostThatCannotStartTheServerAsksAndThenCarriesOn() async throws {
        let session = try await connectedSession(moshCommand: "/nonexistent/mosh-server")
        defer { session.disconnect() }

        guard case .moshUnavailable(let failure) = session.phase else {
            return XCTFail("expected the mosh question, got \(session.phase)")
        }
        XCTAssertEqual(failure.reason, .notInstalled)
        XCTAssertNotNil(failure.detail, "nothing of what the server said was kept")
        XCTAssertTrue(
            session.barWouldHideOutput,
            "the question is not an answer: until it is answered the screen may still be the server's"
        )

        await session.continueOverSSH()

        guard case .connected = session.phase else {
            return XCTFail("carrying on over SSH left the session at \(session.phase)")
        }
        XCTAssertFalse(
            session.barWouldHideOutput,
            "a session that fell back to SSH kept the answer the host's switch had given"
        )
    }

    /// The whole road, on a real server: a command typed here runs there, and
    /// what it printed arrives in our grid.
    ///
    /// Nothing about this can be arranged by agreement with itself. The
    /// keystroke crosses as a user diff in a sealed datagram; the answer comes
    /// back as a screen computed by the *server's* terminal and applied to ours.
    /// The marker is arithmetic so that the echo of the typed line cannot be
    /// mistaken for the answer: `MOSH-ROAD-7` is never typed, only printed.
    func testAMoshSessionCarriesACommandAndItsAnswerBack() async throws {
        let session = try await connectedSession()
        defer {
            session.disconnect()
            // The goodbye is a datagram the loop sends after being told to
            // close, and a server that never hears it holds a shell until its
            // own timeout. A moment here is the difference between leaving one
            // behind and not.
            let until = Date().addingTimeInterval(0.4)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
        }

        if case .moshUnavailable(let failure) = session.phase {
            throw XCTSkip("no mosh session on \(target.host): \(failure.reason) — \(failure.detail ?? "")")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a mosh session, got \(session.phase)")
        }
        XCTAssertTrue(
            session.barWouldHideOutput,
            "a mosh session let the title bar cover a screen the client may not write into"
        )

        session.send(text: "echo MOSH-ROAD-$((3+4))\r")

        let answered = await waitForScreen("MOSH-ROAD-7", in: session, seconds: 10)
        XCTAssertTrue(answered, "the command's output never arrived:\n\(screenText(of: session))")
    }

    // MARK: - Reading the grid

    private func waitForScreen(
        _ needle: String, in session: TerminalSession, seconds: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if screenText(of: session).contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// The visible grid as text. SwiftTerm's lines are public, which is what
    /// makes this possible at all — see the oracle's own reader.
    private func screenText(of session: TerminalSession) -> String {
        let terminal = session.terminalView.getTerminal()
        return (0..<terminal.rows)
            .compactMap {
                terminal.getLine(row: $0)?
                    .translateToString(trimRight: true, skipNullCellsFollowingWide: true)
            }
            .joined(separator: "\n")
    }
}
