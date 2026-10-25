// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the user has done, as the state the client synchronises upward.
///
/// Our side of the protocol is a growing list of actions, and a "state" is
/// simply how many of them had happened — so the diff between two states is the
/// actions in between, and the state number the server acknowledges tells us
/// which ones it has. That is all the state a client needs; the expensive half
/// of mosh, keeping a terminal and computing screen diffs, is the server's job.
///
/// Runs of typing are joined into one keystroke instruction on the way out. The
/// server feeds the bytes to the pty in order, so a hundred separate
/// instructions and one instruction of a hundred bytes mean the same thing, and
/// the second is smaller.
final class MoshUserStream {

    private var actions: [MoshDiffs.UserAction] = []
    private var dropped: UInt64 = 0

    /// How many actions have happened in all, including the ones already
    /// acknowledged and freed.
    var count: UInt64 { dropped + UInt64(actions.count) }

    func type(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        actions.append(.keystrokes(bytes))
    }

    func resize(width: Int, height: Int) {
        actions.append(.resize(width: width, height: height))
    }

    /// The diff that takes the far end from `from` actions to everything we
    /// have.
    func diff(from: UInt64) throws -> Data {
        guard from >= dropped else { throw MoshProtocolError.actionsAlreadyFreed(from: from, freed: dropped) }
        guard from <= count else { throw MoshProtocolError.noSuchAction(from: from, count: count) }
        guard from < count else { return Data() }

        let start = Int(from - dropped)
        return MoshDiffs.encodeUserDiff(coalesce(Array(actions[start...])))
    }

    /// Frees everything the far end has acknowledged; the numbering carries on
    /// regardless, which is what makes a state number mean one thing for the
    /// life of the session.
    func dropThrough(_ upTo: UInt64) {
        guard upTo > dropped else { return }
        let removable = min(Int(upTo - dropped), actions.count)
        guard removable > 0 else { return }
        actions.removeFirst(removable)
        dropped += UInt64(removable)
    }

    /// Joins consecutive typing into one action, leaving a resize where it is:
    /// the order matters, because a resize in the middle of a burst changes how
    /// the far end lays out what follows it.
    private func coalesce(_ window: [MoshDiffs.UserAction]) -> [MoshDiffs.UserAction] {
        var out: [MoshDiffs.UserAction] = []
        var pending = Data()

        func flush() {
            guard !pending.isEmpty else { return }
            out.append(.keystrokes(pending))
            pending = Data()
        }

        for action in window {
            switch action {
            case .keystrokes(let keys):
                pending.append(keys)
            case .resize:
                flush()
                out.append(action)
            }
        }
        flush()
        return out
    }
}
