// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// A first connection to a host asks two questions in a row, and each answer
/// costs a connection. What this pins is their order, and that answering one
/// does not throw away the answer to the other.
///
/// The order changed on 19/10/2026, with the server's banner. It used to be the
/// password first and the host key second, and the problem then was the one this
/// file was opened for: trusting the key called `connect(acceptHostKey:)`, which
/// carries no password, so the attempt fell back to "nothing to authenticate
/// with" and returned to the password prompt — indistinguishable from a rejected
/// password, and reported as exactly that.
///
/// Now the key comes first, because the password is asked for by the server from
/// inside the connection — the only moment its banner exists — and nothing is
/// sent to a server whose key has not been accepted. The carry runs the other
/// way with it: the accepted key has to survive the password prompt, or the
/// second attempt arrives at an unknown key and asks about the same fingerprint
/// again. The key is only written down once a session is up.
///
/// Needs a real server whose key is *not* already pinned, which is why it lives
/// with the integration tests and skips with them.
@MainActor
final class FirstConnectionQuestionsTests: XCTestCase {

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

    /// The host is stored with no password and no key, so the server has to ask
    /// — and with no `knownHostsEntry`, so the key is asked about too.
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

    func testTheKeyIsAskedFirstAndStaysAcceptedAcrossThePasswordPrompt() async throws {
        let session = try await makeSession()

        await session.connect()
        guard case .needsHostKeyApproval = session.phase else {
            return XCTFail("expected the host key prompt first, got \(session.phase)")
        }

        // Trusting it gets as far as authentication, where the server asks.
        await session.connect(acceptHostKey: true)
        guard case .needsPassword = session.phase else {
            return XCTFail("expected the password prompt second, got \(session.phase)")
        }

        // The whole point: no key is accepted here, because the password panel
        // has none to accept — and the key is still not stored, since no session
        // has come up yet.
        await session.connect(password: target.password)

        if case .needsHostKeyApproval = session.phase {
            XCTFail("the key accepted a moment ago was thrown away by the password prompt")
        }
        guard case .connected = session.phase else {
            return XCTFail("expected a connected session, got \(session.phase)")
        }

        session.disconnect()
    }
}
