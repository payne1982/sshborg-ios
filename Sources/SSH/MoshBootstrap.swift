// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Starting a `mosh-server` on the far end, and reading the one line it answers
/// with.
///
/// SSH is only the ignition: it logs in, runs one command, reads one line, and
/// after that the terminal rides UDP. The SSH session itself is **not** closed,
/// which is where this parts company with the stock mosh client — it carries
/// SFTP, the port forwardings, the agent and the shell history, and all of that
/// keeps working because it stays.
///
/// Translated from Android's `SshManager.startMoshServer` and `MoshBootstrap`.
enum MoshBootstrap {

    /// What to run when a host has not named something else. The default is the
    /// program's own name, found on the login shell's PATH.
    static let defaultProgram = "mosh-server"

    /// How long the server waits for a client that has gone before giving up
    /// its shell.
    ///
    /// Deliberately far above mosh's own default, and for a reason Android met
    /// in Doze and we meet worse: iOS suspends the process within about thirty
    /// seconds of the app leaving the screen, and a session the user comes back
    /// to an hour later is exactly the case mosh exists for. The client gives up
    /// first, so this figure never decides when a session ends — only how long a
    /// server the client has already written off keeps a shell on the host.
    static let defaultNetworkTimeout = 3600

    /// Why a mosh session could not be started.
    ///
    /// Each case is separate because each has a different cure, and the user is
    /// told which: the switch is per host and explicit, so somebody who asked
    /// for mosh and did not get it is owed the reason rather than a silent fall
    /// back to SSH.
    struct Unavailable: Error, Equatable {
        enum Reason: Equatable {
            /// No `mosh-server` on the host. The cure is to install it, or to
            /// name the program if it is somewhere a non-interactive shell does
            /// not look.
            case notInstalled
            /// `mosh-server` refuses to run unless the server's locale is UTF-8,
            /// because the whole protocol synchronises a terminal whose contents
            /// it has to be able to interpret. The cure is on the server and
            /// nobody guesses it, which is why it is its own case.
            case localeNotUTF8
            /// It ran and said something we could not read. The detail carries
            /// what it said.
            case noConnectLine
            /// It started, and no datagram ever came back. Almost always
            /// inbound UDP blocked by a firewall: there is no error from the
            /// far end for that, only silence, which is why the only honest
            /// test is to send and wait — see
            /// ``MoshTerminalTransport/awaitFirstContact(timeout:)``.
            case noUDPAnswer
        }

        let reason: Reason
        /// What the server said, with any session key taken out of it. Shown
        /// only where it is the diagnosis.
        let detail: String?
    }

    /// The command, which is the whole of the bootstrap.
    ///
    /// Three things in it are not obvious:
    ///
    /// - **`env` rather than `VAR=value command`**, because that shell syntax is
    ///   not universal: fish has no such form, and a login shell is whatever the
    ///   user chose.
    /// - **`-s`**, which binds the server to the address the SSH connection
    ///   arrived on. That is also where the per-host address family comes from:
    ///   a session can only follow a device between networks that both have the
    ///   family it was born on.
    /// - **`-p` only when a host asked for it.** Left out, mosh picks from its
    ///   own range of a thousand ports, which is the default precisely because
    ///   nobody should have to care.
    static func command(
        networkTimeout: Int = defaultNetworkTimeout,
        program: String? = nil,
        ports: String? = nil
    ) -> String {
        let range = MoshHandover.portRange(ports).map { " -p \($0)" } ?? ""
        let runnable = program?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? defaultProgram
        return "env MOSH_SERVER_NETWORK_TMOUT=\(networkTimeout) \(runnable) new -s\(range) -c 256"
    }

    /// Runs it, and reads the handover.
    ///
    /// `host` is the address SSH actually dialled rather than the name the user
    /// typed, and carrying it through is the difference between talking to the
    /// machine we logged in to and resolving the name a second time and hoping
    /// to agree. `mosh-server -s` listens on one address of one family, and the
    /// handover line says nothing about which.
    static func start(
        on session: SSHSession,
        dialled host: String,
        networkTimeout: Int = defaultNetworkTimeout,
        program: String? = nil,
        ports: String? = nil,
        timeout: TimeInterval = 20
    ) async throws -> MoshHandover {
        let line = command(networkTimeout: networkTimeout, program: program, ports: ports)

        let answer = try await session.execute(line, timeout: timeout) { said in
            // The handover is the first thing it prints, and the channel will
            // not close while the daemon holds it.
            MoshHandover.parse(said, host: host) != nil
        }

        if let handover = MoshHandover.parse(answer.output, host: host) { return handover }

        throw Unavailable(
            reason: reason(for: answer.output, exitStatus: answer.exitStatus),
            detail: MoshHandover.redact(answer.output).nilIfEmpty
        )
    }

    /// Which of the three it was, read off what the shell said.
    ///
    /// 127 is what a shell reports for a command it could not find, and the
    /// message is worth matching too because some shells report it differently.
    static func reason(for said: String, exitStatus: Int32) -> Unavailable.Reason {
        let lowered = said.lowercased()
        if exitStatus == 127 || lowered.contains("not found") || lowered.contains("no such file") {
            return .notInstalled
        }
        if lowered.contains("utf-8") || lowered.contains("utf8") {
            return .localeNotUTF8
        }
        return .noConnectLine
    }
}
