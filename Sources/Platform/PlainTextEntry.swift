// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension View {

    /// Turns off every helpful thing iOS does to prose, for fields that hold no
    /// prose.
    ///
    /// Every text field in this app takes an identifier or a secret: hostnames,
    /// usernames, key labels, passphrases, directory paths, folder names. Not one
    /// of them is a sentence, and autocorrect treats them as if they were —
    /// capitalising a username, "fixing" a hostname, underlining a key label in
    /// red. It was reported from the simulator as spellcheck firing while typing
    /// host names, and it had been applied unevenly: nine of the sixteen fields
    /// had no protection at all, including every password and passphrase.
    ///
    /// Spell checking follows autocorrection rather than needing its own switch:
    /// UIKit's `spellCheckingType` defaults to `.default`, which means "whatever
    /// autocorrection does", so turning autocorrection off turns the red
    /// underlines off with it. SwiftUI exposes no separate modifier for it.
    ///
    /// Deliberately **not** paired with `textContentType(.password)`, which was
    /// briefly set here and made things worse.
    ///
    /// It cannot go further than that, though: the AutoFill "Passwords" key on
    /// the keyboard's shortcut bar belongs to every `SecureField` and iOS gives
    /// no supported way to refuse it. Measured, not assumed — with
    /// `.textContentType(.password)`, with it absent, and with an explicit
    /// `nil`, the accessibility tree reported the same shortcut bar every time:
    ///
    ///     ["SSHBorg", "Close", "shift", "go", "Connect", "Cancel", "Passwords"]
    ///
    /// The tricks that do remove it — claiming the field holds a one-time code,
    /// or dropping secure entry — trade a puzzling button for a wrong keyboard
    /// or a visible password. Not worth it. If it ever has to go, that is the
    /// menu, and this is the note saying the easy route was already tried.
    func plainTextEntry() -> some View {
        self
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}
