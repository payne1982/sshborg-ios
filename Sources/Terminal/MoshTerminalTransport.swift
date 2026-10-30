// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The terminal's bytes over mosh: ``MoshTransport`` with a socket, a clock and
/// a queue around it.
///
/// Everything the protocol decides is in ``MoshTransport``, which owns no socket
/// and no thread so that a test can drive it with a clock it controls, and
/// everything the network needs is in ``MoshSocket``. This is the third piece:
/// the loop that asks the state machine what to send, puts it on the wire, waits
/// for an answer or for the next deadline, and hands back what arrives.
///
/// ### Why the loop lives here and not in the screen
///
/// Under SSH the app reads when somebody is reading, and that is enough —
/// nothing is lost while the terminal is off screen because TCP holds what
/// arrives. Mosh has no such place to put anything. The session exists only for
/// as long as we keep answering, three seconds of heartbeat at a time, so the
/// loop has to outlive the view. ``TerminalSession`` already does: it owns the
/// emulator for the whole life of the tab, which is why the sink is given once,
/// at construction, and is good from the first byte to the last.
///
/// What it does **not** outlive is suspension, and that is deliberate: there is
/// no foreground service on this platform and no honest way to fake one. The
/// loop stops when iOS stops the app and picks the same session up on the way
/// back, which is the whole reason mosh is worth more here than on Android —
/// see PIANO.md, §5 of the plan.
///
/// ### The three things that were paid for on Android and are not rediscovered
///
/// 1. **Host bytes are not applied on the loop's thread.** Applying them means
///    taking the emulator's lock, and the thing that draws the screen holds that
///    same lock for as long as a draw takes. A loop blocked there is a loop that
///    is not acknowledging frames, and a server whose frame has not been
///    acknowledged retransmits instead of advancing. Measured over there on a
///    LAN against a real server, with a draw of 20 ms every 30: the median
///    keystroke went from 17 ms to 31 ms and every other one to **270 ms**, with
///    the stale frames nearly doubled. So they go through ``screen``, one
///    consumer, in the order the far end sent them.
/// 2. **The loop runs whether or not anybody is looking**, and the bytes are
///    applied rather than queued while nobody is. A program left running in the
///    background would otherwise pile up frames without limit, where the
///    emulator has a bounded scrollback and is the thing that will be shown when
///    the user comes back.
/// 3. **Liveness is believed only on a fresh arrival**, never on the sender's
///    address. A datagram that merely came from the server's address proves
///    nothing: anyone who can put that address on a packet can send one, and
///    what we do with it decides both whether mosh is used at all and whether a
///    session that has actually gone silent is allowed to time out.
final class MoshTerminalTransport: TerminalTransport, @unchecked Sendable {

    // MARK: - What it is made of

    private let mosh: MoshTransport
    private let socket: MoshSocket
    private let ears: Ears
    private let clock: @Sendable () -> MoshTime
    private let silenceLimit: MoshTime

    /// Where host bytes end up. The emulator is the main thread's, so this is
    /// called from the one task that consumes ``screen`` and nowhere else.
    private let apply: TerminalSink

    private let screen: AsyncStream<ScreenWrite>
    private let toScreen: AsyncStream<ScreenWrite>.Continuation

    private let mailbox = Mailbox()
    private let ended = Once<TerminalEnd>()
    private let firstContact = Once<Bool>()

    private let outOfContact: AsyncStream<Int>
    private let reportOutOfContact: AsyncStream<Int>.Continuation

    private var tasks: [Task<Void, Never>] = []

    /// Guards ``figures`` and ``finished``, which are the only things written on
    /// one thread and read on another.
    private let lock = NSLock()
    private var figures = Figures()
    private var finished = false
    private var started = false

    /// - Parameters:
    ///   - handover: what `mosh-server` printed — where to talk UDP, and the key.
    ///   - silenceLimit: how long to keep trying while nothing at all comes back,
    ///     before calling the session lost. Not the server's own patience, which
    ///     is set when it is started and is deliberately much larger so that a
    ///     server forgotten by a killed app does not hold a shell for ever. This
    ///     is ours, and it is a compromise with something the app does not have
    ///     yet: mosh's own client shows a "contact lost" line and goes on trying
    ///     indefinitely, and until there is somewhere to say that, a terminal
    ///     that cannot be reached is a photograph with nothing to explain it. So
    ///     we stay patient for long enough to cover what mosh is for — a tunnel,
    ///     a lift, a change of network, a phone in a pocket — and after that we
    ///     say so rather than go on showing a screen that is nobody's.
    ///   - apply: where host bytes go, on the main actor.
    init(
        handover: MoshHandover,
        silenceLimit: MoshTime = MoshTerminalTransport.silenceLimit,
        clock: @escaping @Sendable () -> MoshTime = MoshTerminalTransport.uptimeMilliseconds,
        apply: @escaping TerminalSink
    ) throws {
        self.clock = clock
        self.silenceLimit = silenceLimit
        self.apply = apply

        var writes: AsyncStream<ScreenWrite>.Continuation!
        self.screen = AsyncStream(bufferingPolicy: .unbounded) { writes = $0 }
        self.toScreen = writes

        var seconds: AsyncStream<Int>.Continuation!
        self.outOfContact = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { seconds = $0 }
        self.reportOutOfContact = seconds

        self.ears = Ears(toScreen: writes, clock: clock)
        self.mosh = MoshTransport(crypto: try MoshCrypto(printableKey: handover.key), listener: ears)
        self.socket = MoshSocket(
            peer: MoshSocket.Peer(host: handover.host, port: UInt16(handover.port))
        )
    }

    // MARK: - What the terminal above sees

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    var screenIsSynchronised: Bool { true }

    var outOfContactSeconds: AsyncStream<Int>? { outOfContact }

    func write(_ data: Data) {
        guard isConnected else { return }
        mailbox.post(.typed(data))
    }

    func resize(columns: Int, rows: Int) {
        guard isConnected else { return }
        mailbox.post(.resized(columns: columns, rows: rows))
    }

    /// Waits for the session to end. The bytes do not come through here — they
    /// are pushed at the sink from the moment ``start()`` is called, because the
    /// first frame can arrive before anyone thinks to read.
    func run() async -> TerminalEnd {
        // nil only when the task awaiting this was cancelled, which means the
        // reader has gone and what it is told no longer reaches anybody.
        await ended.get() ?? .cleanExit
    }

    /// Asks the server to go away, and stops the loop whether or not it answers.
    ///
    /// Saying goodbye is worth the moment it takes: without it the server
    /// detaches and sits there until its own network timeout — minutes of a
    /// process, and of a terminal, for a session the user has closed. It is not
    /// waited for, because this is called from the main thread while a tab is
    /// being closed.
    func close() {
        lock.lock()
        let neverStarted = !started
        lock.unlock()

        if neverStarted {
            settle(.cleanExit)
            return
        }
        mailbox.post(.goodbye)
    }

    // MARK: - Starting, and the one question the caller has to ask

    /// Opens the socket and starts the loop. Idempotent; call it before
    /// ``awaitFirstContact(timeout:)``.
    ///
    /// Separate from `init` because it has an effect on the network, and because
    /// the caller wants the object in hand to close it if the handshake does not
    /// come off.
    func start() {
        lock.lock()
        if started || finished {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        // The emulator's thread, and the only consumer of the queue: one task,
        // so the order the far end sent its frames in is the order the screen
        // gets them in.
        tasks.append(Task { @MainActor [weak self] in
            guard let stream = self?.screen else { return }
            for await write in stream {
                guard let self else { return }
                self.apply(write.bytes)
                let waited = self.clock() - write.at
                // `withLock` rather than lock/unlock: the compiler refuses the
                // pair inside an async function, rightly — a lock held across a
                // suspension is a lock held by nobody — and this scope has no
                // `await` in it, which is the thing the closure makes visible.
                self.lock.withLock {
                    self.figures.applied += 1
                    if waited > self.figures.worstScreenWait {
                        self.figures.worstScreenWait = waited
                    }
                }
            }
        })

        // Everything the sockets hear, turned into one more thing the loop has
        // to deal with. The framework delivers on its own queue; the loop is the
        // only thread allowed to touch the state machine, so this hands over and
        // does nothing else.
        tasks.append(Task { [socket, mailbox] in
            for await datagram in socket.arrivals {
                mailbox.post(.datagram(datagram))
            }
        })

        tasks.append(Task { [weak self] in
            guard let transport = self else { return }
            await transport.socket.start()
            let end = await transport.pump()
            await transport.socket.close()
            transport.toScreen.finish()
            transport.reportOutOfContact.finish()
            // After the sockets are gone, and in this order: whoever is waiting
            // on the end wakes up to a transport that has already let go of
            // everything it held.
            transport.firstContact.settle(false)
            transport.settle(end)
        })
    }

    /// Waits for the first datagram to come back, which is the only proof that
    /// there is a path at all.
    ///
    /// There is no handshake in this protocol and no error from the far end for a
    /// blocked path: an inbound UDP port the network will not carry looks exactly
    /// like a server that has not spoken yet. So the one honest test is to send
    /// and wait, and false here is ``MoshBootstrap/Unavailable/Reason/noUDPAnswer``
    /// for the caller to report.
    func awaitFirstContact(timeout: TimeInterval = MoshTerminalTransport.firstContactTimeout) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [firstContact] in await firstContact.get() ?? false }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let answer = await group.next() ?? false
            group.cancelAll()
            return answer
        }
    }

    // MARK: - Diagnostics

    /// One line of how the session is actually going — for a debug build's log,
    /// which is the only way to ask a real device the questions the lab cannot
    /// answer for it, and for the report the user can copy when a session is
    /// lost. One format for both, and the same format as Android's, so that a
    /// number pasted into an issue means the same thing whichever app it came
    /// from.
    ///
    /// No key, no address, no host name: the round trip, what the screen cost,
    /// and the counters that say whether the protocol is fighting something.
    ///
    /// - Parameter reset: clears the worst case, so each logged line describes
    ///   the interval since the last one. A report of how a session ended asks
    ///   for it without resetting.
    func diagnosticLine(reset: Bool = true) -> String {
        lock.lock()
        let now = figures
        if reset { figures.worstScreenWait = 0 }
        lock.unlock()

        return "rtt~\(now.roundTrip)ms screen-wait<=\(now.worstScreenWait)ms applied=\(now.applied) "
            + "stale=\(now.stale) got=\(now.got) missed=\(now.missed) back=\(now.back) "
            + "hops=\(now.hops) refused=\(now.refused) bad=\(now.bad) stray=\(now.stray) "
            + "[\(now.lastStale)]"
    }

    /// How many times the session has moved to a new local port. Diagnostic, and
    /// what the roaming gate asserts on.
    var localPortHops: Int {
        lock.lock()
        defer { lock.unlock() }
        return figures.hops
    }

    /// Datagrams that authenticated under the session key and were still not
    /// usable. Zero on a working session — it means the peer sent something we
    /// could not parse. Packets that never authenticated are counted separately,
    /// in ``MoshTransport/strayDatagrams``, because anyone can send one of those.
    var undecipherableDatagrams: Int {
        lock.lock()
        defer { lock.unlock() }
        return figures.bad
    }

    /// What to show somebody who has to go and look: the port and the address
    /// family, which is the half that gets forgotten. A firewall rule written for
    /// IPv4 does nothing for a session SSH happened to make over IPv6, and
    /// `mosh-server -s` binds to the family the SSH connection arrived on — so a
    /// path can be open and the session still hear nothing.
    func peerDescription() async -> String {
        await socket.peerDescription
    }

    // MARK: - The loop

    private func pump() async -> TerminalEnd {
        var lastHopAt = clock()
        let startedAt = clock()
        var lastHeard: MoshTime = 0
        var closeDeadline = MoshTime.max
        var farewellDeadline = MoshTime.max
        var closing = false
        var hopWanted = false
        var toldTheMTU = false

        while true {
            let now = clock()

            // What the state machine is told, all of it from this one thread.
            for event in mailbox.drain() {
                switch event {
                case .typed(let bytes):
                    mosh.type(bytes)
                case .resized(let columns, let rows):
                    mosh.resize(width: columns, height: rows)
                    // Phase 6b plugs in here: a screen of a different shape
                    // cannot be put back, and for about a round trip the far
                    // end's frames are still painted for the old one.
                case .datagram(let datagram):
                    // Nothing is believed yet. `MoshSocket` connects its ports,
                    // so the system has already dropped anything from another
                    // address — but an address is a claim and not a proof in any
                    // case, and the decision waits for the key.
                    let arrival: MoshTransport.Arrival
                    do {
                        arrival = try mosh.onDatagram(datagram, now: now)
                    } catch {
                        // Someone else's packet, a damaged one, or our own played
                        // back at us. Dropping it is the whole response — anyone
                        // can send us a datagram — but it is counted, because a
                        // session where this is not zero is worth knowing about.
                        arrival = .stray
                    }
                    // Only a datagram that opened under our key and had never
                    // arrived before. A replayed one proves nothing it did not
                    // prove when it was new, and a stray one proves nothing.
                    if arrival == .fresh {
                        lastHeard = now
                        report(outOfContact: 0)
                        firstContact.settle(true)
                    }
                case .goodbye:
                    closing = true
                }
            }

            if closing, !mosh.shutdownInProgress {
                mosh.startShutdown(now: now)
                closeDeadline = now + Self.closeGrace
            }
            if mosh.counterpartyShutdown, farewellDeadline == .max {
                // The server is going away — the shell exited, or it was told to.
                // One more tick gets our acknowledgement out so it can stop
                // retrying and exit now rather than on its timeout; then there is
                // nothing left to be connected to.
                farewellDeadline = now + Self.farewellGrace
            }

            // The address family is only known once the connection has resolved
            // the name, which is the price of letting the framework do it: until
            // then the budget is the pessimistic one that is safe on both.
            if !toldTheMTU, let isIPv4 = await socket.isIPv4 {
                mosh.useMTU(forIPv4: isIPv4)
                toldTheMTU = true
            }

            do {
                for datagram in try mosh.tick(now: now) {
                    await socket.send(datagram)
                }
            } catch {
                return .lost(
                    summary: nil,
                    detail: "mosh: the session loop stopped\n\(error)\n" + diagnosticLine(reset: false)
                )
            }

            if await socket.takeMessageTooLarge() {
                // EMSGSIZE: the path will not carry what we guessed it would. The
                // datagram is gone and the state it carried is retransmitted,
                // smaller, by the next tick.
                mosh.useFallbackMTU()
            }
            if await socket.takeHopRequest() { hopWanted = true }

            await publishFigures()

            if mosh.shutdownAcknowledged { return .cleanExit }
            if now >= closeDeadline { return .cleanExit }
            if now >= farewellDeadline { return .cleanExit }
            if Task.isCancelled { return .cleanExit }

            let silent = now - (lastHeard != 0 ? lastHeard : startedAt)
            if silent > silenceLimit { return lost(silentFor: silent) }
            // Told to the screen in whole seconds, so that a terminal nothing is
            // arriving at can say why. Whole seconds rather than milliseconds
            // because the loop comes round several times a second and the screen
            // has no use for that.
            report(outOfContact: Int(silent / 1000))

            if !closing,
               hopWanted || mosh.shouldHopLocalPort(now: now, lastHopAt: lastHopAt),
               now - lastHopAt >= Self.hopMinInterval {
                await socket.hop()
                lastHopAt = now
                hopWanted = false
            }
            await socket.prune()

            // Wait for something to arrive or for the state machine's next
            // deadline, whichever is sooner. The ceiling is there so that the
            // loop's own clocks — giving up, hopping, saying goodbye — are never
            // further off than that, however far away the protocol's next event.
            let wait = min(max(mosh.nextWakeup - now, 1), Self.maximumWait)
            await mailbox.wait(forAtMost: wait)
        }
    }

    /// @param silentFor how long nothing has been heard, which is the only
    /// symptom there is.
    ///
    /// There is no summary: only the caller can reach the string resources, and
    /// it has a line in every locale for exactly this. What is here is the
    /// detail — the same block that holds a stack trace on the SSH side, and
    /// untranslated for the same reason: it exists to be pasted into an issue,
    /// and a reader who has to act on it is better served by names that do not
    /// change with the phone's language.
    private func lost(silentFor silent: MoshTime) -> TerminalEnd {
        .lost(
            summary: nil,
            detail: "mosh silent=\(silent / 1000)s limit=\(silenceLimit / 1000)s\n"
                + diagnosticLine(reset: false)
        )
    }

    /// Copies the counters out of the state machine under the lock, so that the
    /// line can be asked for from wherever the error report is built without
    /// reading what the loop is writing.
    private func publishFigures() async {
        let hops = await socket.hops
        let refused = await socket.refusedSends

        lock.withLock {
            figures.roundTrip = Int(mosh.timing.smoothedRoundTrip)
            figures.stale = mosh.staleFrames
            figures.got = mosh.receivedDatagrams
            figures.missed = mosh.missedDatagrams
            figures.back = mosh.returnedToState
            figures.bad = mosh.protocolErrors
            figures.stray = mosh.strayDatagrams
            figures.lastStale = mosh.lastStaleFrame
            figures.hops = hops
            figures.refused = refused
        }
    }

    private func report(outOfContact seconds: Int) {
        guard lastReported != seconds else { return }
        lastReported = seconds
        reportOutOfContact.yield(seconds)
    }

    /// Touched by the loop only.
    private var lastReported = -1

    private func settle(_ end: TerminalEnd) {
        lock.lock()
        finished = true
        lock.unlock()
        ended.settle(end)
    }

    deinit {
        for task in tasks { task.cancel() }
        toScreen.finish()
        reportOutOfContact.finish()
    }

    // MARK: - The pieces

    /// A run of host bytes with the moment it arrived, so that what the screen
    /// cost can be seen rather than guessed at.
    private struct ScreenWrite {
        let bytes: Data
        let at: MoshTime
    }

    /// What ``MoshTransport`` tells us, forwarded.
    ///
    /// A separate object because the state machine holds its listener weakly —
    /// rightly, since it is normally owned by whoever owns the machine — and this
    /// one is owned by us, so it lives exactly as long as we do.
    private final class Ears: MoshTransportListener {
        private let toScreen: AsyncStream<ScreenWrite>.Continuation
        private let clock: @Sendable () -> MoshTime

        init(toScreen: AsyncStream<ScreenWrite>.Continuation, clock: @escaping @Sendable () -> MoshTime) {
            self.toScreen = toScreen
            self.clock = clock
        }

        /// Handed over, not applied: see the first of the three rules above.
        func onHostBytes(_ bytes: Data) {
            toScreen.yield(ScreenWrite(bytes: bytes, at: clock()))
        }

        /// The server telling us how big it thinks the terminal is. We are the
        /// ones who decide that, and we have already told it, so there is
        /// nothing here to obey.
        func onHostResize(width: Int, height: Int) {}
    }

    enum Inbound {
        case typed(Data)
        case resized(columns: Int, rows: Int)
        case datagram(Data)
        case goodbye
    }

    /// What the loop is told from elsewhere, and the way it is woken.
    ///
    /// ``write`` and ``resize`` are called from the screen's thread and the
    /// datagrams arrive on the framework's; ``MoshTransport`` is single-threaded
    /// by design and expects to be touched only by the loop. A queue plus a
    /// wake-up is the whole of the handover, and it costs nothing in latency: a
    /// keystroke is not sent the instant it is noticed anyway, but
    /// ``MoshTransport/sendMinDelay`` later, so that a burst of them becomes one
    /// packet.
    ///
    /// The datagrams waiting here are bounded, as the socket's own queue is:
    /// the task that hands them over empties that queue as fast as it fills, so
    /// a bound only there bounded nothing, and a loop held up would have kept
    /// every datagram the network delivered. Found by an audit on 30/10/2026.
    /// The oldest go first, as they do in the socket's queue — SSP sends whole
    /// states, so the newest is the one worth having. What was typed is never
    /// dropped: there is no copy of it anywhere else. Android has no such queue;
    /// its loop reads the socket itself, and the kernel's buffer is the bound.
    final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [Inbound] = []
        private var waiter: CheckedContinuation<Void, Never>?
        private var woken = false
        private var datagrams = 0
        private let datagramLimit: Int

        init(datagramLimit: Int = MoshSocket.arrivalBacklog) {
            self.datagramLimit = datagramLimit
        }

        func post(_ event: Inbound) {
            lock.lock()
            if case .datagram = event {
                if datagrams == datagramLimit,
                   let oldest = queued.firstIndex(where: { if case .datagram = $0 { return true }; return false }) {
                    queued.remove(at: oldest)
                } else {
                    datagrams += 1
                }
            }
            queued.append(event)
            let waiting = waiter
            waiter = nil
            if waiting == nil { woken = true }
            lock.unlock()
            waiting?.resume()
        }

        func drain() -> [Inbound] {
            lock.lock()
            defer {
                queued.removeAll()
                datagrams = 0
                lock.unlock()
            }
            return queued
        }

        /// Returns as soon as something is posted, or after `milliseconds`.
        ///
        /// The timer is an unstructured task on purpose: it is not cancelled when
        /// the loop's task is, so a loop waiting here always comes round again
        /// and can see for itself that it has been asked to stop.
        func wait(forAtMost milliseconds: MoshTime) async {
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                self?.wake()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if woken || !queued.isEmpty {
                    woken = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
            timer.cancel()
        }

        private func wake() {
            lock.lock()
            let waiting = waiter
            waiter = nil
            if waiting == nil { woken = true }
            lock.unlock()
            waiting?.resume()
        }
    }

    /// A value settled once and handed to the one task waiting for it.
    ///
    /// An `AsyncStream` rather than a continuation because a task cancelled
    /// while waiting on a continuation is a task that never wakes up, where an
    /// iteration simply ends. Yielding twice is harmless: the stream is finished
    /// by the first.
    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let stream: AsyncStream<Value>
        private let continuation: AsyncStream<Value>.Continuation

        init() {
            var settled: AsyncStream<Value>.Continuation!
            stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { settled = $0 }
            continuation = settled
        }

        func settle(_ value: Value) {
            continuation.yield(value)
            continuation.finish()
        }

        /// nil when the waiting task was cancelled before anything was settled.
        func get() async -> Value? {
            for await value in stream { return value }
            return nil
        }
    }

    private struct Figures {
        var roundTrip = 0
        var stale = 0
        var got = 0
        var missed = 0
        var back = 0
        var hops = 0
        var refused = 0
        var bad = 0
        var stray = 0
        var lastStale = ""
        var applied = 0
        var worstScreenWait: MoshTime = 0
    }

    // MARK: - The figures of the loop, all of them mosh's

    /// The ceiling on how long the loop sleeps, so its own clocks stay honest.
    static let maximumWait: MoshTime = 250

    /// How long a session with no answer at all is given before it is a failure.
    static let firstContactTimeout: TimeInterval = 10

    /// How long a session hears nothing before it is called lost.
    static let silenceLimit: MoshTime = 30 * 60 * 1000

    /// How long ``close()`` waits for the server to acknowledge the goodbye.
    static let closeGrace: MoshTime = 1_000

    /// How long to keep answering a server that has said it is going away.
    static let farewellGrace: MoshTime = 300

    /// Never hop twice inside this, however many sends fail: hopping is not a
    /// cure for loss.
    static let hopMinInterval: MoshTime = 1_000

    /// Milliseconds since the device started, which is the clock the protocol
    /// wants: it never goes backwards and it is not the wall clock, so a session
    /// is not ended by somebody correcting the time.
    static let uptimeMilliseconds: @Sendable () -> MoshTime = {
        MoshTime(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
