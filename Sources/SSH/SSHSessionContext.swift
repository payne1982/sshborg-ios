// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// What libssh2's per-session "abstract" pointer points at.
///
/// libssh2 gives a session exactly one `void *` for the application, and every C
/// callback reaches its Swift side through it. Two features want it: the jump
/// host tunnel replaces the socket send/recv callbacks, and agent forwarding
/// takes the auth-agent channel. Whichever wrote to it last would win, and a
/// host configured with both a jump host and agent forwarding would break in a
/// way no single-feature test could catch. So there is one context per session
/// holding both, created before the handshake and released after
/// `libssh2_session_free`.
///
/// Only ever touched on the owning session's queue.
final class SSHSessionContext {

    /// The outer session's `direct-tcpip` channel, when this session is
    /// tunnelled. Set by ``SSHTunnel``.
    var tunnelChannel: OpaquePointer?

    /// Handles the auth-agent channels the server opens back to us. Set by
    /// ``AgentForwarder``, and unowned in the C sense: the forwarder is retained
    /// by the session, not by this.
    weak var agentForwarder: AgentForwarder?

    /// The password to answer a keyboard-interactive prompt with.
    ///
    /// Held only for the duration of authentication and cleared immediately
    /// after: the C callback that needs it cannot take a Swift closure, so the
    /// value has to be reachable from the abstract pointer, and there is no
    /// reason for it to outlive the exchange.
    var keyboardInteractivePassword: String?

    /// Creates a context and stores it in `session`'s abstract pointer.
    ///
    /// The returned `Unmanaged` is the owning reference: the caller must call
    /// `release()` on it once the session has been freed, and not before — a
    /// callback can fire at any point up to that.
    static func attach(to session: OpaquePointer) -> Unmanaged<SSHSessionContext> {
        let context = SSHSessionContext()
        let retained = Unmanaged.passRetained(context)

        if let abstract = libssh2_session_abstract(session) {
            abstract.pointee = retained.toOpaque()
        }
        return retained
    }

    /// Recovers the context inside a C callback.
    static func from(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> SSHSessionContext? {
        guard let pointer = abstract?.pointee else { return nil }
        return Unmanaged<SSHSessionContext>.fromOpaque(pointer).takeUnretainedValue()
    }
}
