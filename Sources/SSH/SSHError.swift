// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CSSH2
import Foundation

/// Everything that can go wrong establishing or running an SSH session.
enum SSHError: LocalizedError, Equatable {

    /// The TCP connection could not be made.
    case connectionFailed(String)

    case timedOut

    /// The server presented a key and none is stored yet. The caller should show
    /// the fingerprint, and retry with ``HostKeyPolicy/acceptOnce`` if accepted.
    case unknownHostKey(HostKeyInfo)

    /// The server presented a key that differs from the stored one. This is
    /// either a reinstalled server or an active attack; never accept it silently.
    case hostKeyMismatch(HostKeyInfo)

    case authenticationFailed(String)

    /// The private key could not be parsed, or the passphrase was wrong.
    case invalidPrivateKey

    /// The session ended, either because the peer closed it or the network died.
    case disconnected(String)

    /// A libssh2 call failed for a reason with no better mapping.
    case library(code: Int32, message: String)

    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            return "Could not connect: \(detail)"
        case .timedOut:
            return "The connection timed out."
        case .unknownHostKey(let info):
            return "Unknown host key (\(info.fingerprint))."
        case .hostKeyMismatch(let info):
            return "The host key has changed (\(info.fingerprint)). This could mean the server was rebuilt, or that the connection is being intercepted."
        case .authenticationFailed(let detail):
            return "Authentication failed: \(detail)"
        case .invalidPrivateKey:
            return "The private key could not be read. It may be corrupt, or the passphrase may be wrong."
        case .disconnected(let detail):
            return "Disconnected: \(detail)"
        case .library(let code, let message):
            return "SSH error \(code): \(message)"
        case .notConnected:
            return "The session is not connected."
        }
    }
}

extension SSHError {

    /// Wraps the last error reported by a libssh2 session, mapping the codes
    /// that deserve their own case.
    static func fromSession(_ session: OpaquePointer?, fallback: String = "unknown error") -> SSHError {
        guard let session else { return .library(code: 0, message: fallback) }

        var messageBuffer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        let code = libssh2_session_last_error(session, &messageBuffer, &messageLength, 0)

        let message: String
        if let messageBuffer, messageLength > 0 {
            message = String(cString: messageBuffer)
        } else {
            message = fallback
        }

        switch code {
        case LIBSSH2_ERROR_TIMEOUT:
            return .timedOut
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED, LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED:
            return .authenticationFailed(message)
        case LIBSSH2_ERROR_FILE, LIBSSH2_ERROR_PUBLICKEY_PROTOCOL:
            return .invalidPrivateKey
        case LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV:
            return .disconnected(message)
        default:
            return .library(code: code, message: message)
        }
    }
}
