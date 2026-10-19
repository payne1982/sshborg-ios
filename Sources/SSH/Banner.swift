// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The message a server sends before it lets anyone in.
///
/// A banner is a greeting as often as it is a legal notice, and either way it is
/// worth nothing after the fact: it has to be readable *before* anything is
/// typed. Getting it there is ``SSHAuth/deferred``; this is only the tidying up
/// on the way.
enum Banner {

    /// A banner as it can be put on a screen, or nil when there is nothing to
    /// show.
    ///
    /// Line endings first: a banner travels with CR LF, and left alone every
    /// line of it would be followed by a blank one. Trailing blank lines go —
    /// most banners end with one — while blank lines *inside* stay, because a
    /// banner is usually laid out on purpose. Nothing else is touched: the box
    /// shows what the server drew, spaces and frames included.
    ///
    /// Android's `SshManager.appendBanner` does the same, plus a join: JSch
    /// hands it one banner per server in a chain, while here a connection stops
    /// at the first server that asks and carries only that one's.
    static func readable(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = String(text.reversed().drop(while: { $0.isWhitespace || $0.isNewline }).reversed())

        return trimmed.isEmpty ? nil : trimmed
    }
}
