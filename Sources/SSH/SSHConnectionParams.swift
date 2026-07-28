// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How to authenticate to a host. Mirrors the Android `SshAuth` sealed interface.
enum SSHAuth: Equatable {
    case password(String)
    case publicKey(privateKeyPEM: String, passphrase: String? = nil)
}

/// A single local port-forwarding rule (`-L`).
///
/// Connections to `bindAddress:localPort` are tunnelled to
/// `remoteHost:remotePort` through the SSH session.
struct PortForwarding: Equatable {
    var bindAddress: String = "127.0.0.1"
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
}

/// A single hop in a ProxyJump chain.
struct JumpHost: Equatable {
    var host: String
    var port: Int = 22

    /// `nil` means the target host's username is reused for this hop.
    var username: String?

    /// `known_hosts` line for this hop: `nil` on first connect.
    var knownHostsEntry: String?

    /// Explicit credentials for this hop. `nil` means the target host's
    /// credentials are reused, which is the simple-mode behaviour.
    var auth: SSHAuth?

    /// ID of the ``Host`` record this hop came from, in host-list mode, so a
    /// newly seen host key can be written back to that host's own record.
    var hostId: Int64?
}

/// What to do about the server's host key.
///
/// The Android app asks the user through a callback in the middle of the
/// connection. Here the connection instead fails with
/// ``SSHError/unknownHostKey(_:)`` or ``SSHError/hostKeyMismatch(_:)``, the UI
/// decides, and the connection is retried with ``acceptOnce``. That keeps the
/// SSH layer free of reentrancy into the UI, and makes both outcomes testable.
enum HostKeyPolicy: Equatable {
    /// Fail unless the presented key matches this stored `known_hosts` line.
    case requireMatch(String)

    /// Nothing stored yet: report the key back through
    /// ``SSHError/unknownHostKey(_:)`` so the user can check the fingerprint.
    ///
    /// This is the default, and it deliberately does not trust on first use.
    /// Android shows a confirmation on the first connection too, and silently
    /// pinning whatever answers first would make the whole `known_hosts`
    /// mechanism decorative.
    case promptIfUnknown

    /// The user has been shown the fingerprint and accepted it.
    case acceptOnce
}

/// Everything needed to open an SSH connection. Mirrors `SshConnectionParams`.
struct SSHConnectionParams {
    var hostname: String
    var port: Int = 22
    var username: String
    var auth: SSHAuth
    var hostKeyPolicy: HostKeyPolicy = .promptIfUnknown
    var agentForwarding: Bool = false

    /// Ordered jump hosts to tunnel through before reaching the target.
    var jumpHosts: [JumpHost] = []

    /// Local forwarding rules to activate once connected.
    var portForwardings: [PortForwarding] = []

    /// Appends legacy/weak algorithms to the negotiation list, for old servers.
    var allowLegacyCiphers: Bool = false

    /// How long to wait for the TCP connection and the SSH handshake.
    var connectTimeout: TimeInterval = 20

    /// Interval between keepalive packets. Matches the Android
    /// `ServerAliveInterval` of 30 seconds.
    var keepAliveInterval: TimeInterval = 30
}

// MARK: - Parsing

extension PortForwarding {

    /// Parses a newline-separated list of `-L` specs.
    ///
    /// Accepted forms:
    ///
    ///     localPort:remoteHost:remotePort
    ///     bindAddress:localPort:remoteHost:remotePort
    ///
    /// Blank or unparsable lines are skipped rather than failing the whole
    /// connection, matching `parsePortForwardings` on Android.
    static func parseList(_ raw: String?) -> [PortForwarding] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        return raw.split(whereSeparator: \.isNewline).compactMap { line in
            var spec = line.trimmingCharacters(in: .whitespaces)
            if spec.hasPrefix("-L") {
                spec = String(spec.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !spec.isEmpty else { return nil }

            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 3:
                guard let localPort = Int(parts[0]), let remotePort = Int(parts[2]) else { return nil }
                return PortForwarding(localPort: localPort, remoteHost: parts[1], remotePort: remotePort)
            case 4:
                guard let localPort = Int(parts[1]), let remotePort = Int(parts[3]) else { return nil }
                return PortForwarding(
                    bindAddress: parts[0],
                    localPort: localPort,
                    remoteHost: parts[2],
                    remotePort: remotePort
                )
            default:
                return nil
            }
        }
    }
}

extension JumpHost {

    /// Parses a jump-host string such as `"user@host1:22,host2"` together with a
    /// newline-delimited blob of stored `known_hosts` lines.
    ///
    /// Each token is `[user@]host[:port]`; user and port are optional.
    /// Mirrors `parseJumpHosts` on Android, including its rule that a trailing
    /// `:something` is only treated as a port when it is a valid port number, so
    /// that plain hostnames are never mangled.
    static func parseList(_ raw: String?, knownHostKeys blob: String?) -> [JumpHost] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let keysByHost = KnownHostsLine.indexByHostPort(blob)

        return raw.split(separator: ",").compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            var username: String?
            var hostPort = trimmed
            if let atIndex = trimmed.firstIndex(of: "@") {
                let name = String(trimmed[trimmed.startIndex..<atIndex])
                username = name.isEmpty ? nil : name
                hostPort = String(trimmed[trimmed.index(after: atIndex)...])
            }

            var host = hostPort
            var port = 22
            if let colonIndex = hostPort.lastIndex(of: ":") {
                let suffix = String(hostPort[hostPort.index(after: colonIndex)...])
                if let parsed = Int(suffix), (1...65535).contains(parsed) {
                    host = String(hostPort[hostPort.startIndex..<colonIndex])
                    port = parsed
                }
            }
            guard !host.isEmpty else { return nil }

            return JumpHost(
                host: host,
                port: port,
                username: username,
                knownHostsEntry: keysByHost["\(host):\(port)"]
            )
        }
    }
}
