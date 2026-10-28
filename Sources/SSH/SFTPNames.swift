// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one rule about names that come from the other end of an SFTP connection.
///
/// A listing is the server's answer to "what is in this directory", and every
/// name in that answer is used as a name: appended to a remote path, shown in
/// the browser, and — on the way back — handed to the filesystem on the phone
/// as the file to write and, for a recursive download, as the folder to make.
/// Nothing downstream of the listing asks whether it really is one, and
/// ``TransferManager``'s `uniqueRemoteName` only makes a name unique rather
/// than making it a name.
///
/// No Unix filesystem can hold an entry called `..`, or one with a `/` inside
/// it: those characters are not available to a directory entry, which is
/// precisely why a path arriving as a name means something has gone wrong or is
/// being tried on. So refusing it costs nothing a real server can offer, and
/// the alternative is a name deciding where a download lands —
/// `documents.appendingPathComponent("../../elsewhere")` resolves, and the file
/// goes there.
///
/// It lives in its own file because it is a trust boundary rather than a detail
/// of listing, and because a boundary with no test is a boundary nobody
/// checked: a hostile SFTP server is the one thing that cannot be arranged by
/// hand on a phone. Translated from Android's `SftpNames` (`fa059a1`), which
/// found it.
enum SFTPNames {

    /// Whether `name` is a single name, and therefore usable as one.
    static func isPlain(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }
}
