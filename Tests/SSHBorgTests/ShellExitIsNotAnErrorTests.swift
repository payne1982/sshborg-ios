// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Leaving a shell with `exit` is not a failure, whatever number it carries.
///
/// The session used to report `exit status 1` as the reason for disconnecting.
/// `exit` with no argument returns the status of the last command, so running
/// anything that failed and then typing `exit` produced a disconnection panel
/// that looked like something had gone wrong — reported as "it says exit status
/// 1 and treats it as an error".
///
/// Non-zero on purpose here: zero would pass even with the old logic, which only
/// spoke up when the status was not zero.
@MainActor
final class ShellExitIsNotAnErrorTests: XCTestCase {

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

    func testLeavingWithANonZeroStatusDisconnectsWithoutAReason() async throws {
        var host = Host(label: "exiting", hostname: target.host, username: target.username)
        host.port = target.port
        host.password = target.password
        let session = TerminalSession(host: try await hosts.save(host), hosts: hosts, keys: keys)

        await session.connect(acceptHostKey: true)
        guard case .connected = session.phase else {
            return XCTFail("could not connect: \(session.phase)")
        }

        session.send(text: "exit 3\n")

        // The stream ends asynchronously: the reader task has to see EOF and the
        // exit status has to arrive behind it.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .disconnected = session.phase { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        guard case .disconnected(let reason) = session.phase else {
            return XCTFail("the session never noticed the shell had gone: \(session.phase)")
        }
        XCTAssertNil(reason, "a deliberate exit was reported as a reason to worry: \(reason ?? "")")

        session.disconnect()
    }
}
