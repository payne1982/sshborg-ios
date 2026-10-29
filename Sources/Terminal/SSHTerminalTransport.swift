// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The terminal's bytes over SSH: the shell channel the app has always used,
/// behind the seam.
///
/// There is almost nothing here, and that is the measure of how narrow the seam
/// is. The channel already does the work — it pumps libssh2 on its own queue,
/// buffers a write libssh2 would not take, and finishes its stream when the
/// shell goes — so this reads that stream, hands each run of bytes to the sink,
/// and at the end says which of the two things happened.
///
/// ### What tells a goodbye from a death
///
/// Whether an exit status arrived, and not what it was. A shell that exited of
/// its own accord has one; a dropped link has none. `exit` with no argument
/// carries the status of the last command, so any failed command before leaving
/// produces a non-zero value that describes the shell's last act and not the
/// connection — which is why the number is never shown. Android draws the line
/// in the same place: `if (session.exitStatus != -1) cleanExit = true`.
///
/// ⚠️ A shell that is *killed* counts as a clean exit. SSH does distinguish the
/// two — `exit-signal` rather than `exit-status` — but libssh2 reports 0 for a
/// signalled shell and for a genuine exit 0 alike. Reading the signal was tried
/// on 14/08/2026 and removed the same day: it worked in a test that killed the
/// shell from inside and made no difference to killing it from another session,
/// which was the case that prompted it. Deliberate, and the user's call.
final class SSHTerminalTransport: TerminalTransport, @unchecked Sendable {

    /// `@unchecked Sendable` is accurate rather than a shortcut: the channel
    /// serialises everything on a queue of its own, which is what already lets
    /// a keystroke be sent from the main thread while the pump reads, and the
    /// two properties here are written once before the loop starts.
    private let channel: SSHShellChannel
    private let apply: TerminalSink

    init(channel: SSHShellChannel, apply: @escaping TerminalSink) {
        self.channel = channel
        self.apply = apply
    }

    var isConnected: Bool { channel.exitStatus == nil && channel.finishReason == nil }

    func write(_ data: Data) {
        channel.send(data)
    }

    func resize(columns: Int, rows: Int) {
        channel.resize(columns: columns, rows: rows)
    }

    func run() async -> TerminalEnd {
        for await chunk in channel.output {
            // A reader that has been cancelled must not feed what arrives: the
            // tab is being torn down, and whoever started this loop stopped
            // caring before this chunk existed.
            if Task.isCancelled { return .cleanExit }
            await MainActor.run { apply(chunk) }
        }

        guard channel.exitStatus == nil else { return .cleanExit }
        // The detail is the channel's own word for how its stream ended — "eof",
        // a read error, "closed by caller". Nothing shows it today; it is here
        // because the field exists for exactly this and the alternative is
        // throwing away the one diagnostic the channel already keeps.
        return .lost(summary: nil, detail: channel.finishReason)
    }

    func close() {
        channel.close()
    }
}
