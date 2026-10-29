// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What `mosh-server` hands back when it starts: where to talk UDP, and the key
/// for the session.
///
/// SSH is only the ignition. It logs in, starts the server, reads one line, and
/// that line is the whole handover — after it the terminal rides UDP. The SSH
/// session itself is **not** closed, which is where we part company with the
/// stock client: it carries SFTP, port forwarding, the agent and the shell
/// history, and all of that keeps working because it stays.
///
/// Translated from Android's `MoshBootstrap`, whose shape is worth keeping: the
/// parsing and the redaction are pure functions, so they are tested as such
/// rather than through a connection.
struct MoshHandover: Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {

    let host: String
    let port: Int
    let key: String

    /// Deliberately says nothing: the key is the session's secret and must not
    /// reach a log.
    ///
    /// And it has to be *the* description, not a property that happens to share
    /// the name. Until 29/10/2026 it was the latter, so `"\(handover)"`,
    /// `String(reflecting:)` and `dump` all fell back to printing every field —
    /// the key among them. An audit noticed; nothing printed one yet.
    var description: String { "MoshHandover(\(host):\(port))" }

    var debugDescription: String { description }

    /// What `dump` and the debugger walk, which ignore `description`: the
    /// address only.
    var customMirror: Mirror {
        Mirror(self, children: ["host": host, "port": port], displayStyle: .struct)
    }

    /// `MOSH CONNECT <port> <key>`, the whole of the handover.
    ///
    /// Read out of whatever the server said, because it says other things too —
    /// its version, its copyright, and the line about detaching. Verified
    /// against mosh 1.4.0's own output on 25/10/2026: four fields, a port, and
    /// a key of 22 base64 characters with the padding left off.
    static func parse(_ said: String, host: String) -> MoshHandover? {
        for line in said.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 4, fields[0] == "MOSH", fields[1] == "CONNECT" else { continue }
            guard let port = Int(fields[2]), (1...65535).contains(port) else { continue }
            let key = String(fields[3])
            guard !key.isEmpty else { continue }
            return MoshHandover(host: host, port: port, key: key)
        }
        return nil
    }

    /// What may be shown to the user, or copied out of the error dialog, when
    /// the server said something we could not use.
    ///
    /// The handover line goes first, before anything else happens to the text,
    /// because it holds the session key. The one thing that must never be true
    /// is that a diagnostic somebody pastes into an issue carries it — and a
    /// failure that still managed to print a handover line is exactly the
    /// confusing case where somebody would paste the whole thing.
    static func redact(_ said: String) -> String {
        let lines = said.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[0] == "MOSH", fields[1] == "CONNECT", Int(fields[2]) != nil
            else { return String(line) }
            return "MOSH CONNECT \(fields[2]) <key withheld>"
        }
        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(detailLimit)
            .description
    }

    /// Enough of what the server said to diagnose it, not enough to fill a
    /// dialog.
    static let detailLimit = 2000

    /// The port range a host asks for, as `60001-60999` or a single port,
    /// turned into what `mosh-server` wants after `-p`. `nil` for anything we
    /// cannot make sense of, and then the server is left to its own default
    /// rather than handed nonsense.
    ///
    /// Deliberately forgiving about the separator, because this is typed by
    /// hand from a firewall rule and a person may well write a colon the way
    /// mosh does.
    static func portRange(_ asked: String?) -> String? {
        guard let text = asked?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }

        let parts = text
            .split(whereSeparator: { $0 == "-" || $0 == ":" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let from = Int(parts[0]) else { return nil }
        let to = parts.count == 1 ? from : Int(parts[1])
        guard let to else { return nil }
        guard (1...65535).contains(from), (1...65535).contains(to), to >= from else { return nil }

        return from == to ? "\(from)" : "\(from):\(to)"
    }
}
