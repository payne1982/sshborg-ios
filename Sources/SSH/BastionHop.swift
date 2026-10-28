// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one `ssh` line typed into a bastion's own terminal to reach the host
/// behind it.
///
/// It exists because mosh cannot be tunnelled. A jump hop is an SSH channel
/// inside the hop's own connection, and mosh has no channels at all: it carries
/// one terminal's screen state over UDP and nothing else. So when a host's
/// first hop is itself a mosh host, the session is made *to the bastion* over
/// mosh and the rest of the way is walked by the bastion's own ssh client.
///
/// That is not a consolation prize. The terminal then lives on a machine whose
/// network does not change, which is the arrangement mosh's own documentation
/// recommends over any attempt to jump: the phone's walk from Wi-Fi to a
/// carrier touches only the hop mosh protects, and the inward `ssh` is server
/// to server and never notices. On iOS it is worth more still, because the hop
/// it protects is also the one the system suspends.
///
/// The rest of the chain is handed over as `-J` rather than typed one hop at a
/// time. `ssh h1; ssh h2` does not nest — the `;` runs the second one back on
/// the bastion once the first has exited — and writing the lines ahead of one
/// another is a race against every prompt the hops raise, where a host-key
/// question or a password prompt eats the line that was already in flight. One
/// command, walked by a client that knows how to wait for its own prompts.
///
/// Translated from Android's `BastionHop` (`0ed9722`).
enum BastionHop {

    /// A machine on the composed command line.
    struct Endpoint: Equatable {
        let user: String
        let host: String
        let port: Int

        init(user: String, host: String, port: Int = BastionHop.defaultPort) {
            self.user = user
            self.host = host
            self.port = port
        }
    }

    /// The port that needs no `-p` and no `:suffix`.
    static let defaultPort = 22

    /// The command, or `nil` when a name on it would not survive the shell it is
    /// typed into.
    ///
    /// - Parameters:
    ///   - target: the host actually being reached — the row the person tapped.
    ///   - through: the hops after the bastion, in order; empty when the bastion
    ///     is the only one.
    static func compose(target: Endpoint, through: [Endpoint] = []) -> String? {
        guard isSafe(target), through.allSatisfy(isSafe) else { return nil }

        var line = "ssh"
        if !through.isEmpty {
            let chain = through.map { hop in
                let port = hop.port == defaultPort ? "" : ":\(hop.port)"
                return "\(hop.user)@\(bracketed(hop.host))\(port)"
            }
            line += " -J " + chain.joined(separator: ",")
        }
        if target.port != defaultPort { line += " -p \(target.port)" }
        line += " \(target.user)@\(target.host)"
        return line
    }

    /// An IPv6 literal inside `-J` needs its brackets: `user@2001:db8::1:2222`
    /// has no reading, and ssh's own answer to that is
    /// `user@[2001:db8::1]:2222`. The final target never takes a port suffix —
    /// it gets `-p` — so it is left exactly as it was typed.
    private static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// What may appear in a name that we put on somebody else's shell command
    /// line.
    ///
    /// The line is typed into an interactive shell on the bastion, so a name
    /// carrying a space, a quote or a `$` would stop being one argument.
    /// Everything a host name or a user name can legally hold is allowed here,
    /// brackets and `%` included for an IPv6 literal with a scope id; anything
    /// else means the line is not composed at all.
    ///
    /// Quoting every name would have worked too, and Android tried it first. It
    /// was dropped because this line is read by the person it is typed in front
    /// of — and edited by them, which is the other thing they do with it — and
    /// `ssh '…'@'…'` is not a line anyone wants to meet.
    private static func isSafe(_ endpoint: Endpoint) -> Bool {
        (1...65535).contains(endpoint.port)
            && isSafe(endpoint.user)
            && isSafe(endpoint.host)
    }

    private static func isSafe(_ name: String) -> Bool {
        // A name that begins with `-` is read by ssh as an option and not as a
        // name, which is a way onto the command line the character set does not
        // close by itself: `-oProxyCommand` is made only of characters a host
        // name may contain. Nothing legitimate starts with one.
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }

        return name.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || ".-_:[]%".contains(character)
        }
    }
}
