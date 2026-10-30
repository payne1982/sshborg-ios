// SPDX-License-Identifier: GPL-3.0-or-later

import CSSH2
import Foundation

/// A live interactive shell with a PTY attached, the counterpart of the Android
/// `ShellSession`.
///
/// Output is delivered as an `AsyncStream<Data>`, which is what the terminal
/// view consumes in phase 3. Every libssh2 call happens on the owning session's
/// serial queue.
///
/// The channel is set up while the session is still in blocking mode — that
/// keeps `open`, `request pty` and `shell` free of `EAGAIN` retry loops — and the
/// session is then switched to non-blocking for the interactive phase.
///
/// Reads are driven by a self-rescheduling pump rather than by a dispatch source
/// on the socket. A dispatch source would mean the file descriptor has to
/// outlive the source, which is exactly the kind of lifetime coupling that turns
/// a disconnect into a use-after-close. Polling costs little here because iOS
/// suspends the app in the background anyway, so this loop only ever runs while
/// the terminal is on screen, and it backs off to a quarter of a second when the
/// remote goes quiet. Typing latency is unaffected: writes do not wait for the
/// pump.
final class SSHShellChannel {

    /// Everything the remote writes. Finishes when the shell exits or the
    /// connection drops.
    let output: Output

    /// The output, counted as it is taken: what has been read from the channel
    /// and not yet taken by the terminal is a ``ByteBacklog``, and the pump stops
    /// reading while there is too much of it.
    ///
    /// The stream it wraps is unbounded, and a terminal slower than the network
    /// — a `cat` of a large file on a fast link, with SwiftTerm parsing on the
    /// main thread — kept everything the far end sent. An audit on 30/10/2026
    /// proposed ending the session past a budget; not reading is better, because
    /// SSH has flow control: the channel's window fills, and the server stops
    /// sending until there is room. Nothing is lost and nothing is closed.
    struct Output: AsyncSequence {
        typealias Element = Data

        fileprivate let stream: AsyncStream<Data>
        fileprivate let backlog: ByteBacklog

        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var base: AsyncStream<Data>.AsyncIterator
            fileprivate let backlog: ByteBacklog

            mutating func next() async -> Data? {
                guard let chunk = await base.next() else { return nil }
                backlog.taken(chunk.count)
                return chunk
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), backlog: backlog)
        }
    }

    private let backlog = ByteBacklog()

    /// Read and not yet taken from ``output``. For a test: the limit on it is
    /// the whole of the backpressure, and nothing else shows it working.
    var waitingOutput: Int { backlog.waiting }

    private let queue: DispatchQueue
    private let session: OpaquePointer

    /// The session this channel belongs to, so a channel dropped without being
    /// closed can be freed safely — and only while that session is still there.
    /// Strong: the session's own reference back is weak, so there is no cycle,
    /// and the session must outlive this object's `deinit`.
    private let owner: SSHSession?
    private var channel: OpaquePointer?
    private let continuation: AsyncStream<Data>.Continuation

    /// Bytes a write could not hand to libssh2 yet, retried by the pump.
    private var pendingWrite = Data()

    private var idleDelay: TimeInterval = Pump.minimumDelay
    private var isPumping = false

    private(set) var exitStatus: Int32?


    /// Why the output stream ended. A shell that stops is indistinguishable from
    /// one that never had anything to say, so the reason is recorded rather than
    /// inferred. Read after the stream finishes.
    private(set) var finishReason: String?

    private enum Pump {
        /// Delay after a read that produced nothing.
        static let minimumDelay: TimeInterval = 0.02
        /// Ceiling reached once the remote has been quiet for a while.
        static let maximumDelay: TimeInterval = 0.25
        /// How quickly the delay grows while nothing arrives.
        static let backoffFactor: Double = 1.6
    }

    /// libssh2's own defaults, restated because they come from function-like
    /// macros, which Swift does not import.
    private enum Defaults {
        static let windowSize: UInt32 = 2 * 1024 * 1024
        static let packetSize: UInt32 = 32_768
        /// Pixel geometry reported to the PTY. The Android app uses the same
        /// 8×16 cell approximation.
        static let cellWidth = 8
        static let cellHeight = 16
        static let readBufferSize = 32 * 1024
        /// How much may wait for the terminal before reading stops. Twice the
        /// window: the server can have that much more in flight anyway.
        static let backlogLimit = 4 * 1024 * 1024
        /// And in pieces, for a far end that sends a byte at a time: each one is
        /// a `Data` and a node in the stream, worth far more than its byte. A
        /// full read is 32 KB, so this is never what stops a fast one.
        static let backlogEntries = 1024
    }

    /// Must be called on the session queue, with the session still blocking.
    init(
        session: OpaquePointer,
        queue: DispatchQueue,
        owner: SSHSession? = nil,
        term: String,
        columns: Int,
        rows: Int,
        requestAgentForwarding: Bool = false
    ) throws {
        self.session = session
        self.queue = queue
        self.owner = owner

        var streamContinuation: AsyncStream<Data>.Continuation!
        self.output = Output(stream: AsyncStream { streamContinuation = $0 }, backlog: backlog)
        self.continuation = streamContinuation

        guard let channel = libssh2_channel_open_ex(
            session,
            "session", 7,
            Defaults.windowSize,
            Defaults.packetSize,
            nil, 0
        ) else {
            throw SSHError.fromSession(session, fallback: "could not open channel")
        }
        self.channel = channel

        var succeeded = false
        defer {
            if !succeeded {
                libssh2_channel_free(channel)
                self.channel = nil
            }
        }

        let ptyResult = term.withCString { termName in
            libssh2_channel_request_pty_ex(
                channel,
                termName, UInt32(strlen(termName)),
                nil, 0,
                Int32(columns), Int32(rows),
                Int32(columns * Defaults.cellWidth), Int32(rows * Defaults.cellHeight)
            )
        }
        guard ptyResult == 0 else {
            throw SSHError.fromSession(session, fallback: "the server refused a PTY")
        }

        // Asked for before the shell starts, so SSH_AUTH_SOCK is already in the
        // environment the shell inherits. A server with AllowAgentForwarding no
        // simply refuses, and that is not worth failing the connection over —
        // the user gets a shell, just without an agent in it.
        if requestAgentForwarding {
            _ = libssh2_channel_request_auth_agent(channel)
        }

        guard libssh2_channel_process_startup(channel, "shell", 5, nil, 0) == 0 else {
            throw SSHError.fromSession(session, fallback: "could not start a shell")
        }

        succeeded = true

        // From here on every libssh2 call may return EAGAIN instead of blocking.
        libssh2_session_set_blocking(session, 0)
        schedulePump(after: 0)
    }

    deinit {
        continuation.finish()
        guard let channel else { return }

        // Through the session, which frees it on its own queue and only if it
        // has not been torn down in the meantime. Two crashes on 24/09/2026 came
        // from the two ways of doing this directly. Freeing here, on whichever
        // thread dropped the last reference, races everything the session is
        // doing — SIGSEGV inside `_libssh2_packet_ask`. Queueing the free
        // unconditionally trades that for the opposite order: a channel whose
        // Swift object has already gone is invisible to `teardownOnQueue`,
        // whose reference to it is weak, so `libssh2_session_free` frees the
        // channel itself and the queued call arrives at a dead pointer —
        // `Assertion failed: (session), _libssh2_channel_free`.
        owner?.freeChannelOnQueue(channel)
    }

    // MARK: - Pump

    private func schedulePump(after delay: TimeInterval) {
        guard !isPumping else { return }
        isPumping = true

        let work = { [weak self] in
            self?.isPumping = false
            self?.pump()
        }

        if delay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// One cycle: flush anything queued, then read whatever is available.
    private func pump() {
        guard channel != nil else { return }

        flushPendingWrite()
        let readAny = drain()

        guard channel != nil else { return }

        // Held back, not idle: the terminal is behind, and the next look is
        // soon, so that reading resumes as soon as it has caught up.
        if backlog.waiting >= Defaults.backlogLimit || backlog.waitingEntries >= Defaults.backlogEntries {
            idleDelay = Pump.minimumDelay
            schedulePump(after: Pump.minimumDelay)
        } else if readAny {
            idleDelay = Pump.minimumDelay
            schedulePump(after: 0)
        } else {
            idleDelay = min(idleDelay * Pump.backoffFactor, Pump.maximumDelay)
            schedulePump(after: idleDelay)
        }
    }

    /// Reads until libssh2 has nothing more. Returns whether anything arrived.
    @discardableResult
    private func drain() -> Bool {
        guard let channel else { return false }

        var buffer = [UInt8](repeating: 0, count: Defaults.readBufferSize)
        var readAny = false

        while backlog.waiting < Defaults.backlogLimit, backlog.waitingEntries < Defaults.backlogEntries {
            // Stream 0 only: with a PTY attached the server merges stderr into
            // stdout, so there is no second stream to service.
            let count = buffer.withUnsafeMutableBytes { raw in
                libssh2_channel_read_ex(
                    channel,
                    0,
                    raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }

            if count > 0 {
                backlog.added(Int(count))
                continuation.yield(Data(buffer[0..<Int(count)]))
                readAny = true
                continue
            }

            if count == Int(LIBSSH2_ERROR_EAGAIN) {
                return readAny
            }

            if count == 0 {
                // Zero is *not* proof of EOF: libssh2 also returns it when this
                // read produced nothing for this channel, which happens when the
                // packet it processed belonged to another one. Agent forwarding
                // makes that routine — the auth-agent channel opens inside this
                // very read — and treating it as EOF killed the shell the moment
                // the remote touched SSH_AUTH_SOCK. Only `channel_eof` decides.
                guard libssh2_channel_eof(channel) == 1 else { return readAny }
                finishReason = "eof"
            } else {
                finishReason = "read error \(count)"
            }

            // A genuine EOF, or a real error. Either way the shell is over.
            finish()
            return readAny
        }
        // Stopped at the limit; ``pump()`` looks again shortly.
        return readAny
    }

    // MARK: - Writing

    /// Sends keystrokes to the remote shell.
    ///
    /// Writes are attempted immediately rather than waiting for the pump, so
    /// typing latency does not depend on the read backoff. They are also
    /// fire-and-forget: a terminal has nothing useful to do with a write error
    /// that the read side will report anyway as a disconnection.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, self.channel != nil else { return }

            self.pendingWrite.append(data)
            self.flushPendingWrite()

            // Output is likely on its way back; stop backing off.
            self.idleDelay = Pump.minimumDelay
            self.schedulePump(after: 0)
        }
    }

    /// Hands as much of ``pendingWrite`` to libssh2 as it will take. Whatever is
    /// left stays queued for the next cycle.
    private func flushPendingWrite() {
        guard let channel, !pendingWrite.isEmpty else { return }

        var consumed = 0

        pendingWrite.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }

            while consumed < raw.count {
                let written = libssh2_channel_write_ex(
                    channel,
                    0,
                    base + consumed,
                    raw.count - consumed
                )

                if written > 0 {
                    consumed += Int(written)
                    continue
                }
                // EAGAIN means the window or the socket is full: keep the rest.
                // Any other error is terminal, and the read side will report it.
                break
            }
        }

        if consumed > 0 {
            pendingWrite.removeFirst(consumed)
        }
    }

    // MARK: - Control

    /// Tells the remote about a new window size, so full-screen programs redraw
    /// correctly.
    func resize(columns: Int, rows: Int) {
        queue.async { [weak self] in
            guard let channel = self?.channel else { return }
            _ = libssh2_channel_request_pty_size_ex(
                channel,
                Int32(columns), Int32(rows),
                Int32(columns * Defaults.cellWidth), Int32(rows * Defaults.cellHeight)
            )
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, let channel = self.channel else { return }
            _ = libssh2_channel_close(channel)
            self.finishReason = self.finishReason ?? "closed by caller"
            self.finish()
        }
    }

    /// Synchronous teardown for the owning session. Must be called on the queue.
    ///
    /// The session uses this to stop the pump before it frees the session and
    /// closes the socket, so no scheduled work can touch a dangling handle.
    func teardownOnQueue() {
        finishReason = finishReason ?? "session teardown"
        finish()
    }

    private func finish() {
        guard let channel else { return }

        if libssh2_channel_eof(channel) == 1 {
            exitStatus = libssh2_channel_get_exit_status(channel)
        }

        libssh2_channel_free(channel)
        self.channel = nil
        pendingWrite.removeAll()
        continuation.finish()
    }
}

/// Bytes handed towards the terminal and not yet taken by it, for a producer
/// to look at before it reads more. Written from two threads, the producer's
/// and the consumer's. Used by the SSH shell and by mosh, each its own way of
/// not reading: see ``SSHShellChannel/Output`` and `MoshTerminalTransport`.
///
/// In bytes and in entries: bytes alone would let a flood of tiny frames
/// through, entries alone a few enormous ones (Android's `TerminalBacklog`).
final class ByteBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var entries = 0

    var waiting: Int { lock.withLock { bytes } }
    var waitingEntries: Int { lock.withLock { entries } }
    func added(_ count: Int) { lock.withLock { bytes += count; entries += 1 } }
    func taken(_ count: Int) { lock.withLock { bytes -= count; entries -= 1 } }
}
