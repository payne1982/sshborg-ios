// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// A host key as presented by a server, in the form the UI needs to show it and
/// the database needs to store it.
struct HostKeyInfo: Equatable {
    /// Hostname as written in the `known_hosts` marker, e.g. `example.com` or
    /// `[example.com]:2222`.
    let marker: String

    /// SSH algorithm name, e.g. `ssh-ed25519`.
    let algorithm: String

    /// Base64 of the raw key blob.
    let base64Key: String

    /// OpenSSH-style fingerprint, e.g. `SHA256:6dV5…`, for display to the user.
    let fingerprint: String

    /// The full `known_hosts` line to persist once the user accepts.
    var knownHostsLine: String {
        "\(marker) \(algorithm) \(base64Key)"
    }
}

/// Builds and reads the single-line `known_hosts` entries SSHBorg stores per
/// host, rather than in one global file.
enum KnownHostsLine {

    /// Formats a host for the leading marker of a `known_hosts` line, following
    /// the OpenSSH convention that non-default ports are bracketed. The Android
    /// app relies on the same convention when it indexes stored jump-host keys.
    static func marker(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Splits a line into its three fields, or `nil` when it is not well formed.
    static func parse(_ line: String) -> (marker: String, algorithm: String, base64Key: String)? {
        let fields = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        guard fields.count >= 3 else { return nil }
        return (fields[0], fields[1], fields[2])
    }

    /// Reverses ``marker(host:port:)``.
    static func hostAndPort(fromMarker marker: String) -> (host: String, port: Int)? {
        guard marker.hasPrefix("[") else {
            return marker.isEmpty ? nil : (marker, 22)
        }
        guard let closing = marker.firstIndex(of: "]") else { return nil }

        let host = String(marker[marker.index(after: marker.startIndex)..<closing])
        let remainder = marker[marker.index(after: closing)...]
        guard remainder.hasPrefix(":"), let port = Int(remainder.dropFirst()) else { return nil }
        guard !host.isEmpty else { return nil }

        return (host, port)
    }

    /// Indexes a newline-delimited blob of `known_hosts` lines by `"host:port"`,
    /// normalising both the bare and the bracketed marker forms so a lookup
    /// works regardless of port. Mirrors the map built in `parseJumpHosts`.
    static func indexByHostPort(_ blob: String?) -> [String: String] {
        guard let blob else { return [:] }

        var index: [String: String] = [:]
        for line in blob.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard let parsed = parse(line),
                  let target = hostAndPort(fromMarker: parsed.marker)
            else { continue }
            // Every line for a machine, not the last one: an entry can hold a
            // key per algorithm, and dropping one would make it a mismatch.
            let key = "\(target.host):\(target.port)"
            index[key] = index[key].map { $0 + "\n" + line } ?? line
        }
        return index
    }

    /// Whether a presented key matches a stored entry.
    ///
    /// Only the algorithm and the key material are compared. The marker is
    /// deliberately ignored: a host renamed or moved to a different port still
    /// matches the key the user already accepted, and a genuine key change is
    /// still caught.
    ///
    /// **Any** line of the entry, not just the first. An entry holds a key per
    /// algorithm: Android keeps the other algorithms when one is replaced (its
    /// `KnownHosts.replacing`, 30/10/2026), so one arrives here through a backup,
    /// and reading only its first line would turn the second algorithm into a
    /// "changed key" every time it was offered.
    static func matches(storedLine entry: String, algorithm: String, base64Key: String) -> Bool {
        entry.split(whereSeparator: \.isNewline).contains { line in
            guard let parsed = parse(String(line)) else { return false }
            return parsed.algorithm == algorithm && parsed.base64Key == base64Key
        }
    }

    /// What to store once the person has accepted `arriving`: the line pinned
    /// for that algorithm gives way to it, and every other line is kept.
    ///
    /// Kept, because the other lines are other algorithms, and accepting one key
    /// says nothing about them. Android's `KnownHosts.replacing`, with one
    /// difference that follows from ``matches(storedLine:algorithm:base64Key:)``:
    /// the marker is not compared here either, because one entry belongs to one
    /// host record.
    static func replacing(pinned entry: String?, arriving line: String) -> String {
        guard let algorithm = parse(line)?.algorithm else { return line }
        let kept = (entry ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { parse($0)?.algorithm != algorithm && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (kept + [line]).joined(separator: "\n")
    }

    /// Formats a raw key blob the way OpenSSH prints fingerprints:
    /// `SHA256:` followed by unpadded base64 of the digest.
    static func fingerprint(forKeyBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.replacingOccurrences(of: "=", with: "")
    }
}
