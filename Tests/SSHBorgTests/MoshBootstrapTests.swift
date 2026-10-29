// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The command, which is the whole of the bootstrap, and the reading of what
/// came back when it was not a handover.
///
/// Pure: the command is a string and the classification is a function, so both
/// are checked here rather than against a server. What needs a server is that
/// the command *works*, and that is `SSHIntegrationTests`.
final class MoshBootstrapTests: XCTestCase {

    func testTheDefaultCommandIsTheOneAndroidSends() {
        XCTAssertEqual(
            MoshBootstrap.command(networkTimeout: 3600),
            "env MOSH_SERVER_NETWORK_TMOUT=3600 mosh-server new -s -c 256"
        )
    }

    /// `env` rather than `VAR=value command`, because that shell syntax is not
    /// universal — fish has no such form, and a login shell is whatever the user
    /// chose.
    func testTheEnvironmentIsSetWithEnvAndNotWithShellSyntax() {
        let command = MoshBootstrap.command()

        XCTAssertTrue(command.hasPrefix("env MOSH_SERVER_NETWORK_TMOUT="))
        XCTAssertFalse(command.contains("TMOUT=3600 MOSH"), "two variables would need a shell")
    }

    /// A host that keeps the program somewhere a non-interactive shell does not
    /// look. Without this the case reports itself as "mosh is not installed",
    /// which is a false diagnosis with nothing the person can do about it.
    func testAHostMayNameTheProgram() {
        XCTAssertEqual(
            MoshBootstrap.command(networkTimeout: 60, program: "/opt/mosh/bin/mosh-server"),
            "env MOSH_SERVER_NETWORK_TMOUT=60 /opt/mosh/bin/mosh-server new -s -c 256"
        )
        // Nothing, or whitespace, is not a program name.
        XCTAssertTrue(MoshBootstrap.command(program: "   ").contains("mosh-server new"))
        XCTAssertTrue(MoshBootstrap.command(program: nil).contains("mosh-server new"))
    }

    /// `-p` only when a host asked for it: left out, mosh picks from its own
    /// range of a thousand ports, which is the default precisely because nobody
    /// should have to care.
    func testThePortRangeIsPassedOnlyWhenAHostNarrowedIt() {
        XCTAssertFalse(MoshBootstrap.command(ports: nil).contains(" -p "))
        XCTAssertFalse(MoshBootstrap.command(ports: "nonsense").contains(" -p "))

        XCTAssertEqual(
            MoshBootstrap.command(networkTimeout: 30, ports: "60001-60999"),
            "env MOSH_SERVER_NETWORK_TMOUT=30 mosh-server new -s -p 60001:60999 -c 256"
        )
        XCTAssertEqual(
            MoshBootstrap.command(networkTimeout: 30, ports: "60001"),
            "env MOSH_SERVER_NETWORK_TMOUT=30 mosh-server new -s -p 60001 -c 256"
        )
    }

    /// The server is told an hour by default, and it is deliberate: the client
    /// gives up first, so this never decides when a session ends — only how long
    /// a server the client has written off keeps a shell. On iOS the app is
    /// suspended within half a minute of leaving the screen, so a session
    /// somebody comes back to is the ordinary case rather than the exception.
    func testTheServerIsToldToWaitAnHour() {
        XCTAssertEqual(MoshBootstrap.defaultNetworkTimeout, 3600)
        XCTAssertTrue(MoshBootstrap.command().contains("TMOUT=3600"))
    }

    // MARK: - Reading a failure

    func testAShellThatCouldNotFindItSaysSoClearly() {
        XCTAssertEqual(
            MoshBootstrap.reason(for: "bash: mosh-server: command not found", exitStatus: 127),
            .notInstalled
        )
        // Some shells report it their own way, so the status alone is enough.
        XCTAssertEqual(MoshBootstrap.reason(for: "", exitStatus: 127), .notInstalled)
        XCTAssertEqual(
            MoshBootstrap.reason(for: "/bin/sh: 1: mosh-server: not found", exitStatus: 1),
            .notInstalled
        )
    }

    /// Its own case because the cure is on the server and nobody guesses it:
    /// mosh refuses to run outside a UTF-8 locale, since the whole protocol
    /// synchronises a terminal whose contents it has to interpret.
    func testALocaleThatIsNotUTF8IsItsOwnDiagnosis() {
        XCTAssertEqual(
            MoshBootstrap.reason(
                for: "mosh-server needs a UTF-8 native locale to run", exitStatus: 1
            ),
            .localeNotUTF8
        )
    }

    func testAnythingElseIsSaidToBeUnreadableRatherThanGuessedAt() {
        XCTAssertEqual(MoshBootstrap.reason(for: "something odd happened", exitStatus: 1), .noConnectLine)
        XCTAssertEqual(MoshBootstrap.reason(for: "", exitStatus: 0), .noConnectLine)
    }

    // MARK: - The program a host asks for

    /// The field arrives in a backup as well as from the form, and the line it
    /// goes into is typed into somebody's shell. A plain name or path is kept;
    /// anything a shell would read as more than one word means `mosh-server`.
    func testOnlyAPlainProgramReachesTheShell() {
        for plain in ["mosh-server", "/usr/local/bin/mosh-server", "~/bin/mosh-server",
                      "./mosh-server", "mosh-server-1.4", "c++-built/mosh_server"] {
            XCTAssertEqual(MoshBootstrap.serverProgram(plain), plain, "\(plain) was refused")
        }
        for hostile in ["mosh-server; touch /tmp/x; #", "$(id)", "`id`", "mosh-server && reboot",
                        "mosh server", "mosh-server|tee x", "a\nb", "mosh-server>x", "\"quoted\"",
                        "-oProxyCommand=evil", "--help"] {
            XCTAssertNil(MoshBootstrap.serverProgram(hostile), "\(hostile) was let through")
        }
        XCTAssertNil(MoshBootstrap.serverProgram(nil))
        XCTAssertNil(MoshBootstrap.serverProgram("   "))
        XCTAssertEqual(MoshBootstrap.serverProgram("  mosh-server  "), "mosh-server")
    }

    /// And a refused one falls back to `mosh-server` rather than failing the
    /// session: the command is whole, and nothing of the hostile text is in it.
    func testARefusedProgramFallsBackToTheDefault() {
        let line = MoshBootstrap.command(program: "mosh-server; touch /tmp/sshborg-marker; #")
        XCTAssertFalse(line.contains("touch"), line)
        XCTAssertFalse(line.contains(";"), line)
        XCTAssertTrue(line.contains(" mosh-server new -s"), line)
    }
}
