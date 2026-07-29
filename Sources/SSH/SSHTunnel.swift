// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Darwin
import Foundation

/// Carries one SSH session inside a `direct-tcpip` channel of another, which is
/// what a jump host is.
///
/// libssh2 lets a session's socket reads and writes be replaced wholesale, so
/// the inner session never learns it is not talking to a socket: its bytes go
/// into the outer session's channel and come back out the same way. This is the
/// same shape as `JumpProxy` in the Android `SshManager`, where JSch's `Proxy`
/// interface does the equivalent job.
///
/// Two rules make it work, and breaking either one deadlocks the connection:
///
/// 1. The **outer** session is switched to non-blocking. Its reads happen inside
///    the inner session's callbacks, and a blocking read there would stop the
///    only thread that could ever supply the data.
/// 2. The **inner** session stays blocking and is handed the real outermost
///    socket. When it has nothing to read it waits on that descriptor, which is
///    correct: tunnelled data can only arrive when the real socket has traffic.
final class SSHTunnel {

    /// Held so the chain below this hop cannot be freed while it is in use.
    private let outer: SSHSession
    private let channel: OpaquePointer

    /// The real socket at the bottom of the chain, which every session in it
    /// waits on.
    let realSocket: Int32

    private init(outer: SSHSession, channel: OpaquePointer, realSocket: Int32) {
        self.outer = outer
        self.channel = channel
        self.realSocket = realSocket
    }

    /// Opens a tunnel from `session` towards `host:port`.
    ///
    /// Must be called on the session's queue.
    static func open(
        through session: SSHSession,
        raw: OpaquePointer,
        to host: String,
        port: Int,
        realSocket: Int32
    ) throws -> SSHTunnel {
        // The originator address is informational; OpenSSH logs it and does not
        // check it. Loopback is what every client sends.
        guard let channel = host.withCString({ target in
            "127.0.0.1".withCString { origin in
                libssh2_channel_direct_tcpip_ex(raw, target, Int32(port), origin, 22)
            }
        }) else {
            throw SSHError.fromSession(raw, fallback: "the jump host refused to open a tunnel to \(host):\(port)")
        }

        // From here the outer session is only ever driven from inside the inner
        // session's callbacks, so it must never block.
        libssh2_session_set_blocking(raw, 0)

        return SSHTunnel(outer: session, channel: channel, realSocket: realSocket)
    }

    /// Points a freshly created session's socket operations at this tunnel.
    ///
    /// `context` is the inner session's, already installed in its abstract
    /// pointer by ``SSHSession``; the callbacks below find the channel through
    /// it. It is shared with agent forwarding, so this sets one field and
    /// leaves the rest alone.
    func attach(to innerSession: OpaquePointer, context: SSHSessionContext) {
        context.tunnelChannel = channel

        libssh2_session_callback_set2(
            innerSession,
            LIBSSH2_CALLBACK_SEND,
            unsafeBitCast(tunnelSend, to: (@convention(c) () -> Void).self)
        )
        libssh2_session_callback_set2(
            innerSession,
            LIBSSH2_CALLBACK_RECV,
            unsafeBitCast(tunnelReceive, to: (@convention(c) () -> Void).self)
        )
    }

    /// Must be called on the queue, and only once nothing is using the tunnel.
    func close() {
        libssh2_channel_close(channel)
        libssh2_channel_free(channel)
        outer.disconnect()
    }
}

/// Returned to libssh2 when the tunnel has nothing right now. libssh2 treats a
/// negative `EAGAIN` as "would block" and waits on the socket before retrying.
private let wouldBlock = -Int(EAGAIN)

/// The tunnel channel a callback should work on, or `nil` if the session is not
/// tunnelled — in which case libssh2 should never have called us at all.
private func tunnelChannel(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> OpaquePointer? {
    SSHSessionContext.from(abstract)?.tunnelChannel
}

private let tunnelSend: @convention(c) (
    libssh2_socket_t, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buffer, length, _, abstract in
    guard let channel = tunnelChannel(from: abstract), let buffer, length > 0 else { return wouldBlock }

    let written = libssh2_channel_write_ex(
        channel,
        0,
        buffer.assumingMemoryBound(to: CChar.self),
        length
    )

    if written == Int(LIBSSH2_ERROR_EAGAIN) { return wouldBlock }
    // Anything else negative is a dead tunnel; report it as a closed socket so
    // the inner session gives up rather than spinning.
    return written < 0 ? -Int(ECONNRESET) : written
}

private let tunnelReceive: @convention(c) (
    libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buffer, length, _, abstract in
    guard let channel = tunnelChannel(from: abstract), let buffer, length > 0 else { return wouldBlock }

    let read = libssh2_channel_read_ex(
        channel,
        0,
        buffer.assumingMemoryBound(to: CChar.self),
        length
    )

    if read == Int(LIBSSH2_ERROR_EAGAIN) { return wouldBlock }
    if read == 0 {
        // Zero from a channel means EOF, not "try again". Reporting it as a
        // would-block would hang the inner session forever.
        return libssh2_channel_eof(channel) == 1 ? 0 : wouldBlock
    }
    return read < 0 ? -Int(ECONNRESET) : read
}
