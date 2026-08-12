// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// A first connection to a host asks two questions in a row, and the second used
/// to erase the answer to the first.
///
/// Typing the password produced the host key prompt, and trusting the key called
/// `connect(acceptHostKey:)`, which carries no password — so the attempt fell
/// back to "nothing to authenticate with" and returned to the password prompt.
/// From the outside that is indistinguishable from a rejected password, and it
/// was reported as exactly that: "it asks for the password again as if I had got
/// it wrong."
///
/// Needs a real server whose key is *not* already pinned, which is why it lives
/// with the integration tests and skips with them.
@MainActor
final class PasswordCarriesAcrossHostKeyPromptTests: XCTestCase {

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

    /// The host is stored with no password and no key, so the session has to ask
    /// — and with no `knownHostsEntry`, so it has to ask about the key too.
    private func makeSession() async throws -> TerminalSession {
        var host = Host(
            label: "unpinned",
            hostname: target.host,
            username: target.username
        )
        host.port = target.port
        let saved = try await hosts.save(host)
        return TerminalSession(host: saved, hosts: hosts, keys: keys)
    }

    func testTrustingTheHostKeyKeepsThePasswordAlreadyTyped() async throws {
        let session = try await makeSession()

        await session.connect()
        guard case .needsPassword = session.phase else {
            return XCTFail("expected the password prompt first, got \(session.phase)")
        }

        await session.connect(password: target.password)
        guard case .needsHostKeyApproval = session.phase else {
            return XCTFail("expected the host key prompt second, got \(session.phase)")
        }

        // The whole point: no password is passed here, because the Trust button
        // has none to pass.
        await session.connect(acceptHostKey: true)

        if case .needsPassword = session.phase {
            XCTFail("the password typed a moment ago was thrown away by the host key prompt")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a connected session, got \(session.phase)")
        }

        session.disconnect()
    }
}
