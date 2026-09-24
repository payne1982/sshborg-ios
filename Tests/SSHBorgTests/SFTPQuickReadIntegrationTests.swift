// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Reads files over an SFTP channel opened on a session that already has a
/// shell on it — the arrangement the command history now uses instead of
/// logging in a second time.
///
/// It has to be an integration test. What is under test is precisely the
/// behaviour of a *non-blocking* libssh2 session: every call there can answer
/// `EAGAIN` instead of waiting, and no fake reproduces which calls do so and
/// when. Skipped unless a target is configured — see ``SSHIntegrationTests`` for
/// how the credentials arrive.
final class SFTPQuickReadIntegrationTests: XCTestCase {

    private var session: SSHSession!
    private var channel: SSHShellChannel!
    private var scratch: String!
    private var sftp: SFTPSession!
    private var target: SSHTestCredentials.Target!

    override func setUp() async throws {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        self.target = target

        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15

        // A second connection, only to put the fixtures in place and take them
        // away again: what is being tested is the reading, not the writing.
        sftp = try await SFTPSession.connect(params)
        scratch = "sshborg-quickread-\(UUID().uuidString.prefix(8))"
        try await sftp.createDirectory(at: "\(sftp.homePath)/\(scratch!)")

        session = try await SSHSession.connect(params)
        // The shell is what switches the session to non-blocking, which is the
        // whole difficulty this code exists for.
        channel = try await session.openShell(columns: 80, rows: 24)
    }

    override func tearDown() async throws {
        if let sftp, let scratch {
            let directory = "\(sftp.homePath)/\(scratch)"
            for entry in (try? await sftp.list(directory)) ?? [] {
                try? await sftp.removeFile(at: "\(directory)/\(entry.name)")
            }
            try? await sftp.removeDirectory(at: directory)
            sftp.disconnect()
        }
        session?.disconnect()
        channel = nil
    }

    /// Puts a fixture on the server, through the second connection.
    private func write(_ contents: String, to name: String) async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshborg-quickread-\(UUID().uuidString.prefix(8))")
        try Data(contents.utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        try await sftp.upload(from: local, to: "\(sftp.homePath)/\(scratch!)/\(name)")
    }

    func testReadsAFileOverTheShellsOwnSession() async throws {
        let body = "ls -la\ncd /tmp\ngrep -r pattern .\n"
        try await write(body, to: "history-one")

        let files = try await SFTPQuickRead.readFromHome(
            ["\(scratch!)/history-one"],
            on: session
        )

        let data = try XCTUnwrap(files["\(scratch!)/history-one"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), body)
    }

    /// Several files in one channel, which is what the history does: three
    /// candidates, of which most accounts have one.
    func testReadsSeveralFilesAndSkipsTheMissingOnes() async throws {
        try await write("one\n", to: "history-a")
        try await write("two\n", to: "history-b")

        let names = ["\(scratch!)/history-a", "\(scratch!)/nothing-here", "\(scratch!)/history-b"]
        let files = try await SFTPQuickRead.readFromHome(names, on: session)

        XCTAssertEqual(files.count, 2, "a missing file must be absent, not an error")
        XCTAssertEqual(files[names[0]].map { String(decoding: $0, as: UTF8.self) }, "one\n")
        XCTAssertEqual(files[names[2]].map { String(decoding: $0, as: UTF8.self) }, "two\n")
    }

    /// Bigger than one SFTP packet, so the read spans several attempts and the
    /// `EAGAIN` path in the middle of a file is actually taken.
    func testReadsAFileLargerThanOneChunk() async throws {
        let line = "command with a reasonably long line to fill the file up\n"
        let body = String(repeating: line, count: 4000)   // ~220 KB
        try await write(body, to: "history-big")

        let files = try await SFTPQuickRead.readFromHome(["\(scratch!)/history-big"], on: session)

        let data = try XCTUnwrap(files["\(scratch!)/history-big"])
        XCTAssertEqual(data.count, body.utf8.count)
    }

    /// Tearing the session down right after a read must be safe.
    ///
    /// On 24/09/2026 it was not: the channel was shut down by a detached task
    /// that gave up after five seconds of `EAGAIN`, and `libssh2_session_free`
    /// then walked a channel list that shutdown had half-unlinked — SIGSEGV in
    /// `_libssh2_list_remove`, taking the test process with it. The read now
    /// finishes its own teardown before it returns, and the loops it uses never
    /// abandon a call halfway.
    func testDisconnectingRightAfterAReadIsSafe() async throws {
        try await write("something\n", to: "history-d")

        for _ in 0..<3 {
            var params = SSHConnectionParams(
                hostname: target.host,
                port: target.port,
                username: target.username,
                auth: .password(target.password)
            )
            params.hostKeyPolicy = .acceptOnce
            params.connectTimeout = 15

            let other = try await SSHSession.connect(params)
            _ = try await other.openShell(columns: 80, rows: 24)
            _ = try await SFTPQuickRead.readFromHome(["\(scratch!)/history-d"], on: other)
            other.disconnect()
        }

        // Nothing to assert beyond arriving here: the failure mode was a crash.
        XCTAssertTrue(true)
    }

    /// And the shell is still usable afterwards: the point of reading on this
    /// session is that it costs the session nothing.
    func testTheShellStillWorksAfterTheRead() async throws {
        try await write("something\n", to: "history-c")
        _ = try await SFTPQuickRead.readFromHome(["\(scratch!)/history-c"], on: session)

        channel.send(Data("echo sshborg-still-here\n".utf8))

        // The echoed command arrives too, so the marker is split in two to make
        // sure what is seen is the shell's answer and not the keystrokes.
        let expected = "sshborg" + "-still-here"
        var output = ""
        let deadline = Date().addingTimeInterval(15)

        for await data in channel.output {
            output += String(decoding: data, as: UTF8.self)
            if output.components(separatedBy: expected).count > 2 { break }
            if Date() > deadline { break }
        }

        XCTAssertGreaterThan(
            output.components(separatedBy: expected).count, 2,
            "the shell went quiet after the SFTP read"
        )
    }
}
