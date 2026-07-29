// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An ssh-agent, serving the keys the app holds.
///
/// This is the piece the original plan expected to avoid. libssh2 1.11 declares
/// `LIBSSH2_CALLBACK_AUTHAGENT_IDENTITIES` and `_SIGN`, which read as though the
/// library speaks the agent protocol and only asks us to list and sign — but the
/// macros that would invoke them, `LIBSSH2_ADD_IDENTITIES` and
/// `LIBSSH2_AUTHAGENT_SIGN`, are defined in `libssh2_priv.h` and called from
/// nowhere in 1.11.1. They are hooks for a libssh2-based *server*. What libssh2
/// actually does for a client is accept the server's `auth-agent@openssh.com`
/// channel and hand it over through `LIBSSH2_CALLBACK_AUTHAGENT`; the protocol
/// on that channel is ours to speak.
///
/// It is still far less work than the UNIX-socket agent the plan called for,
/// because a forwarded agent only ever gets asked two questions. Everything else
/// — adding keys, removing them, locking, smartcards — is answered with a
/// failure, which is what a restricted agent is supposed to do.
///
/// Reference: OpenSSH's `PROTOCOL.agent`.
struct SSHAgent {

    /// Message numbers. Only the ones this agent uses are named.
    enum Message {
        static let failure: UInt8 = 5
        static let success: UInt8 = 6
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    /// A cap on one request, so a confused or hostile peer cannot make the app
    /// allocate without bound. Real requests are a few hundred bytes; the data
    /// to be signed is a session identifier plus a username.
    static let maximumRequestLength = 256 * 1024

    private let identities: [SSHSigner]

    init(identities: [SSHSigner]) {
        self.identities = identities
    }

    var isEmpty: Bool { identities.isEmpty }

    /// Answers one agent request. `request` and the result are both payloads,
    /// without the length prefix that frames them on the wire.
    ///
    /// This never throws: a failure to sign is an answer the protocol has a
    /// message for, and turning it into a Swift error would only mean the caller
    /// has to convert it back.
    func respond(to request: Data) -> Data {
        guard let type = request.first else { return Self.framed(Message.failure) }
        let body = Data(request.dropFirst())

        switch type {
        case Message.requestIdentities:
            return identitiesAnswer()
        case Message.signRequest:
            return signResponse(for: body)
        default:
            return Self.framed(Message.failure)
        }
    }

    // MARK: - Requests

    private func identitiesAnswer() -> Data {
        var encoder = SSHWireEncoder()
        encoder.write(uint32: UInt32(identities.count))
        for identity in identities {
            encoder.write(string: identity.publicKeyBlob)
            encoder.write(string: identity.comment)
        }
        return Self.framed(Message.identitiesAnswer, payload: encoder.data)
    }

    /// `string key_blob | string data | uint32 flags`
    private func signResponse(for body: Data) -> Data {
        var decoder = SSHWireDecoder(body)

        guard let keyBlob = try? decoder.readString(),
              let data = try? decoder.readString()
        else {
            return Self.framed(Message.failure)
        }
        // Older clients omit the flags word entirely.
        let flags = (try? decoder.readUInt32()) ?? 0

        // Constant-time comparison is pointless here: the blob is a public key,
        // and the peer already knows it — it is what we just sent them.
        guard let identity = identities.first(where: { $0.publicKeyBlob == keyBlob }),
              let signature = try? identity.signature(for: data, flags: flags)
        else {
            return Self.framed(Message.failure)
        }

        var encoder = SSHWireEncoder()
        encoder.write(string: signature)
        return Self.framed(Message.signResponse, payload: encoder.data)
    }

    // MARK: - Framing

    private static func framed(_ type: UInt8, payload: Data = Data()) -> Data {
        Data([type]) + payload
    }
}

/// Splits an agent channel's byte stream into requests.
///
/// Each message is a 32-bit length followed by that many bytes. A channel read
/// can end anywhere, so this holds the remainder until the rest arrives.
struct SSHAgentFraming {

    private var buffer = Data()

    /// True once a length prefix has been read that exceeds the cap, at which
    /// point the stream cannot be resynchronised and the channel should close.
    private(set) var isPoisoned = false

    mutating func append(_ bytes: Data) {
        guard !isPoisoned else { return }
        buffer += bytes
    }

    /// The next complete request, or `nil` when more bytes are needed.
    mutating func nextRequest() -> Data? {
        guard !isPoisoned, buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        var length = 0
        for offset in 0..<4 {
            length = (length << 8) | Int(buffer[start + offset])
        }

        guard length > 0, length <= SSHAgent.maximumRequestLength else {
            // A zero or absurd length means we are no longer aligned to a
            // message boundary; there is no way back from that.
            isPoisoned = true
            return nil
        }
        guard buffer.count >= 4 + length else { return nil }

        let request = Data(buffer[(start + 4)..<(start + 4 + length)])
        buffer.removeFirst(4 + length)
        return request
    }

    /// Wraps a response for the wire.
    static func frame(_ payload: Data) -> Data {
        var encoder = SSHWireEncoder()
        encoder.write(string: payload)
        return encoder.data
    }
}
