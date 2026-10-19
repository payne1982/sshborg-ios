// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The message a server sends before it lets anyone in, from the wire to the
/// prompt.
///
/// This is the whole reason the password question moved inside the connection:
/// a banner arrives *during* authentication, so a prompt raised before the
/// connect has nothing to show. What that is worth can only be measured against
/// a server that actually sends one — the ordinary test host does not, and
/// configuring one on it would change what every other suite sees. So this
/// suite wants `SSHBORG_TEST_BANNER_PORT`, a throwaway `sshd` with `Banner` set,
/// and skips without it.
///
/// That server authenticates nobody, which costs this suite nothing: everything
/// here happens before a password is sent.
@MainActor
final class ServerBannerTests: XCTestCase {

    private var database: AppDatabase!
    private var hosts: HostRepository!
    private var keys: SSHKeyRepository!
    private var target: SSHTestCredentials.Target!
    private var bannerPort: Int!

    override func setUpWithError() throws {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        guard let port = SSHTestCredentials.bannerPort() else {
            throw XCTSkip("No SSHBORG_TEST_BANNER_PORT: no server sending a banner to read.")
        }
        self.target = target
        self.bannerPort = port
        database = try AppDatabase.makeInMemory()
        hosts = HostRepository(database)
        keys = SSHKeyRepository(database)
    }

    /// A host with nothing stored reaches the password prompt carrying what the
    /// server said — after the key question, which still comes first.
    func testTheBannerReachesThePasswordPrompt() async throws {
        var host = Host(label: "bannered", hostname: target.host, username: target.username)
        host.port = bannerPort
        let session = TerminalSession(host: try await hosts.save(host), hosts: hosts, keys: keys)

        await session.connect()
        guard case .needsHostKeyApproval = session.phase else {
            return XCTFail("expected the host key prompt first, got \(session.phase)")
        }

        await session.connect(acceptHostKey: true)
        guard case .needsPassword(let banner) = session.phase else {
            return XCTFail("expected the password prompt, got \(session.phase)")
        }

        let text = try XCTUnwrap(banner, "the server's banner did not reach the prompt")
        XCTAssertTrue(
            text.contains("SSHBORG-BANNER"),
            "that is not the banner this server sends:\n\(text)"
        )
        // Drawn with spaces and frames, and it has to arrive that way: the box
        // shows it in a monospaced font for exactly this reason.
        XCTAssertTrue(text.contains("+---"), "the drawing did not survive the trip")
        XCTAssertFalse(text.contains("\r"), "CR LF would show as a blank line between every line")
        XCTAssertFalse(text.hasSuffix("\n"), "a trailing blank line pushes the field down for nothing")

        session.disconnect()
    }

    /// And the file browser asks the same question with the same answer in it:
    /// one banner, two screens, from one place in the SSH layer.
    func testTheFileBrowserGetsTheBannerToo() async throws {
        var host = Host(label: "bannered-sftp", hostname: target.host, username: target.username)
        host.port = bannerPort
        let model = SFTPModel(host: try await hosts.save(host), hosts: hosts, keys: keys)

        await model.connect()
        guard case .needsHostKeyApproval = model.phase else {
            return XCTFail("expected the host key prompt first, got \(model.phase)")
        }

        await model.connect(acceptHostKey: true)
        guard case .needsPassword(let banner) = model.phase else {
            return XCTFail("expected the password prompt, got \(model.phase)")
        }
        XCTAssertTrue(try XCTUnwrap(banner).contains("SSHBORG-BANNER"))

        model.disconnect()
    }
}
