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
    private func connectedSession(
        moshCommand: String? = nil, agentForwarding: Bool = false
    ) async throws -> TerminalSession {
        var host = Host(label: "mosh", hostname: target.host, username: target.username)
        host.port = target.port
        host.mosh = true
        host.moshCommand = moshCommand
        host.agentForwarding = agentForwarding
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

    /// A host whose **first hop** has mosh is reached from the other end: this
    /// session is made to the bastion over mosh, and the rest of the way is
    /// typed into it as one `ssh` line.
    ///
    /// Two claims, and the first is the one that could not be guessed: the tab's
    /// own host has mosh **off**, and the session is a mosh session anyway,
    /// because the bastion's switch is the whole decision. The second is that
    /// the line reaches the bastion's shell, which needs the login to have been
    /// recognised as settled — there is no prompt detector, only silence.
    ///
    /// What the inward `ssh` then does belongs to somebody's `known_hosts` and
    /// is not this test's business. Both rows name the same machine, so the line
    /// is `ssh <user>@<host>`, and the echo of it on the bastion's own shell is
    /// the proof it arrived.
    func testAHostBehindAMoshBastionIsReachedByTypingOneSSHLine() async throws {
        var bastion = Host(label: "bastion", hostname: target.host, username: target.username)
        bastion.port = target.port
        bastion.mosh = true
        let savedBastion = try await hosts.save(bastion)

        var destination = Host(label: "behind", hostname: target.host, username: target.username)
        destination.port = target.port
        destination.jumpMode = Host.JumpMode.hostList.rawValue
        destination.jumpHostIdList = Host.formatIDList([savedBastion.id!])
        let savedDestination = try await hosts.save(destination)

        XCTAssertFalse(savedDestination.mosh, "the host being reached must not be the one asking for mosh")

        let session = TerminalSession(host: savedDestination, hosts: hosts, keys: keys)
        defer {
            session.disconnect()
            let until = Date().addingTimeInterval(0.4)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
        }

        // The questions belong to the bastion, which is the machine being
        // dialled: its key, then its password.
        await session.connect()
        await session.connect(acceptHostKey: true)
        await session.connect(password: target.password)

        if case .moshUnavailable(let failure) = session.phase {
            throw XCTSkip("no mosh session on \(target.host): \(failure.reason) — \(failure.detail ?? "")")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a mosh session to the bastion, got \(session.phase)")
        }
        XCTAssertTrue(
            session.barWouldHideOutput,
            "the bastion's switch did not decide the road: this is not a mosh session"
        )

        let typed = await waitForScreen("ssh \(target.username)@\(target.host)", in: session, seconds: 10)
        XCTAssertTrue(typed, "the ssh line never reached the bastion's shell:\n\(screenText(of: session))")
    }

    /// The forwarded agent reaches the shell **mosh** runs, not only an SSH one.
    ///
    /// It used to be asked for only by the shell channel, which a mosh session
    /// never opens: `mosh-server` was started on an exec channel that had not
    /// asked, so the shell it ran had no `SSH_AUTH_SOCK` — and the `ssh` line
    /// typed into a bastion is exactly where the phone's keys are wanted. An
    /// audit found it on 29/10/2026.
    func testTheAgentReachesTheShellMoshRuns() async throws {
        let session = try await connectedSession(agentForwarding: true)
        defer {
            session.disconnect()
            let until = Date().addingTimeInterval(0.4)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
        }
        if case .moshUnavailable(let failure) = session.phase {
            throw XCTSkip("no mosh session on \(target.host): \(failure.reason)")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a mosh session, got \(session.phase)")
        }

        // The prefix and suffix are typed, the path between them is not: only a
        // socket that exists can fill it.
        session.send(text: "echo AGENT=[${SSH_AUTH_SOCK:-none}]\r")

        let answered = await waitForScreen("AGENT=[/", in: session, seconds: 10)
        XCTAssertTrue(answered, "no agent in the mosh shell:\n\(screenText(of: session))")
    }

    /// And it **answers** there: a question to the agent from the mosh shell
    /// comes back.
    ///
    /// The test above only saw the socket's name. Under mosh nothing reads the SSH
    /// connection any more — the screen comes by UDP — so the channel the server
    /// opens back to us for each agent question sat unread, and an `ssh` typed into
    /// a bastion hung at the agent. Reported from the phone on 30/10/2026.
    func testTheAgentAnswersInTheShellMoshRuns() async throws {
        let session = try await connectedSession(agentForwarding: true)
        defer {
            session.disconnect()
            let until = Date().addingTimeInterval(0.4)
            while Date() < until { RunLoop.current.run(mode: .default, before: until) }
        }
        if case .moshUnavailable(let failure) = session.phase {
            throw XCTSkip("no mosh session on \(target.host): \(failure.reason)")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a mosh session, got \(session.phase)")
        }

        // 0 with keys, 1 with none: either is an answer. 2 is no agent at all,
        // and nothing at all is the hang.
        session.send(text: "ssh-add -l >/dev/null 2>&1; echo AGENT=[$?]\r")

        let deadline = Date().addingTimeInterval(15)
        var screen = ""
        while Date() < deadline {
            screen = screenText(of: session)
            if screen.contains("AGENT=[0]") || screen.contains("AGENT=[1]") { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the agent did not answer in the mosh shell:\n\(screen)")
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
