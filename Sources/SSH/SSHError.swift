// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// libssh2 could not make sense of the key material it was handed: an
    /// unsupported format, a corrupt file, or the wrong passphrase.
    ///
    /// Narrowed on 05/09/2026. It used to cover the two cases below as well —
    /// which meant a host whose key had been deleted was reported as a key that
    /// "may be corrupt, or the passphrase may be wrong", about a passphrase
    /// nobody had been asked for.
    case invalidPrivateKey

    /// The host is set to use a key that is not in the database any more.
    ///
    /// Nothing to do with the key material: the record it points at is gone.
    ///
    /// Defensive, and it should stay unreachable: `hosts.keyId` references
    /// `ssh_keys` with `onDelete: .setNull`, so deleting a key empties the
    /// column rather than leaving a dangling id, and the foreign key refuses to
    /// insert one. `CredentialFailureTests` pins that invariant. The branch
    /// exists because the guard that raises it has to say *something*, and
    /// `keyUnreadable` would be a lie.
    case keyNotFound

    /// The key record exists and its private half could not be read back.
    ///
    /// In practice the Keychain refusing. Distinct from `invalidPrivateKey`
    /// because nothing has tried to parse anything yet.
    case keyUnreadable

    /// The session ended, either because the peer closed it or the network died.
    case disconnected(String)

    /// A libssh2 call failed for a reason with no better mapping.
    case library(code: Int32, message: String)

    case notConnected

    /// The user stopped a transfer. Not a failure, and never worth an alert.
    case cancelled

    /// ⚠️ These are user-visible — `phase = .failed(error.localizedDescription)`
    /// puts them straight into the status panel — and every one of them is
    /// hardcoded English. Localising this enum is its own job, listed in
    /// PIANO.md, and doing it one case at a time would only hide how much of it
    /// is left. New cases here follow the existing pattern deliberately.
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
        case .keyNotFound:
            return "The key this host is set to use is no longer in the app. Edit the host to pick another one, or use a password."
        case .keyUnreadable:
            return "The key this host is set to use could not be read from the Keychain."
        case .disconnected(let detail):
            return "Disconnected: \(detail)"
        case .library(let code, let message):
            return "SSH error \(code): \(message)"
        case .notConnected:
            return "The session is not connected."
        case .cancelled:
            return "Cancelled."
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
