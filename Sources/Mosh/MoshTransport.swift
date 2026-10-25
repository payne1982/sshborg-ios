// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the transport hands up: the screen, and the two facts the layer above
/// uses to keep one.
///
/// Class-bound and held weakly, because the session owns the transport and the
/// transport talks back to the session — a strong reference each way would keep
/// a closed session alive with its socket.
protocol MoshTransportListener: AnyObject {

    /// Terminal output to apply. The emulator may answer it — device status and
    /// identification replies — and that answer belongs in ``MoshTransport/type(_:)``,
    /// not in a discarded buffer.
    func onHostBytes(_ bytes: Data)

    func onHostResize(width: Int, height: Int)

    /// Predictive echo only; there is no prediction engine, so this is for the
    /// record.
    func onEchoAck(_ number: UInt64)

    /// The screen now *is* the state numbered `number`. A copy taken here is
    /// what makes ``onReturnToState(_:)`` possible later.
    func onStateReached(_ number: UInt64)

    /// Asks for the screen to be put back as it was at state `number`, because
    /// a frame has arrived that was computed against it and we have moved on.
    ///
    /// Returns `true` if it will be — the frame is then applied on top and
    /// supersedes what we had, being the newer state. `false`, the default, and
    /// the frame is dropped unacknowledged.
    func onReturnToState(_ number: UInt64) -> Bool
}

extension MoshTransportListener {
    func onHostResize(width: Int, height: Int) {}
    func onEchoAck(_ number: UInt64) {}
    func onStateReached(_ number: UInt64) {}
    func onReturnToState(_ number: UInt64) -> Bool { false }
}

/// The transport state machine: what to send, when to send it, and what to do
/// with what arrives.
///
/// **It owns no socket and starts no thread.** Every entry point takes the
/// current time and ``tick(now:)`` hands back the datagrams to put on the wire,
/// so the whole of the protocol's timing can be driven by a test with a clock it
/// controls — the only honest way to check retransmission and heartbeats, and
/// the reason there is no sleep and no call to a clock anywhere in this file.
/// The socket, the port hopping and the lifecycle belong to the layer above.
///
/// ### What the client has to keep
///
/// Upward, a list of states we have sent — a state being a count of user
/// actions, see ``MoshUserStream`` — and the newest one we believe the server
/// holds. Downward, **one** state only: the live terminal. Mosh's own client
/// keeps a queue of terminal snapshots so that it can apply a diff computed
/// against an older one; we do not, because our terminal is SwiftTerm and
/// copying it per frame is not a trade to make by default. An instruction whose
/// `oldNumber` is not the state we hold is therefore dropped, unacknowledged,
/// and the server — which diffs from what we last acknowledged — sends one we
/// can use. The cost is an occasional extra retransmission; the gain is that
/// the screen has exactly one copy.
///
/// Android measured what that costs on a real network and then softened it with
/// a history of screens; ``MoshTransportListener/onReturnToState(_:)`` is where
/// that would plug in here, and it is deliberately optional.
final class MoshTransport {

    private let crypto: MoshCrypto
    private weak var listener: MoshTransportListener?
    private var mtu: Int

    private let sequence = MoshSequence()
    private let replay = MoshReplayFilter(weAreClient: true)
    private let assembly = MoshFragmentAssembly()
    private let fragmenter = MoshFragmenter()
    private let user = MoshUserStream()

    /// Exposed because the round-trip estimate is the most useful thing a
    /// diagnostic can show.
    let timing = MoshTiming()

    init(crypto: MoshCrypto, listener: MoshTransportListener?, mtu: Int = MoshTransport.defaultMTU) {
        self.crypto = crypto
        self.listener = listener
        self.mtu = mtu
    }

    // MARK: - Counters, which are the whole diagnostic

    /// The largest number of fragments one arriving instruction has been split
    /// into.
    var largestAssembly: Int { assembly.largestAssembly }

    /// See ``MoshFragmentAssembly/conflictingFragments``; anything but zero is a
    /// broken assumption.
    var conflictingFragments: Int { assembly.conflictingFragments }

    /// Frames thrown away because they were diffed against a state we no longer
    /// hold.
    ///
    /// The price of keeping one terminal instead of mosh's queue of them, and
    /// the number to look at when typing feels slow: each one costs a round trip
    /// plus ``ackDelay`` before the server sends a frame we can use.
    private(set) var staleFrames = 0

    /// Frames that would have been thrown away and were not, because the screen
    /// could be put back to what they were computed against.
    private(set) var returnedToState = 0

    /// Datagrams from the far end that opened and parsed.
    private(set) var receivedDatagrams = 0

    /// Datagrams the far end sent that never reached us, counted from the gaps
    /// it leaves in its own sequence numbers.
    ///
    /// The one number that tells a lossy link from a protocol getting in its own
    /// way, and the two have the same symptom. Reordering counts here too — a
    /// datagram that arrives late is already past what the replay filter
    /// expects — which is the right way round for a diagnostic, because to the
    /// protocol a late datagram and a lost one are the same thing.
    private(set) var missedDatagrams = 0

    /// Datagrams that did not authenticate: too short, or a failed tag. Anyone
    /// can send one to an open UDP port, so this is not a fault of the
    /// session's and is counted apart from what arrived *under our key*.
    private(set) var strayDatagrams = 0

    /// The state numbers of the last frame we had to throw away: what it was
    /// diffed against, what it would have produced, and what we hold.
    ///
    /// Three shapes tell three different stories: `old` one behind `held` is the
    /// far end being optimistic and a round trip stale; `old` far behind is it
    /// having given up on our acknowledgements and fallen back to its oldest
    /// unacknowledged state; `new` equal to a number we have already seen is a
    /// retransmission we are counting twice.
    private(set) var lastStaleFrame = ""

    // MARK: - State

    private struct SentState {
        var timestamp: MoshTime
        let number: UInt64
        let actionCount: UInt64
    }

    private var sent: [SentState] = [SentState(timestamp: 0, number: 0, actionCount: 0)]
    private var assumedReceiver = 0

    private var ackNumber: UInt64 = 0
    private var heldState: UInt64 = 0
    private var pendingDataAck = false

    private var lastHeard: MoshTime = 0
    private var lastRoundTrip: MoshTime = 0
    private var nextAckTime: MoshTime = 0
    private var nextSendTime: MoshTime = MoshTransport.never
    private var mindelayClock: MoshTime = MoshTransport.never

    private var shutdownStart: MoshTime = MoshTransport.never
    private var shutdownTries = 0

    private(set) var shutdownInProgress = false

    /// True once the server has acknowledged our shutdown, or said it is going
    /// away itself.
    private(set) var shutdownAcknowledged = false

    private(set) var counterpartyShutdown = false

    private var highestSequence: UInt64?

    // MARK: - What the user does

    func type(_ bytes: Data) { user.type(bytes) }

    func resize(width: Int, height: Int) { user.resize(width: width, height: height) }

    /// Begins the closing handshake: from here on every packet claims the
    /// shutdown state number, and the session is over when the server
    /// acknowledges it or ``shutdownTimedOut(now:)`` gives up on it.
    func startShutdown(now: MoshTime) {
        guard !shutdownInProgress else { return }
        shutdownInProgress = true
        shutdownStart = now
    }

    func shutdownTimedOut(now: MoshTime) -> Bool {
        shutdownInProgress
            && (shutdownTries >= Self.shutdownRetries || now - shutdownStart >= Self.activeRetryTimeout)
    }

    // MARK: - The clock

    /// When ``tick(now:)`` next has something to do, so an I/O loop can wait
    /// rather than spin.
    ///
    /// The contract, which mosh's own main loop follows too: **tick after every
    /// event** — a keystroke, a resize, an arriving datagram — and again when
    /// this time comes. A tick is what schedules work as well as what performs
    /// it, so the tick that first notices a keystroke computes when it may go
    /// out (never sooner than ``sendMinDelay``, so that a burst of keys becomes
    /// one packet) and the tick at that moment is the one that sends it.
    var nextWakeup: MoshTime { min(nextAckTime, nextSendTime) }

    /// The datagrams to send now, if any.
    ///
    /// Three things can make a packet: a diff we have not sent, an
    /// acknowledgement we owe within ``ackDelay`` of hearing something, and the
    /// ``ackInterval`` heartbeat that says we are still here. That heartbeat is
    /// what the battery note in the plan is about: three seconds is mosh's
    /// figure, not ours.
    func tick(now: MoshTime) throws -> [Data] {
        try calculateTimers(now: now)
        guard now >= nextAckTime || now >= nextSendTime else { return [] }

        let diff = try user.diff(from: sent[assumedReceiver].actionCount)
        if diff.isEmpty {
            if now >= nextAckTime { return try sendEmptyAck(now: now) }
            if now >= nextSendTime {
                nextSendTime = Self.never
                mindelayClock = Self.never
            }
            return []
        }
        guard now >= nextSendTime || now >= nextAckTime else { return [] }
        return try sendDiff(diff, now: now)
    }

    /// Drops to ``fallbackMTU`` after the kernel has refused a datagram as too
    /// big.
    ///
    /// The budget is a guess about the path, and the one thing that proves it
    /// wrong is `EMSGSIZE`. There is no way back up: mosh does not probe for a
    /// larger one either, and a session that works slightly less efficiently is
    /// the right end of that trade.
    func useFallbackMTU() { mtu = Self.fallbackMTU }

    /// Tells the transport which address family the socket got, because the two
    /// have different headers to pay for.
    func useMTU(forIPv4: Bool) { mtu = forIPv4 ? Self.ipv4MTU : Self.ipv6MTU }

    /// True when nothing has made it there and back for ``portHopInterval``: the
    /// cure is a new local port, because the usual reason is a NAT binding that
    /// has gone stale. Only the client does this — the server adopts whatever
    /// address it hears from, which *is* the roaming.
    func shouldHopLocalPort(now: MoshTime, lastHopAt: MoshTime) -> Bool {
        now - lastRoundTrip > Self.portHopInterval && now - lastHopAt > Self.portHopInterval
    }

    // MARK: - What arrives

    /// A datagram that did not authenticate is dropped here and tallied in
    /// ``strayDatagrams``: anyone can send one, and it says nothing about the
    /// session.
    ///
    /// Throws when the datagram *did* authenticate and is still not usable —
    /// our own traffic played back, or an instruction we cannot parse. That came
    /// from the real peer, so the reason is worth having. Either way the caller
    /// carries on: it is not a reason to end the session.
    func onDatagram(_ datagram: Data, now: MoshTime) throws {
        guard let opened = crypto.open(datagram) else {
            strayDatagrams += 1
            return
        }
        receivedDatagrams += 1

        let number = opened.nonce.sequence
        if let highest = highestSequence, number > highest + 1 {
            missedDatagrams += Int(number - highest - 1)
        }
        if highestSequence == nil || number > highestSequence! { highestSequence = number }

        let fresh = try replay.accept(opened.nonce)
        let packet = try MoshPacket.decode(opened.plaintext)

        if fresh {
            timing.onPacketReceived(
                timestamp: packet.timestamp, reply: packet.timestampReply, now: now
            )
            lastHeard = now
        }

        // A packet with no payload is a heartbeat with nothing in it. Mosh sends
        // them, and the timing above is the whole of what they are for; there is
        // no fragment to decode and asking for one would throw.
        guard !packet.payload.isEmpty else { return }

        guard let payload = assembly.add(try MoshFragment.decode(packet.payload)) else { return }
        let instruction = try MoshInstruction.decode(fragmentPayload: payload)

        processAcknowledgement(instruction.ackNumber, now: now)

        if instruction.newNumber == Self.shutdownNumber {
            // The far end is going away. Acknowledge it so it can stop retrying,
            // and stop pretending we hold its states.
            counterpartyShutdown = true
            ackNumber = Self.shutdownNumber
            pendingDataAck = true
            return
        }

        // Already applied: the duplicate of a frame we have is not an error, it
        // is a retransmission.
        guard instruction.newNumber != heldState else { return }

        if instruction.oldNumber != heldState {
            // We keep one state, the live terminal, so a diff against anything
            // else is unusable and applying it would corrupt the screen. But we
            // can be put back: if the screen can return to what this frame was
            // computed against, the frame is applied on top and supersedes what
            // we had, being the newer state.
            if listener?.onReturnToState(instruction.oldNumber) ?? false {
                returnedToState += 1
                heldState = instruction.oldNumber
            } else {
                staleFrames += 1
                lastStaleFrame = "old=\(instruction.oldNumber) new=\(instruction.newNumber) "
                    + "held=\(heldState)"
                // Acknowledged *now*, not in `ackDelay`. The delay exists to
                // batch acknowledgements, which is right when one is merely
                // owed; here the far end is sending frames we cannot use and
                // will go on doing so until it learns which state we hold, so
                // every millisecond of batching is a millisecond of the screen
                // not moving. In Android's lab this turned a 1.3-second stall at
                // the start of every session into one round trip.
                pendingDataAck = true
                nextAckTime = now
                return
            }
        }

        if !instruction.diff.isEmpty {
            for action in try MoshDiffs.decodeHostDiff(instruction.diff) {
                switch action {
                case .hostBytes(let bytes): listener?.onHostBytes(bytes)
                case .resize(let width, let height):
                    listener?.onHostResize(width: width, height: height)
                case .echoAck(let number): listener?.onEchoAck(number)
                }
            }
        }

        heldState = instruction.newNumber
        ackNumber = instruction.newNumber
        listener?.onStateReached(instruction.newNumber)
        // Every state we accept is worth saying so about, and within `ackDelay`
        // rather than whenever we next happen to send something. Mosh only marks
        // a *data* acknowledgement owed and can afford to: its client keeps a
        // history of screens, so a far end that has lost track of which state we
        // hold costs it nothing. We keep one screen and throw the frame away, so
        // being slow to say where we are is the one thing we cannot afford.
        pendingDataAck = true
    }

    // MARK: - The sender

    private func calculateTimers(now: MoshTime) throws {
        updateAssumedReceiver(now: now)
        user.dropThrough(sent[0].actionCount)

        if pendingDataAck, nextAckTime > now + Self.ackDelay { nextAckTime = now + Self.ackDelay }

        let last = sent[sent.count - 1]
        let active = lastHeard + Self.activeRetryTimeout > now

        if user.count != last.actionCount {
            // Something typed that has not gone out yet: as soon as the frame
            // rate allows, but never within `sendMinDelay` of noticing it, so a
            // burst of keys becomes one packet.
            if mindelayClock == Self.never { mindelayClock = now }
            nextSendTime = max(mindelayClock + Self.sendMinDelay, last.timestamp + timing.sendInterval)
        } else if user.count != sent[assumedReceiver].actionCount, active {
            // Sent, not acknowledged, and the session is alive: keep offering it
            // at frame rate.
            let floor = mindelayClock == Self.never ? 0 : mindelayClock + Self.sendMinDelay
            nextSendTime = max(last.timestamp + timing.sendInterval, floor)
        } else if user.count != sent[0].actionCount, active {
            // Something older is still unacknowledged: retransmit on the
            // round-trip timeout.
            nextSendTime = last.timestamp + timing.retransmitTimeout + Self.ackDelay
        } else {
            nextSendTime = Self.never
        }

        if shutdownInProgress || ackNumber == Self.shutdownNumber {
            nextAckTime = last.timestamp + timing.sendInterval
        }
    }

    /// Gives recently sent states the benefit of the doubt, as mosh does,
    /// instead of assuming loss.
    private func updateAssumedReceiver(now: MoshTime) {
        assumedReceiver = 0
        let window = timing.retransmitTimeout + Self.ackDelay
        for index in 1..<max(sent.count, 1) {
            guard now - sent[index].timestamp < window else { return }
            assumedReceiver = index
        }
    }

    private func sendDiff(_ diff: Data, now: MoshTime) throws -> [Data] {
        let last = sent[sent.count - 1]
        let number: UInt64
        if shutdownInProgress {
            number = Self.shutdownNumber
        } else if user.count == last.actionCount {
            number = last.number
        } else {
            number = last.number + 1
        }

        if number == last.number {
            sent[sent.count - 1].timestamp = now
        } else {
            addSentState(SentState(timestamp: now, number: number, actionCount: user.count))
        }

        let datagrams = try sendInFragments(diff: diff, number: number, now: now)
        assumedReceiver = sent.count - 1
        nextAckTime = now + Self.ackInterval
        nextSendTime = Self.never
        mindelayClock = Self.never
        return datagrams
    }

    private func sendEmptyAck(now: MoshTime) throws -> [Data] {
        let number = shutdownInProgress ? Self.shutdownNumber : sent[sent.count - 1].number + 1
        addSentState(SentState(timestamp: now, number: number, actionCount: user.count))
        let datagrams = try sendInFragments(diff: Data(), number: number, now: now)
        nextAckTime = now + Self.ackInterval
        nextSendTime = Self.never
        return datagrams
    }

    private func sendInFragments(diff: Data, number: UInt64, now: MoshTime) throws -> [Data] {
        var instruction = MoshInstruction()
        instruction.oldNumber = sent[assumedReceiver].number
        instruction.newNumber = number
        instruction.ackNumber = ackNumber
        instruction.throwawayNumber = sent[0].number
        instruction.diff = diff
        instruction.chaff = Self.chaff()

        if number == Self.shutdownNumber { shutdownTries += 1 }
        pendingDataAck = false

        // The budget is what is left of the path MTU once the nonce, the
        // timestamps and the tag have taken their share; the fragment header
        // comes out of it inside the fragmenter.
        let budget = mtu - Self.nonceAndTimestamps - MoshOCB.tagLength
        return try fragmenter.fragments(of: instruction, budget: budget).map { fragment in
            let packet = MoshPacket(
                timestamp: MoshTiming.stamp(now),
                // Only the first datagram of a burst carries the reply: it is
                // consumed when it is used.
                timestampReply: timing.timestampReply(now: now),
                payload: fragment.encoded
            )
            return try crypto.seal(
                nonce: MoshNonce(sequence: try sequence.next(), toClient: false),
                plaintext: packet.encoded
            )
        }
    }

    private func addSentState(_ state: SentState) {
        sent.append(state)
        // Mosh's ceiling, and its way of keeping it: drop from the middle, where
        // a gap costs one retransmission, rather than the oldest, which
        // everything else is still measured against.
        if sent.count > Self.maximumSentStates { sent.remove(at: sent.count - 16) }
    }

    private func processAcknowledgement(_ ack: UInt64, now: MoshTime) {
        guard sent.contains(where: { $0.number == ack }) else { return }
        let before = sent.count
        sent.removeAll { $0.number < ack }
        if before != sent.count || ack == sent[0].number { lastRoundTrip = now }
        if ack == Self.shutdownNumber { shutdownAcknowledged = true }
        assumedReceiver = min(assumedReceiver, sent.count - 1)
    }

    /// Random padding, nought to sixteen bytes. It is not decoration: without it
    /// the length of a datagram tells an observer how much was typed, which is
    /// what a keystroke-timing attack is built on.
    private static func chaff() -> Data {
        let length = Int.random(in: 0...chaffMaximum)
        guard length > 0 else { return Data() }
        return Data((0..<length).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: - The figures, all of them mosh's

    /// The UDP payload we may fill, per address family.
    ///
    /// Mosh aims at a 1280-byte **IP datagram** — not a 1280-byte payload — and
    /// takes the IP and UDP headers out of it before anything else. Android's
    /// lab caught them getting this wrong: datagrams went out at up to 1308
    /// bytes on IPv4 and 1328 on IPv6, the second of which is over the minimum
    /// every IPv6 path is required to carry. Mosh's own comment explains why it
    /// stays low: tunnels and mobile networks drop more than Ethernet's 1500
    /// suggests, and it names a real network that dropped anything from 1320 up.
    ///
    /// For IPv4 it guesses the minimum header because fragmentation there is
    /// merely wasteful; for IPv6 it is deliberately pessimistic — 40 base, 16
    /// for two extension headers, 8 for UDP — because fragmentation there is not
    /// allowed on the path. The default is the IPv6 figure, which is safe on
    /// both, and ``useMTU(forIPv4:)`` raises it once the socket has said which
    /// family it got.
    static let ipv4MTU = 1280 - (20 + 8)
    static let ipv6MTU = 1280 - (40 + 16 + 8)
    static let defaultMTU = ipv6MTU

    /// Mosh's payload MTU of last resort, after the kernel refuses a datagram.
    static let fallbackMTU = 500

    static let sendMinDelay: MoshTime = 8
    static let ackDelay: MoshTime = 100
    static let ackInterval: MoshTime = 3_000
    static let activeRetryTimeout: MoshTime = 10_000
    static let portHopInterval: MoshTime = 10_000
    static let shutdownRetries = 16

    /// The state number that means "I am going away": all ones.
    static let shutdownNumber = UInt64.max

    static let never: MoshTime = .max

    private static let maximumSentStates = 32
    private static let chaffMaximum = 16
    private static let nonceAndTimestamps = MoshCrypto.nonceWireLength + 4
}
