// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The state machine, driven by a clock the test owns.
///
/// This is why ``MoshTransport`` has no socket and no thread in it: a heartbeat,
/// a retransmission and a mindelay cannot be checked honestly against a real
/// clock — a test that sleeps either takes minutes or asserts that something
/// happened *about* when it should have. Here the time is an argument, so ten
/// minutes of session cost no milliseconds and the assertions are exact.
final class MoshTransportTests: XCTestCase {

    private var key = Data((0..<16).map { UInt8($0 &* 7 &+ 1) })
    private var listener: RecordingListener!
    private var transport: MoshTransport!
    private var server: ServerStub!

    override func setUpWithError() throws {
        listener = RecordingListener()
        transport = try MoshTransport(crypto: MoshCrypto(key: key), listener: listener)
        server = try ServerStub(key: key)
    }

    // MARK: - Sending

    /// A burst of keys becomes one packet, because the tick that first notices
    /// typing schedules it rather than sending it.
    ///
    /// Past the start of the session first, and that is worth knowing: at time
    /// zero an acknowledgement is already owed — `nextAckTime` begins at nought
    /// — so the very first keystroke of a session goes out at once with nothing
    /// to wait for. Mosh is the same, and it is right: there is nothing to batch
    /// it with yet.
    func testABurstOfTypingBecomesOnePacket() throws {
        XCTAssertEqual(try transport.tick(now: 0).count, 1, "the session did not open with a packet")

        transport.type(Data("l".utf8))
        XCTAssertEqual(try transport.tick(now: 100), [], "a keystroke went out before the frame rate")
        transport.type(Data("s".utf8))
        transport.type(Data("\r".utf8))
        XCTAssertEqual(try transport.tick(now: 249), [])

        // Half the round-trip estimate after the last packet — but **capped at
        // 250 ms**, which is what decides it from a cold start: the first guess
        // is a second of round trip, half of that is 500, and the cap brings it
        // back to 250. The eight-millisecond mindelay is the floor, not the
        // thing that paces this.
        let datagrams = try transport.tick(now: 250)
        XCTAssertEqual(datagrams.count, 1)

        let sent = try server.read(try XCTUnwrap(datagrams.first))
        XCTAssertEqual(sent.instruction.newNumber, 2)
        XCTAssertEqual(
            sent.instruction.diff,
            MoshDiffs.encodeUserDiff([.keystrokes(Data("ls\r".utf8))]),
            "three keystrokes did not arrive as one action"
        )
    }

    /// Mosh's three-second heartbeat, which is the figure the plan's battery
    /// note is about. Nothing typed, nothing heard, and still a packet — because
    /// a session the client stops answering is a session the server forgets.
    func testTheHeartbeatGoesOutEveryThreeSeconds() throws {
        let first = try transport.tick(now: 0)
        XCTAssertEqual(first.count, 1, "the first tick said nothing at all")
        XCTAssertTrue(try server.read(try XCTUnwrap(first.first)).instruction.diff.isEmpty)

        XCTAssertEqual(try transport.tick(now: 2_999), [])
        XCTAssertEqual(try transport.tick(now: 3_000).count, 1)
        XCTAssertEqual(try transport.tick(now: 3_001), [])
        XCTAssertEqual(try transport.tick(now: 6_000).count, 1)
    }

    /// Ten minutes of nothing happening, with neither side giving up: the gate
    /// the plan asks for, in a form that costs no time at all.
    func testTenMinutesOfSilenceKeepsTheSessionAlive() throws {
        var now: MoshTime = 0
        var packets = 0

        while now < 600_000 {
            packets += try transport.tick(now: now).count
            // Answer every heartbeat, as a live server would, so the session
            // stays in the state where it is *not* giving up.
            if packets > 0, now % 3_000 == 0 {
                try transport.onDatagram(server.emptyFrame(ack: UInt64(packets)), now: now)
            }
            now += 500
        }

        XCTAssertGreaterThan(packets, 190, "about one heartbeat every three seconds for ten minutes")
        XCTAssertLessThan(packets, 210)
        XCTAssertFalse(transport.shutdownInProgress)
        XCTAssertFalse(transport.counterpartyShutdown)
        XCTAssertEqual(transport.strayDatagrams, 0)
    }

    /// Sent, unacknowledged, and the session alive: the diff is offered again at
    /// frame rate rather than forgotten.
    func testAnUnacknowledgedDiffIsOfferedAgain() throws {
        // Hear something first, so the session counts as active.
        try transport.onDatagram(server.emptyFrame(ack: 0), now: 0)

        transport.type(Data("x".utf8))
        let first = try transport.tick(now: 100)
        XCTAssertEqual(first.count, 1)

        // Not at frame rate: the state we just sent is still inside the window
        // where mosh gives it the benefit of the doubt, so what schedules the
        // next attempt is the retransmission timeout — the round-trip estimate
        // plus four variations, capped at a second, plus the acknowledgement
        // delay. From a pessimistic start that is 1100 ms after the send.
        XCTAssertEqual(try transport.tick(now: 400), [])
        XCTAssertEqual(try transport.tick(now: 1_199), [])
        let again = try transport.tick(now: 1_200)
        XCTAssertEqual(again.count, 1, "an unacknowledged keystroke was never offered again")

        XCTAssertEqual(try server.read(try XCTUnwrap(again.first)).instruction.diff, try server.read(try XCTUnwrap(first.first)).instruction.diff)
    }

    // MARK: - Receiving

    func testAFrameIsAppliedAndAcknowledged() throws {
        try transport.onDatagram(
            server.frame(old: 0, new: 1, bytes: Data("hello".utf8)), now: 500
        )

        XCTAssertEqual(listener.hostBytes, [Data("hello".utf8)])
        XCTAssertEqual(listener.statesReached, [1])

        // On the next tick, because a tick is what computes the timers as well
        // as what sends: the contract is to tick after every event.
        let ack = try transport.tick(now: 510)
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(try server.read(try XCTUnwrap(ack.first)).instruction.ackNumber, 1)
    }

    func testAResizeAndAnEchoAcknowledgementComeThrough() throws {
        try transport.onDatagram(server.frame(old: 0, new: 1, resize: (120, 40)), now: 0)
        try transport.onDatagram(server.frame(old: 1, new: 2, echoAck: 77), now: 10)

        XCTAssertEqual(listener.resizes, [[120, 40]])
        XCTAssertEqual(listener.echoAcks, [77])
    }

    /// A retransmission of a frame we already hold is not an error and not an
    /// application: it is simply nothing.
    func testADuplicateFrameChangesNothing() throws {
        let frame = server.frame(old: 0, new: 1, bytes: Data("once".utf8))
        try transport.onDatagram(frame, now: 0)
        try transport.onDatagram(server.reseal(frame), now: 10)

        XCTAssertEqual(listener.hostBytes, [Data("once".utf8)])
    }

    /// The shortcut this client takes, and its price: we keep one screen, so a
    /// frame diffed against a state we have left is unusable. It is dropped,
    /// counted, and — this is the part that matters — acknowledged *at once*,
    /// because until the far end learns which state we hold it goes on sending
    /// frames we cannot use.
    func testAStaleFrameIsDroppedAndAcknowledgedImmediately() throws {
        try transport.onDatagram(server.frame(old: 0, new: 4, bytes: Data("four".utf8)), now: 0)
        _ = try transport.tick(now: 100)

        try transport.onDatagram(server.frame(old: 2, new: 5, bytes: Data("five".utf8)), now: 200)

        XCTAssertEqual(listener.hostBytes, [Data("four".utf8)], "a stale frame was applied")
        XCTAssertEqual(transport.staleFrames, 1)
        XCTAssertEqual(transport.lastStaleFrame, "old=2 new=5 held=4")
        XCTAssertEqual(transport.nextWakeup, 200, "the acknowledgement was batched instead of sent")
    }

    /// And the cure, which Android measured as 78 frames rescued in one session
    /// of typing: if the screen can go back to what the frame was computed
    /// against, the frame is applied on top instead of thrown away.
    func testAScreenThatCanGoBackRescuesTheFrame() throws {
        listener.canReturnToState = true

        try transport.onDatagram(server.frame(old: 0, new: 4, bytes: Data("four".utf8)), now: 0)
        try transport.onDatagram(server.frame(old: 2, new: 5, bytes: Data("five".utf8)), now: 200)

        XCTAssertEqual(listener.returnRequests, [2])
        XCTAssertEqual(listener.hostBytes, [Data("four".utf8), Data("five".utf8)])
        XCTAssertEqual(transport.returnedToState, 1)
        XCTAssertEqual(transport.staleFrames, 0)
    }

    /// Counted from the gaps the far end leaves in its own sequence numbers,
    /// which is the one number that tells a lossy link from a protocol getting
    /// in its own way.
    func testMissedDatagramsAreCountedFromTheGaps() throws {
        try transport.onDatagram(server.emptyFrame(ack: 0), now: 0)
        server.skipSequence(3)
        try transport.onDatagram(server.emptyFrame(ack: 0), now: 10)

        XCTAssertEqual(transport.missedDatagrams, 3)
        XCTAssertEqual(transport.receivedDatagrams, 2)
    }

    /// Anyone can send a datagram to an open UDP port, so this is not a fault
    /// of the session's and is counted apart.
    func testRubbishIsCountedAndIgnored() throws {
        try transport.onDatagram(Data(repeating: 0xAB, count: 60), now: 0)
        try transport.onDatagram(Data(), now: 0)

        XCTAssertEqual(transport.strayDatagrams, 2)
        XCTAssertEqual(transport.receivedDatagrams, 0)
        XCTAssertEqual(transport.protocolErrors, 0, "the weather was counted as a fault of ours")
        XCTAssertTrue(listener.hostBytes.isEmpty)
    }

    /// Our own direction bit coming back at us authenticates, which is exactly
    /// why it has to be refused rather than counted as weather.
    func testOurOwnTrafficPlayedBackIsAnError() throws {
        transport.type(Data("x".utf8))
        let ours = try XCTUnwrap(try transport.tick(now: 10).first)

        XCTAssertThrowsError(try transport.onDatagram(ours, now: 20)) {
            XCTAssertEqual($0 as? MoshProtocolError, .wrongDirection)
        }

        // And counted as ours, not as the weather: it got past the tag, so it
        // came from whoever holds the session key. On a working session
        // `protocolErrors` is the one that should be zero.
        XCTAssertEqual(transport.protocolErrors, 1)
        XCTAssertEqual(transport.strayDatagrams, 0)
    }

    /// **A state the screen has already been cannot come back**, which is
    /// Android's `ab4a36c`. The replay filter hands a duplicate on deliberately,
    /// because being idempotent about it is this layer's job — and it was not.
    ///
    /// The dangerous shape is the one where the screen *can* go back: two frames
    /// arriving the wrong way round, and the older applied on top of the newer,
    /// taking the screen backwards. Ordinary UDP does that without anybody's
    /// help, and anyone able to copy a datagram back onto the wire could do it
    /// on purpose, with no key and no forgery.
    func testTwoFramesOvertakingEachOtherDoNotTakeTheScreenBackwards() throws {
        listener.canReturnToState = true

        try transport.onDatagram(server.frame(old: 0, new: 2, bytes: Data("newer".utf8)), now: 0)
        try transport.onDatagram(server.frame(old: 0, new: 1, bytes: Data("older".utf8)), now: 10)

        XCTAssertEqual(listener.hostBytes, [Data("newer".utf8)], "the screen went backwards")
        XCTAssertEqual(listener.statesReached, [2])
        XCTAssertTrue(listener.returnRequests.isEmpty, "it offered to go back for an older frame")
    }

    /// And what arrived is reported, because liveness, first contact and the
    /// roaming all hang on the difference between hearing from the server and
    /// merely hearing something — and the address a datagram came from is not
    /// that difference.
    func testWhatArrivedIsReportedToTheCaller() throws {
        let frame = server.frame(old: 0, new: 1, bytes: Data("once".utf8))

        XCTAssertEqual(try transport.onDatagram(frame, now: 0), .fresh)
        XCTAssertEqual(try transport.onDatagram(frame, now: 10), .duplicate, "a byte-for-byte replay")
        XCTAssertEqual(
            try transport.onDatagram(Data(repeating: 0xAB, count: 60), now: 20), .stray
        )

        XCTAssertEqual(listener.hostBytes, [Data("once".utf8)])
    }

    // MARK: - The closing handshake

    func testShutdownClaimsTheAllOnesStateAndStopsWhenAcknowledged() throws {
        transport.startShutdown(now: 0)

        // Paced by half a round trip, like everything else in a closing
        // session, so the goodbye goes out on the tick after the interval.
        XCTAssertEqual(try transport.tick(now: 0), [])
        let goodbye = try transport.tick(now: 500)
        XCTAssertEqual(goodbye.count, 1)
        XCTAssertEqual(try server.read(try XCTUnwrap(goodbye.first)).instruction.newNumber, UInt64.max)
        XCTAssertFalse(transport.shutdownAcknowledged)

        try transport.onDatagram(server.emptyFrame(ack: UInt64.max), now: 100)
        XCTAssertTrue(transport.shutdownAcknowledged)
    }

    /// Without this the client would retry for ever at a server that has gone,
    /// which on a phone is a radio wake-up every three seconds for nothing.
    func testShutdownGivesUpAfterSixteenTries() throws {
        transport.startShutdown(now: 0)

        var now: MoshTime = 0
        var tries = 0
        while !transport.shutdownTimedOut(now: now), now < 60_000 {
            tries += try transport.tick(now: now).count
            now += 250
        }

        XCTAssertTrue(transport.shutdownTimedOut(now: now))
        XCTAssertGreaterThanOrEqual(tries, 16)
        XCTAssertLessThan(now, 10_500, "it kept trying past the active-retry timeout")
    }

    func testTheFarEndGoingAwayIsNoticedAndAcknowledged() throws {
        try transport.onDatagram(server.frame(old: 0, new: UInt64.max), now: 0)

        XCTAssertTrue(transport.counterpartyShutdown)
        // Half a round trip, not `ackDelay`: once either side is shutting down
        // the send interval is what paces the packets.
        XCTAssertEqual(try transport.tick(now: 100), [])
        let ack = try transport.tick(now: 600)
        XCTAssertEqual(try server.read(try XCTUnwrap(ack.first)).instruction.ackNumber, UInt64.max)
    }

    // MARK: - The path

    /// Mosh aims at a 1280-byte *IP* datagram, so what we may put in a UDP
    /// payload is less — and getting that wrong by 28 bytes is what Android's
    /// lab caught. Nothing we send may exceed it.
    func testNoDatagramExceedsThePathBudget() throws {
        // Random, because eight thousand identical bytes compress to nothing
        // and would have travelled in one datagram — proving the opposite of
        // what this asks.
        transport.type(Data((0..<8_000).map { _ in UInt8.random(in: 0...255) }))

        let datagrams = try transport.tick(now: 10)

        XCTAssertGreaterThan(datagrams.count, 1, "eight kilobytes went out in one datagram")
        for datagram in datagrams {
            XCTAssertLessThanOrEqual(datagram.count, MoshTransport.ipv6MTU)
        }
    }

    func testTheFallbackBudgetIsSmallerAndSticks() throws {
        transport.useFallbackMTU()
        transport.type(Data((0..<4_000).map { _ in UInt8.random(in: 0...255) }))

        for datagram in try transport.tick(now: 10) {
            XCTAssertLessThanOrEqual(datagram.count, MoshTransport.fallbackMTU)
        }
    }

    /// Ten seconds without anything making it there and back, and the cure is a
    /// new local port: the usual reason is a NAT binding that has gone stale.
    func testTheLocalPortIsHoppedAfterTenSecondsWithoutARoundTrip() throws {
        XCTAssertFalse(transport.shouldHopLocalPort(now: 9_000, lastHopAt: 0))
        XCTAssertTrue(transport.shouldHopLocalPort(now: 11_000, lastHopAt: 0))
        // And not again straight away, or a bad network becomes a storm of new
        // sockets.
        XCTAssertFalse(transport.shouldHopLocalPort(now: 11_000, lastHopAt: 10_000))
    }

    /// The acknowledgement is what proves the round trip, so hearing one has to
    /// postpone the hop.
    func testAnAcknowledgementPostponesTheHop() throws {
        transport.type(Data("x".utf8))
        _ = try transport.tick(now: 10)
        try transport.onDatagram(server.emptyFrame(ack: 1), now: 10_500)

        XCTAssertFalse(transport.shouldHopLocalPort(now: 11_000, lastHopAt: 0))
        XCTAssertTrue(transport.shouldHopLocalPort(now: 21_000, lastHopAt: 0))
    }

    // MARK: - The round-trip estimate

    /// The first real measurement replaces the pessimistic guess outright
    /// instead of being averaged into it, which is mosh's own rule.
    func testTheFirstMeasurementReplacesTheGuess() throws {
        let timing = MoshTiming()
        XCTAssertEqual(timing.smoothedRoundTrip, 1000)

        timing.onPacketReceived(timestamp: 500, reply: MoshTiming.stamp(1_000) - 40, now: 1_000)

        XCTAssertEqual(timing.smoothedRoundTrip, 40)
        XCTAssertEqual(timing.roundTripVariation, 20)
    }

    /// A reply from before a suspend says nothing about the network, and on iOS
    /// that is the ordinary way a session comes back rather than a corner case.
    func testAnImplausibleMeasurementIsThrownAway() {
        let timing = MoshTiming()
        timing.onPacketReceived(timestamp: 1, reply: MoshTiming.stamp(1_000) - 40, now: 1_000)

        timing.onPacketReceived(timestamp: 1, reply: MoshTiming.stamp(10_000) - 6_000, now: 10_000)

        XCTAssertEqual(timing.smoothedRoundTrip, 40, "a six-second round trip poisoned the estimate")
    }

    /// The reply field is theirs plus the time we sat on it, so their
    /// subtraction measures the network and not our scheduling. And it is used
    /// once: a second packet in the same burst has nothing to report.
    func testTheReplyCarriesTheTimeWeHeldItAndIsUsedOnce() {
        let timing = MoshTiming()
        timing.onPacketReceived(timestamp: 1_000, reply: MoshPacket.none, now: 5_000)

        XCTAssertEqual(timing.timestampReply(now: 5_030), 1_030)
        XCTAssertEqual(timing.timestampReply(now: 5_031), MoshPacket.none)
    }

    func testAReplyHeldTooLongIsNotWorthSending() {
        let timing = MoshTiming()
        timing.onPacketReceived(timestamp: 1_000, reply: MoshPacket.none, now: 5_000)

        XCTAssertEqual(timing.timestampReply(now: 6_500), MoshPacket.none)
    }

    // MARK: - Doubles

    private final class RecordingListener: MoshTransportListener {
        var hostBytes: [Data] = []
        var resizes: [[Int]] = []
        var echoAcks: [UInt64] = []
        var statesReached: [UInt64] = []
        var returnRequests: [UInt64] = []
        var canReturnToState = false

        func onHostBytes(_ bytes: Data) { hostBytes.append(bytes) }
        func onHostResize(width: Int, height: Int) { resizes.append([width, height]) }
        func onEchoAck(_ number: UInt64) { echoAcks.append(number) }
        func onStateReached(_ number: UInt64) { statesReached.append(number) }

        func onReturnToState(_ number: UInt64) -> Bool {
            returnRequests.append(number)
            return canReturnToState
        }
    }

    /// Enough of a server to be answered by: it seals frames the way the far end
    /// would, and reads ours back the way the far end would.
    private final class ServerStub {
        private let crypto: MoshCrypto
        /// One fragmenter for the life of the stub, not one per frame: the id is
        /// what tells a retransmission from a new instruction, so a fresh
        /// fragmenter would stamp every frame with id 1 and the client would
        /// deliver the first and ignore the rest. Found by this file.
        private let fragmenter = MoshFragmenter()
        private var sequence: UInt64 = 1

        init(key: Data) throws {
            self.crypto = try MoshCrypto(key: key)
        }

        func skipSequence(_ count: UInt64) { sequence += count }

        func frame(
            old: UInt64,
            new: UInt64,
            bytes: Data? = nil,
            resize: (Int, Int)? = nil,
            echoAck: UInt64? = nil,
            ack: UInt64 = 0
        ) -> Data {
            var actions: [MoshDiffs.HostAction] = []
            if let bytes { actions.append(.hostBytes(bytes)) }
            if let resize { actions.append(.resize(width: resize.0, height: resize.1)) }
            if let echoAck { actions.append(.echoAck(echoAck)) }

            var instruction = MoshInstruction()
            instruction.oldNumber = old
            instruction.newNumber = new
            instruction.ackNumber = ack
            instruction.diff = Self.encodeHostDiff(actions)
            return seal(instruction)
        }

        func emptyFrame(ack: UInt64) -> Data {
            var instruction = MoshInstruction()
            instruction.oldNumber = 0
            instruction.newNumber = 0
            instruction.ackNumber = ack
            return seal(instruction)
        }

        /// The same frame again under a new sequence number, which is what a
        /// retransmission looks like on the wire.
        func reseal(_ datagram: Data) -> Data {
            guard let opened = crypto.open(datagram) else { return datagram }
            sequence += 1
            return (try? crypto.seal(
                nonce: MoshNonce(sequence: sequence, toClient: true), plaintext: opened.plaintext
            )) ?? datagram
        }

        func read(_ datagram: Data) throws -> (nonce: MoshNonce, instruction: MoshInstruction) {
            let opened = try XCTUnwrap(crypto.open(datagram))
            let packet = try MoshPacket.decode(opened.plaintext)
            let fragment = try MoshFragment.decode(packet.payload)
            let assembly = MoshFragmentAssembly()
            let payload = try XCTUnwrap(assembly.add(fragment))
            return (opened.nonce, try MoshInstruction.decode(fragmentPayload: payload))
        }

        private func seal(_ instruction: MoshInstruction) -> Data {
            let fragments = (try? fragmenter.fragments(of: instruction, budget: 1_200)) ?? []
            guard let fragment = fragments.first else { return Data() }
            let packet = MoshPacket(
                timestamp: 1, timestampReply: MoshPacket.none, payload: fragment.encoded
            )
            sequence += 1
            return (try? crypto.seal(
                nonce: MoshNonce(sequence: sequence, toClient: true), plaintext: packet.encoded
            )) ?? Data()
        }

        /// The server's side of ``MoshDiffs``, which the app never writes — so it
        /// lives here, where standing in for a server is the whole job.
        private static func encodeHostDiff(_ actions: [MoshDiffs.HostAction]) -> Data {
            let message = ProtoWriter()
            for action in actions {
                let instruction = ProtoWriter()
                switch action {
                case .hostBytes(let bytes):
                    instruction.bytes(2, ProtoWriter().bytes(4, bytes).data)
                case .resize(let width, let height):
                    instruction.bytes(
                        3, ProtoWriter().varint(5, UInt64(width)).varint(6, UInt64(height)).data
                    )
                case .echoAck(let number):
                    instruction.bytes(7, ProtoWriter().varint(8, number).data)
                }
                message.bytes(1, instruction.data)
            }
            return message.data
        }
    }
}
