// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

/// A plain BSD socket, which is what libssh2 wants to be handed.
///
/// `Network.framework` would be the idiomatic choice on iOS, but libssh2 drives
/// the file descriptor itself through `send`/`recv`, so a POSIX socket is what
/// actually fits. Connecting is done non-blocking so the attempt can time out,
/// then the descriptor is switched back to blocking for libssh2 to use.
enum SSHSocket {

    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
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

        // Try every resolved address: a host with a broken IPv6 route should
        // still connect over IPv4.
        var candidate: UnsafeMutablePointer<addrinfo>? = results
        while let address = candidate {
            defer { candidate = address.pointee.ai_next }

            do {
                return try connect(to: address.pointee, timeout: timeout)
            } catch let error as SSHError {
                if case .connectionFailed(let detail) = error { lastError = detail }
                if case .timedOut = error { throw error }
            }
        }

        throw SSHError.connectionFailed(lastError)
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
