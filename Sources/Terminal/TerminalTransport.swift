// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a terminal's bytes come from.
///
/// The terminal above this — the emulator, the view, the scrollback, the
/// selection, the extra-key bar, the suggestions, the touch handling — must not
/// learn which transport it has. That is not tidiness: all of it has been
/// settled by use and by bug reports, and a transport has no business touching
/// any of it. The seam is this narrow because the bytes only ever crossed in
/// three places to begin with — the read loop, the write of a keystroke (or of
/// the emulator's own answer to a device query), and a resize.
///
/// Implementations: ``SSHTerminalTransport``, which is the shell channel the app
/// has always used, and ``MoshTerminalTransport``, which runs a UDP state
/// machine instead.
///
/// ### Two differences from Android's interface of the same name
///
/// The output is a **push** and not a blocking read. Android hands `read` a
/// callback and keeps the loop's bytes somewhere else while no screen is
/// reading, because its ViewModel is destroyed and rebuilt by a mere switch
/// between sibling tabs. Here the emulator belongs to ``TerminalSession``,
/// which lives as long as the tab does, so there is one sink, it is given at
/// construction, and it is valid from the first byte to the last. That also
/// removes the question Android had to answer about which of two sinks a frame
/// belongs to.
///
/// And there is no `survivesUnattended`. Over there it distinguishes a session
/// that keeps itself alive with a heartbeat from one TCP holds for it, because a
/// foreground service keeps the process either way. iOS suspends the whole app
/// within about thirty seconds of leaving the screen, so the distinction has no
/// reader here: what matters on this side is what survives coming *back*, which
/// is the session's business and not the transport's contract.
protocol TerminalTransport: AnyObject {

    /// False once the far end has gone, as far as this transport can tell
    /// without asking.
    var isConnected: Bool { get }

    /// Keystrokes, and the emulator's own answers to device queries.
    func write(_ data: Data)

    func resize(columns: Int, rows: Int)

    /// Runs until the session ends, pushing host bytes at the sink it was built
    /// with, and says how it ended.
    func run() async -> TerminalEnd

    /// Whether the screen is synchronised from the far side rather than streamed
    /// to us.
    ///
    /// False for SSH, where the bytes are the remote program's own output
    /// appended at the cursor. The client may then write into its own terminal
    /// as well, and does: the first screenful is kept clear of the retracting
    /// title bar by line feeds of our own, put in before the first byte arrives.
    ///
    /// True for mosh, where the far end keeps the terminal and sends what it
    /// *looks like*, as differences against the screen it believes we hold.
    /// Anything we write into the emulator ourselves makes that belief false,
    /// and from then on every frame is computed against a screen we do not
    /// have — observed on Android as the typed line jumping back to the top of
    /// the window after a few words, which is the server positioning the cursor
    /// for its own layout while theirs sat three rows lower.
    ///
    /// So this is not a label for "is it mosh". It is the one fact the layers
    /// above need, and each takes from it only what it needs.
    var screenIsSynchronised: Bool { get }

    /// Whole seconds since the far end was last heard from, 0 while in contact —
    /// or nil for a transport that cannot tell.
    ///
    /// SSH cannot tell, and that is not an oversight in this protocol: TCP
    /// acknowledges and retransmits below us, so silence on an SSH session is
    /// indistinguishable from a server with nothing to say. A protocol that
    /// keeps its own session alive with a heartbeat knows exactly, and owes the
    /// screen the number — a terminal that cannot be reached is otherwise a
    /// photograph with nothing to explain it.
    var outOfContactSeconds: AsyncStream<Int>? { get }

    /// Closes whatever this transport owns. Never the SSH session, which
    /// outlives it: under mosh that session is still carrying SFTP, the port
    /// forwardings and the agent, and it is the one that started the server.
    func close()
}

extension TerminalTransport {
    var screenIsSynchronised: Bool { false }
    var outOfContactSeconds: AsyncStream<Int>? { nil }
    func close() {}
}

/// Why a session ended.
enum TerminalEnd: Equatable {

    /// The remote program exited of its own accord: the screen may close itself.
    case cleanExit

    /// - Parameters:
    ///   - summary: the short line shown under the title, or nil to let the
    ///     caller word it — only the caller can reach the string resources.
    ///   - detail: the full technical cause for the expandable, copyable
    ///     section, or nil.
    case lost(summary: String?, detail: String?)
}
