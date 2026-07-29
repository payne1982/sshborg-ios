// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import XCTest

@testable import SSHBorg

/// Exercises agent forwarding against a real server.
///
/// The unit tests prove the agent answers correctly when handed the right bytes.
/// What they cannot prove is that the bytes ever arrive: that needs a server
/// that opens `auth-agent@openssh.com` back at us, and a client on the far end
/// that speaks the protocol for real. So these run `ssh-add` in the forwarded
/// shell and read what OpenSSH itself makes of our agent.
///
/// Requires `AllowAgentForwarding yes` on the test server, which is the default.
final class AgentForwardingIntegrationTests: XCTestCase {

    private typealias Target = SSHTestCredentials.Target

    private func target() throws -> Target {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }
        return target
    }

    private func params(_ target: Target, identities: [AgentIdentity]) -> SSHConnectionParams {
        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15
        params.agentForwarding = true
        params.agentIdentities = identities
        return params
    }

    // MARK: - Tests

    /// The narrowest question first: does asking for agent forwarding break the
    /// shell? Everything below depends on the answer being no, and when they all
    /// fail together this is what says whether the fault is in the request or in
    /// the agent behind it.
    func testShellStillWorksWithForwardingOn() async throws {
        let target = try target()
        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "sshborg-smoke")
        let identities = [AgentIdentity(privateKeyPEM: key.privateKeyPEM, passphrase: nil)]

        let session = try await SSHSession.connect(params(target, identities: identities))
        defer { session.disconnect() }

        let result = try await run("echo SHELL_ALIVE; echo SOCK=[$SSH_AUTH_SOCK]", on: session)

        XCTAssertTrue(
            result.output.contains("SHELL_ALIVE"),
            "the shell produced nothing with agent forwarding on.\nRaw:\n\(result.raw)"
        )
        // The server sets this only if it accepted the forwarding request, so it
        // separates "the server said no" from "our agent misbehaved".
        XCTAssertFalse(
            result.output.contains("SOCK=[]"),
            "the server did not set SSH_AUTH_SOCK.\nRaw:\n\(result.raw)"
        )
    }

    /// `ssh-add -l` on the far end must list exactly the keys the app holds,
    /// with the fingerprints OpenSSH computes for them.
    func testRemoteSSHAddListsTheForwardedKeys() async throws {
        let target = try target()

        let ed25519 = try SSHKeyGenerator.generate(type: .ed25519, comment: "sshborg-ios-test")
        let ecdsa = try SSHKeyGenerator.generate(type: .ecdsa, bits: 256, comment: "sshborg-ecdsa-test")

        let identities = [ed25519, ecdsa].map {
            AgentIdentity(privateKeyPEM: $0.privateKeyPEM, passphrase: nil)
        }

        let session = try await SSHSession.connect(params(target, identities: identities))
        defer { session.disconnect() }

        let result = try await run("ssh-add -l", on: session)

        // The agent must actually have been asked. Without this the test would
        // still pass if `ssh-add` read the keys from somewhere else entirely.
        let diagnostics = session.agentDiagnostics
        XCTAssertEqual(diagnostics?.acceptedChannels, 1, "the server never opened an agent channel")
        XCTAssertEqual(diagnostics?.requestsHandled, 1, "the agent was never asked for its identities")

        for key in [ed25519, ecdsa] {
            let fingerprint = try fingerprint(ofPublicKeyLine: key.publicKeyLine)
            XCTAssertTrue(
                result.output.contains(fingerprint),
                "ssh-add did not list \(key.type).\nExtracted: \(result.output)\nRaw:\n\(result.raw)"
            )
        }
        XCTAssertTrue(
            result.output.contains("sshborg-ios-test"),
            "the comment did not survive.\nRaw:\n\(result.raw)"
        )
    }

    /// The one that proves the whole path: `ssh-keygen -Y sign` makes OpenSSH ask
    /// our agent for a real signature and then verifies it itself. A signature
    /// that is well-formed but wrong fails here and nowhere earlier.
    func testRemoteOpenSSHAcceptsASignatureFromOurAgent() async throws {
        let target = try target()

        let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "sshborg-sign-test")
        let identities = [AgentIdentity(privateKeyPEM: key.privateKeyPEM, passphrase: nil)]

        let session = try await SSHSession.connect(params(target, identities: identities))
        defer { session.disconnect() }

        // Write the public key out, sign a message through the agent, then have
        // ssh-keygen verify the signature against an allowed-signers file. Every
        // step happens on the server, using its own OpenSSH.
        let directory = "/tmp/sshborg-agent-\(UUID().uuidString.prefix(8))"
        let script = """
        mkdir -p \(directory) && cd \(directory) && \
        printf '%s\\n' '\(key.publicKeyLine)' > id.pub && \
        printf 'signer %s\\n' '\(key.publicKeyLine)' > allowed && \
        echo 'message to sign' > message && \
        ssh-keygen -Y sign -f id.pub -n file message 2>&1 && \
        ssh-keygen -Y verify -f allowed -I signer -n file -s message.sig < message 2>&1; \
        cd /; rm -rf \(directory)
        """

        let result = try await run(script, on: session)

        // ssh-keygen prints "Good \"file\" signature ..." only when the signature
        // it got from our agent actually verifies.
        XCTAssertTrue(
            result.output.contains("Good \"file\" signature"),
            "OpenSSH did not accept a signature made by our agent.\nExtracted: \(result.output)\nRaw:\n\(result.raw)"
        )
    }

    /// With forwarding off there must be no socket at all — an agent that leaks
    /// into a session the user did not enable it for is a security bug.
    func testAgentIsAbsentWhenForwardingIsOff() async throws {
        let target = try target()

        var params = params(target, identities: [])
        params.agentForwarding = false

        let session = try await SSHSession.connect(params)
        defer { session.disconnect() }

        let result = try await run("echo AUTH_SOCK=[$SSH_AUTH_SOCK]", on: session)
        XCTAssertTrue(
            result.output.contains("AUTH_SOCK=[]"),
            "SSH_AUTH_SOCK was set without agent forwarding:\n\(result.raw)"
        )
    }

    // MARK: - Helpers

    /// Runs a command in an interactive shell and returns everything printed
    /// between two markers, so the prompt and the echo of the command itself do
    /// not end up in the result.
    ///
    /// Returns the raw stream alongside it: when a marker never arrives, the
    /// extracted text is empty and says nothing about why, whereas the raw
    /// stream distinguishes "the shell died" from "the command printed nothing".
    private func run(
        _ command: String,
        on session: SSHSession
    ) async throws -> (output: String, raw: String) {
        let channel = try await session.openShell(columns: 200, rows: 50)
        defer { channel.close() }

        let id = UUID().uuidString.prefix(8)
        let start = "SSHBORG_BEGIN_\(id)"
        let end = "SSHBORG_END_\(id)"

        // The markers are split by empty quotes in what gets typed, so the shell
        // prints `SSHBORG_END_x` while the echo of the command line reads
        // `SSHBORG_EN''D_x`. Without this the two are indistinguishable, and
        // counting occurrences does not save it: a PTY echoes the line once and
        // zsh redraws it, so the marker can appear twice before the command has
        // run at all. That made this helper return the prompt instead of the
        // output, at a moment that varied from run to run.
        let typedStart = "SSHBORG_BEG''IN_\(id)"
        let typedEnd = "SSHBORG_EN''D_\(id)"

        channel.send(Data("echo \(typedStart); \(command); echo \(typedEnd)\n".utf8))

        let collector = Task { () -> String in
            var text = ""
            for await chunk in channel.output {
                text += String(decoding: chunk, as: UTF8.self)
                if text.contains(end) { return text }
            }
            return text
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            collector.cancel()
        }
        let text = await collector.value
        watchdog.cancel()

        // First occurrence, not last: with the quote trick the only clean marker
        // in the stream is the one the shell printed.
        guard let after = text.range(of: start) else { return ("", text) }
        let tail = String(text[after.upperBound...])
        guard let before = tail.range(of: end) else { return (tail, text) }
        return (String(tail[..<before.lowerBound]), text)
    }

    /// The `SHA256:…` fingerprint OpenSSH prints for a public key line.
    private func fingerprint(ofPublicKeyLine line: String) throws -> String {
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw XCTSkip("could not read the generated public key line")
        }

        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}
