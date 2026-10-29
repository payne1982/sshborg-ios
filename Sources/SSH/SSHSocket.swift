// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// A plain BSD socket, which is what libssh2 wants to be handed.
///
/// `Network.framework` would be the idiomatic choice on iOS, but libssh2 drives
/// the file descriptor itself through `send`/`recv`, so a POSIX socket is what
/// actually fits. Connecting is done non-blocking so the attempt can time out,
/// then the descriptor is switched back to blocking for libssh2 to use.
enum SSHSocket {

    /// Which address family to try first when a name resolves to both.
    ///
    /// A preference and never a filter: a host that only has one of the two must
    /// still connect, so the other family is tried after, not instead.
    ///
    /// It exists for mosh, and only a mosh host is given one. A mosh session is
    /// bound to the family it was born on — `mosh-server -s` listens on the one
    /// address the SSH connection arrived on — so a host that resolves to both
    /// can have its UDP carried on one and dropped on the other, and nothing
    /// about the SSH half would say so. Android grew the same per-host setting
    /// for the same reason.
    enum AddressPreference: String {
        case auto
        case ipv4
        case ipv6

        /// Anything unexpected in the column means no preference, which is the
        /// behaviour a database written by an older version has to keep.
        init(column: String?) {
            self = AddressPreference(rawValue: column ?? "") ?? .auto
        }
    }

    static func connect(
        host: String,
        port: Int,
        timeout: TimeInterval,
        preferring preference: AddressPreference = .auto
    ) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC // IPv4 or IPv6, whichever resolves
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let results else {
            let reason = String(cString: gai_strerror(status))
            throw SSHError.connectionFailed("\(host): \(reason)")
        }
        defer { freeaddrinfo(results) }

        var lastError = "no address returned for \(host)"

        var candidates: [addrinfo] = []
        var candidate: UnsafeMutablePointer<addrinfo>? = results
        while let address = candidate {
            candidates.append(address.pointee)
            candidate = address.pointee.ai_next
        }

        // Try every resolved address, in the order the preference asks for: a
        // host with a broken IPv6 route should still connect over IPv4.
        for index in attemptOrder(of: candidates.map(\.ai_family), preferring: preference) {
            do {
                return try connect(to: candidates[index], timeout: timeout)
            } catch let error as SSHError {
                if case .connectionFailed(let detail) = error { lastError = detail }
                if case .timedOut = error { throw error }
            }
        }

        throw SSHError.connectionFailed(lastError)
    }

    /// The order to try resolved addresses in: the preferred family first, each
    /// group keeping the order the resolver gave it, and nothing dropped.
    ///
    /// Pure, and separate from the connecting, because it is the whole of what
    /// the per-host setting does and the alternative is a test that needs a name
    /// with both families behind it.
    static func attemptOrder(of families: [Int32], preferring preference: AddressPreference) -> [Int] {
        let wanted: Int32
        switch preference {
        case .auto: return Array(families.indices)
        case .ipv4: wanted = AF_INET
        case .ipv6: wanted = AF_INET6
        }

        let indices = Array(families.indices)
        return indices.filter { families[$0] == wanted } + indices.filter { families[$0] != wanted }
    }

    /// The address this descriptor is actually connected to, numerically.
    ///
    /// Mosh is why it exists. `mosh-server -s` listens on the one address the
    /// SSH connection arrived on, and the handover line says nothing about
    /// which — so resolving the name a second time to find the server is a
    /// guess, and the lab measured the way it fails: a name that resolves to
    /// IPv6 first while the server had bound IPv4, which looks exactly like a
    /// blocked port. The cure is to talk to the address we are already talking
    /// to.
    ///
    /// nil for anything that is not an internet socket, which includes the
    /// socket pair a tunnelled session is driven through.
    static func peerAddress(of descriptor: Int32) -> String? {
        var peer = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let asked = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &length)
            }
        }
        guard asked == 0, peer.ss_family == AF_INET || peer.ss_family == AF_INET6 else {
            return nil
        }

        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard named == 0 else { return nil }
        return String(cString: name)
    }

    private static func connect(to address: addrinfo, timeout: TimeInterval) throws -> Int32 {
        let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard descriptor >= 0 else {
            throw SSHError.connectionFailed(String(cString: strerror(errno)))
        }

        var succeeded = false
        defer { if !succeeded { close(descriptor) } }

        // Do not let a dead peer raise SIGPIPE and kill the app.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Interactive typing must not wait for Nagle's algorithm.
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        try setBlocking(descriptor, false)

        let result = Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen)
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw SSHError.connectionFailed(String(cString: strerror(errno)))
            }
            try waitUntilWritable(descriptor, timeout: timeout)

            // A completed poll does not mean the connection succeeded; the error
            // is only visible through SO_ERROR.
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                throw SSHError.connectionFailed(String(cString: strerror(socketError)))
            }
        }

        try setBlocking(descriptor, true)
        succeeded = true
        return descriptor
    }

    private static func waitUntilWritable(_ descriptor: Int32, timeout: TimeInterval) throws {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SSHError.timedOut }

            let ready = poll(&descriptorSet, 1, Int32(remaining * 1000))
            if ready > 0 { return }
            if ready == 0 { throw SSHError.timedOut }
            // A signal interrupted the wait; poll again on what is left.
            guard errno == EINTR else {
                throw SSHError.connectionFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func setBlocking(_ descriptor: Int32, _ blocking: Bool) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else {
            throw SSHError.connectionFailed(String(cString: strerror(errno)))
        }

        let updated = blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK)
        guard fcntl(descriptor, F_SETFL, updated) >= 0 else {
            throw SSHError.connectionFailed(String(cString: strerror(errno)))
        }
    }
}
