// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import XCTest

@testable import SSHBorg

/// Drives the agent the way a client on the far end would: by handing it the
/// exact bytes `ssh-add` puts on the socket and reading back what it answers.
final class SSHAgentTests: XCTestCase {

    private func makeSigners(_ count: Int) throws -> [SSHSigner] {
        try (0..<count).map { index in
            let key = try SSHKeyGenerator.generate(type: .ed25519, comment: "key-\(index)")
            return try SSHSigner.make(privateKeyPEM: key.privateKeyPEM)
        }
    }

    // MARK: - Listing

    func testListsEveryIdentityWithItsComment() throws {
        let signers = try makeSigners(3)
        let agent = SSHAgent(identities: signers)

        let response = agent.respond(to: Data([SSHAgent.Message.requestIdentities]))

        XCTAssertEqual(response.first, SSHAgent.Message.identitiesAnswer)
        var decoder = SSHWireDecoder(Data(response.dropFirst()))
        XCTAssertEqual(try decoder.readUInt32(), 3)

        for signer in signers {
            XCTAssertEqual(try decoder.readString(), signer.publicKeyBlob)
            XCTAssertEqual(try decoder.readStringAsText(), signer.comment)
        }
        XCTAssertTrue(decoder.isAtEnd, "the answer carried more than it should")
    }

    /// An agent with nothing in it is a normal state, not an error: the far end
    /// gets an empty list and moves on to the next authentication method.
    func testEmptyAgentAnswersWithZeroIdentities() throws {
        let agent = SSHAgent(identities: [])
        let response = agent.respond(to: Data([SSHAgent.Message.requestIdentities]))

        XCTAssertEqual(response.first, SSHAgent.Message.identitiesAnswer)
        var decoder = SSHWireDecoder(Data(response.dropFirst()))
        XCTAssertEqual(try decoder.readUInt32(), 0)
    }

    // MARK: - Signing

    func testSignsWithTheRequestedKey() throws {
        let signers = try makeSigners(2)
        let agent = SSHAgent(identities: signers)
        let payload = Data("session id and username".utf8)

        // Ask the second key specifically, so picking the first would pass a
        // weaker test and fail this one.
        let wanted = signers[1]
        var request = SSHWireEncoder()
        request.write(string: wanted.publicKeyBlob)
        request.write(string: payload)
        request.write(uint32: 0)

        let response = agent.respond(to: Data([SSHAgent.Message.signRequest]) + request.data)
        XCTAssertEqual(response.first, SSHAgent.Message.signResponse)

        var decoder = SSHWireDecoder(Data(response.dropFirst()))
        var blob = SSHWireDecoder(try decoder.readString())
        XCTAssertEqual(try blob.readStringAsText(), "ssh-ed25519")
        let signature = try blob.readString()

        var publicBlob = SSHWireDecoder(wanted.publicKeyBlob)
        _ = try publicBlob.readString()
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try publicBlob.readString())
        XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    }

    /// A key we do not hold must be refused rather than signed with whatever is
    /// at hand — the far end would otherwise get a signature it cannot verify.
    func testUnknownKeyIsRefused() throws {
        let agent = SSHAgent(identities: try makeSigners(1))
        let stranger = try SSHSigner.make(
            privateKeyPEM: try SSHKeyGenerator.generate(type: .ed25519).privateKeyPEM
        )

        var request = SSHWireEncoder()
        request.write(string: stranger.publicKeyBlob)
        request.write(string: Data("sign this".utf8))
        request.write(uint32: 0)

        let response = agent.respond(to: Data([SSHAgent.Message.signRequest]) + request.data)
        XCTAssertEqual(response, Data([SSHAgent.Message.failure]))
    }

    func testTruncatedSignRequestFails() throws {
        let agent = SSHAgent(identities: try makeSigners(1))
        let response = agent.respond(to: Data([SSHAgent.Message.signRequest, 0x00, 0x00]))
        XCTAssertEqual(response, Data([SSHAgent.Message.failure]))
    }

    /// Adding, removing and locking keys are all things a *forwarded* agent must
    /// not do. Refusing them is the behaviour, not a gap.
    func testEverythingElseIsRefused() throws {
        let agent = SSHAgent(identities: try makeSigners(1))

        for type: UInt8 in [1, 17, 18, 20, 21, 22, 25, 27] {
            XCTAssertEqual(
                agent.respond(to: Data([type])),
                Data([SSHAgent.Message.failure]),
                "message \(type) should have been refused"
            )
        }
        XCTAssertEqual(agent.respond(to: Data()), Data([SSHAgent.Message.failure]))
    }

    // MARK: - Framing

    func testFramingReassemblesASplitMessage() {
        var framing = SSHAgentFraming()
        let payload = Data([SSHAgent.Message.requestIdentities])
        let wire = SSHAgentFraming.frame(payload)

        // A channel read can end anywhere, including inside the length prefix.
        for split in 1..<wire.count {
            var partial = SSHAgentFraming()
            partial.append(Data(wire.prefix(split)))
            XCTAssertNil(partial.nextRequest(), "produced a request from \(split) of \(wire.count) bytes")
            partial.append(Data(wire.suffix(from: wire.startIndex + split)))
            XCTAssertEqual(partial.nextRequest(), payload)
        }

        framing.append(wire)
        XCTAssertEqual(framing.nextRequest(), payload)
        XCTAssertNil(framing.nextRequest())
    }

    func testFramingHandlesSeveralMessagesInOneRead() {
        var framing = SSHAgentFraming()
        let first = Data([SSHAgent.Message.requestIdentities])
        let second = Data([SSHAgent.Message.signRequest, 0x01])

        framing.append(SSHAgentFraming.frame(first) + SSHAgentFraming.frame(second))

        XCTAssertEqual(framing.nextRequest(), first)
        XCTAssertEqual(framing.nextRequest(), second)
        XCTAssertNil(framing.nextRequest())
    }

    /// A length that could not possibly be real means the stream is no longer
    /// aligned to a message boundary. There is no resynchronising from that, so
    /// the channel has to go rather than allocate whatever was asked for.
    func testAbsurdLengthPoisonsTheStream() {
        var framing = SSHAgentFraming()
        framing.append(Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 8))

        XCTAssertNil(framing.nextRequest())
        XCTAssertTrue(framing.isPoisoned)
    }

    func testZeroLengthPoisonsTheStream() {
        var framing = SSHAgentFraming()
        framing.append(Data([0, 0, 0, 0]))

        XCTAssertNil(framing.nextRequest())
        XCTAssertTrue(framing.isPoisoned)
    }
}
