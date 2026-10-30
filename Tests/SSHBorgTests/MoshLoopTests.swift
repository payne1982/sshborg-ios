// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest

@testable import SSHBorg

/// The loop: the state machine, a socket and a clock, talking to something that
/// answers.
///
/// What answers here is a fake server of our own, on the loopback, and that is
/// the point of this suite rather than a weakness of it. The lab proves that
/// **mosh** understands our encoder, and no amount of agreeing with ourselves
/// would say so; what it cannot do is hold a frame back, say goodbye on cue, or
/// answer with rubbish from the right address. Those are the loop's questions,
/// they each end on a number, and they run without the lab's server and its
/// one-test-per-server rule.
///
/// The fake server speaks the half of the protocol production never writes: it
/// encodes a host diff, which only a server does, and sends frames the client is
/// supposed to apply.
final class MoshLoopTests: XCTestCase {

    /// A key of no significance, in the form `mosh-server` prints it.
    private static let key = Data(repeating: 0x2A, count: 16).base64EncodedString()

    /// Somewhere nothing will answer: the documentation range, reserved for
    /// exactly this and routed nowhere.
    private var nowhere: MoshHandover {
        MoshHandover(host: "192.0.2.1", port: 60001, key: Self.key)
    }

    // MARK: - What waits for the loop

    /// A loop held up keeps the newest datagrams up to the bound, and every
    /// keystroke whatever the bound.
    ///
    /// The bound used to be only on the socket's queue, which a task empties into
    /// this one as fast as it fills: nothing held the datagrams back once they
    /// were here. Found by an audit on 30/10/2026.
    func testTheMailboxKeepsTheNewestDatagramsAndEveryKeystroke() {
        let mailbox = MoshTerminalTransport.Mailbox(datagramLimit: 3)
        mailbox.post(.typed(Data("a".utf8)))
        for n in 0..<10 { mailbox.post(.datagram(Data([UInt8(n)]))) }
        mailbox.post(.typed(Data("b".utf8)))

        var typed: [Data] = []
        var datagrams: [Data] = []
        for event in mailbox.drain() {
            switch event {
            case .typed(let bytes): typed.append(bytes)
            case .datagram(let bytes): datagrams.append(bytes)
            default: XCTFail("nothing else was posted: \(event)")
            }
        }
        XCTAssertEqual(typed, [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(datagrams, [Data([7]), Data([8]), Data([9])])

        // And the count starts again with the next round.
        for n in 0..<3 { mailbox.post(.datagram(Data([UInt8(n)]))) }
        XCTAssertEqual(mailbox.drain().count, 3)
    }

    /// A screen behind by either measure stops datagrams being opened, and they
    /// are opened again only once it is back under both low marks — so a loop at
    /// the edge does not flap. Android's marks, since it adopted the idea.
    func testAScreenThatIsBehindHoldsDatagramsBetweenTwoMarks() {
        typealias Marks = MoshTerminalTransport.ScreenBacklog
        let high = Marks.highBytes, low = Marks.lowBytes

        XCTAssertFalse(Marks.isBehind(wasBehind: false, bytes: high, entries: 0))
        XCTAssertTrue(Marks.isBehind(wasBehind: false, bytes: high + 1, entries: 0))
        XCTAssertTrue(Marks.isBehind(wasBehind: false, bytes: 0, entries: Marks.highEntries + 1))

        // Between the marks the answer is whatever it was.
        XCTAssertTrue(Marks.isBehind(wasBehind: true, bytes: low + 1, entries: 0))
        XCTAssertFalse(Marks.isBehind(wasBehind: false, bytes: low + 1, entries: 0))

        // Both measures must come down.
        XCTAssertTrue(Marks.isBehind(wasBehind: true, bytes: 0, entries: Marks.lowEntries + 1))
        XCTAssertFalse(Marks.isBehind(wasBehind: true, bytes: low, entries: Marks.lowEntries))
    }

    // MARK: - There and back

    /// The whole of it, in one claim: a keystroke leaves, the server's screen
    /// arrives, and it arrives at the sink rather than at a queue nobody drains.
    func testAKeystrokeGoesOutAndTheScreenComesBack() async throws {
        let server = try FakeMoshServer(printableKey: Self.key)
        server.start()
        defer { server.stop() }
        server.answer("MOSHLOOP-READY", whenTyped: "ls\r")

        let screen = Screen()
        let transport = try MoshTerminalTransport(
            handover: MoshHandover(host: "127.0.0.1", port: Int(server.port), key: Self.key),
            apply: { bytes in screen.append(bytes) }
        )
        transport.start()
        defer { transport.close() }

        let answered = await transport.awaitFirstContact(timeout: 3)
        XCTAssertTrue(answered, "nothing came back from the fake server")

        transport.write(Data("ls\r".utf8))

        // The server answers the datagram the keystroke travelled in, so this
        // one wait covers the whole way there and back: typed here, read over
        // there, a frame computed for it, and the bytes at our sink.
        let shown = await screen.waitFor("MOSHLOOP-READY", seconds: 3)
        XCTAssertTrue(shown, "the screen never came back; the sink holds \(screen.text)")

        let keystroke = Data("ls\r".utf8)
        let typed = server.instructionsHeard.contains { $0.diff.range(of: keystroke) != nil }
        XCTAssertTrue(typed, "the screen arrived without the keystroke that asked for it")
    }

    /// The first of the three rules the loop exists to respect: host bytes are
    /// not applied on the loop's thread.
    ///
    /// The sink here does what a draw does — it holds the main thread for 400 ms
    /// — and the question is whether the frame it is drawing has been
    /// acknowledged in the meantime. A server whose frame has not been
    /// acknowledged retransmits instead of advancing, which is how this costs
    /// every other keystroke 270 ms on Android when it is got wrong. The
    /// acknowledgement is owed within ``MoshTransport/ackDelay``, 100 ms, so
    /// anything under 300 means the loop never waited for the screen.
    func testHostBytesAreNotAppliedOnTheLoopsThread() async throws {
        let server = try FakeMoshServer(printableKey: Self.key)
        server.start()
        defer { server.stop() }

        let screen = Screen()
        screen.holdTheThread(for: 0.4)
        server.deliver("SLOW")

        let transport = try MoshTerminalTransport(
            handover: MoshHandover(host: "127.0.0.1", port: Int(server.port), key: Self.key),
            apply: { bytes in screen.append(bytes) }
        )
        transport.start()
        defer { transport.close() }

        let answered = await transport.awaitFirstContact(timeout: 3)
        XCTAssertTrue(answered, "nothing came back from the fake server")

        var delay: MoshTime?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, delay == nil {
            delay = server.acknowledgementDelay(forState: 1)
            if delay == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        let measured = try XCTUnwrap(delay, "the frame was never acknowledged at all")
        XCTAssertLessThan(
            measured, 300,
            "state 1 was acknowledged only after the screen let go of the thread: \(measured) ms"
        )
    }

    // MARK: - Liveness, which is believed only on a fresh arrival

    func testWithNothingAtTheOtherEndThereIsNoFirstContact() async throws {
        let transport = try MoshTerminalTransport(handover: nowhere, apply: { _ in })
        transport.start()
        defer { transport.close() }

        let answered = await transport.awaitFirstContact(timeout: 0.5)
        XCTAssertFalse(answered, "a path nothing came back on was called open")
    }

    /// The third rule: an address is a claim and not a proof.
    ///
    /// Anyone who can put the server's address on a packet can send one, and a
    /// trickle of them must not commit the session to mosh — nor keep a dead one
    /// alive. So the datagrams here come from exactly the right address and will
    /// not open under the key, and nothing is believed.
    func testADatagramThatDoesNotOpenIsNotProofOfLife() async throws {
        let server = try FakeMoshServer(printableKey: Self.key, behaviour: .gibberish)
        server.start()
        defer { server.stop() }

        let transport = try MoshTerminalTransport(
            handover: MoshHandover(host: "127.0.0.1", port: Int(server.port), key: Self.key),
            apply: { _ in }
        )
        transport.start()
        defer { transport.close() }

        let answered = await transport.awaitFirstContact(timeout: 1.5)
        XCTAssertFalse(answered, "the session believed an address instead of the key")

        let line = transport.diagnosticLine()
        let strays = try XCTUnwrap(figure("stray", in: line), line)
        XCTAssertGreaterThan(strays, 0, "the rubbish was not even counted: \(line)")
        XCTAssertEqual(figure("got", in: line), 0, "a datagram that never opened was counted as received")
    }

    /// A session that hears nothing is eventually lost, and says in numbers what
    /// happened — untranslated on purpose, because it exists to be pasted into
    /// an issue.
    func testASilentSessionIsLostAndSaysForHowLong() async throws {
        let transport = try MoshTerminalTransport(
            handover: nowhere, silenceLimit: 1_500, apply: { _ in }
        )
        transport.start()

        let end = await transport.run()
        guard case .lost(let summary, let detail) = end else {
            return XCTFail("a session that heard nothing ended as \(end)")
        }
        XCTAssertNil(summary, "the transport worded a line only the caller can localise")

        let said = try XCTUnwrap(detail)
        XCTAssertTrue(said.hasPrefix("mosh silent=1s limit=1s"), said)
        XCTAssertTrue(said.contains("rtt~"), said)
        XCTAssertFalse(transport.isConnected)
    }

    // MARK: - Ending

    func testClosingASessionThatNeverStartedEndsCleanly() async throws {
        let transport = try MoshTerminalTransport(handover: nowhere, apply: { _ in })

        transport.close()

        let end = await transport.run()
        XCTAssertEqual(end, .cleanExit)
        XCTAssertFalse(transport.isConnected)
    }

    /// Saying goodbye is worth the moment it costs: without it the server
    /// detaches and sits there until its own network timeout. So the session
    /// ends on the server's acknowledgement, and the one-second grace is only
    /// what happens when nobody answers — which is what the time here measures.
    func testOurGoodbyeEndsTheSessionOnTheAnswerAndNotOnTheGrace() async throws {
        let server = try FakeMoshServer(printableKey: Self.key)
        server.start()
        defer { server.stop() }

        let transport = try MoshTerminalTransport(
            handover: MoshHandover(host: "127.0.0.1", port: Int(server.port), key: Self.key),
            apply: { _ in }
        )
        transport.start()
        let answered = await transport.awaitFirstContact(timeout: 3)
        XCTAssertTrue(answered, "nothing came back from the fake server")

        let before = Date()
        transport.close()
        let end = await transport.run()

        XCTAssertEqual(end, .cleanExit)
        XCTAssertLessThan(
            Date().timeIntervalSince(before), 0.9,
            "the session waited out its grace instead of taking the acknowledgement"
        )
    }

    /// The far end going away — the shell exited, or it was told to — ends the
    /// session as a clean exit, after one more tick that lets our acknowledgement
    /// out so the server can stop retrying.
    func testTheServerSayingItIsGoingAwayEndsTheSession() async throws {
        let server = try FakeMoshServer(printableKey: Self.key)
        server.start()
        defer { server.stop() }

        let transport = try MoshTerminalTransport(
            handover: MoshHandover(host: "127.0.0.1", port: Int(server.port), key: Self.key),
            apply: { _ in }
        )
        transport.start()
        defer { transport.close() }
        let answered = await transport.awaitFirstContact(timeout: 3)
        XCTAssertTrue(answered, "nothing came back from the fake server")

        server.goodbye()

        let end = await transport.run()
        XCTAssertEqual(end, .cleanExit)
    }

    // MARK: - Reading the line

    /// `name=<number>` out of a diagnostic line, which also pins the format the
    /// line is pasted into issues in.
    private func figure(_ name: String, in line: String) -> Int? {
        for field in line.split(separator: " ") where field.hasPrefix("\(name)=") {
            return Int(field.dropFirst(name.count + 1))
        }
        return nil
    }
}

/// Where host bytes end up, and a way to make applying them cost what a draw
/// costs.
private final class Screen: @unchecked Sendable {

    private let lock = NSLock()
    private var bytes = Data()
    private var hold: TimeInterval = 0

    /// Makes the next write hold the thread it is called on for `seconds`, which
    /// is what drawing a hundred-column terminal does to the main thread.
    func holdTheThread(for seconds: TimeInterval) {
        lock.lock()
        hold = seconds
        lock.unlock()
    }

    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        let wait = hold
        hold = 0
        lock.unlock()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    func waitFor(_ text: String, seconds: TimeInterval) async -> Bool {
        let needle = Data(text.utf8)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let found = bytes.range(of: needle) != nil
            lock.unlock()
            if found { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

/// The server's half of a mosh session, on the loopback, in one thread.
///
/// Small on purpose: it answers every datagram it can open, delivers what it has
/// been told to deliver, and records what the client said. It is not a model of
/// `mosh-server` — the lab is where a real one is asked — and the two things it
/// has that the lab cannot give are a cue (`deliver`, `goodbye`) and a stopwatch
/// on the client's acknowledgements.
private final class FakeMoshServer: @unchecked Sendable {

    enum Behaviour {
        /// Opens what arrives and answers in the protocol.
        case speakMosh
        /// Answers from the right address with bytes that will not open under
        /// the key.
        case gibberish
    }

    enum Failure: Error { case cannotOpen, cannotBind }

    let port: UInt16

    private let descriptor: Int32
    private let crypto: MoshCrypto
    private let behaviour: Behaviour
    private let assembly = MoshFragmentAssembly()
    /// One for the whole session, which is not a detail: the id is what tells a
    /// retransmission from a new instruction, and a fresh fragmenter per reply
    /// numbers them all 0 — so the client's assembly takes the first and drops
    /// every one after it as already delivered. Found by this suite on
    /// 29/10/2026, in the shape of a server that answered once and then went
    /// quiet.
    private let fragmenter = MoshFragmenter()
    private let lock = NSLock()

    private var running = true
    private var sequence: UInt64 = 1
    private var state: UInt64 = 0
    private var queued: [Data] = []
    private var answers: [(typed: Data, screen: Data)] = []
    private var leaving = false
    private var heard: [MoshInstruction] = []
    private var sentAt: [UInt64: MoshTime] = [:]
    private var ackedAt: [UInt64: MoshTime] = [:]

    init(printableKey: String, behaviour: Behaviour = .speakMosh) throws {
        self.crypto = try MoshCrypto(printableKey: printableKey)
        self.behaviour = behaviour

        // Everything through a local, because a closure that mentioned the
        // property would be capturing a half-built object.
        let opened = socket(AF_INET, SOCK_DGRAM, 0)
        guard opened >= 0 else { throw Failure.cannotOpen }

        var mine = sockaddr_in()
        mine.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        mine.sin_family = sa_family_t(AF_INET)
        mine.sin_port = 0
        mine.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &mine) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(opened, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(opened)
            throw Failure.cannotBind
        }

        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let asked = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(opened, $0, &length)
            }
        }
        guard asked == 0 else {
            close(opened)
            throw Failure.cannotBind
        }

        // So that the thread notices it has been stopped rather than sitting in
        // a read nothing will ever satisfy.
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(
            opened, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
        )

        descriptor = opened
        port = UInt16(bigEndian: named.sin_port)
    }

    func start() {
        let thread = Thread { [self] in serve() }
        thread.name = "fake-mosh-server"
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Hands these bytes to the client in the next frame, as a screen.
    func deliver(_ text: String) {
        lock.lock()
        queued.append(Data(text.utf8))
        lock.unlock()
    }

    /// Answers the datagram that carries these keystrokes with this screen,
    /// which is what a shell does: the frame rides back on the reply to the very
    /// packet that typed it, so a test of the round trip waits for one.
    func answer(_ screen: String, whenTyped typed: String) {
        lock.lock()
        answers.append((typed: Data(typed.utf8), screen: Data(screen.utf8)))
        lock.unlock()
    }

    /// Says "I am going away" from the next frame on.
    func goodbye() {
        lock.lock()
        leaving = true
        lock.unlock()
    }

    var instructionsHeard: [MoshInstruction] {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    /// How long the client took to acknowledge the state it was sent, or nil if
    /// it has not yet.
    func acknowledgementDelay(forState state: UInt64) -> MoshTime? {
        lock.lock()
        defer { lock.unlock() }
        guard let sent = sentAt[state], let acked = ackedAt[state] else { return nil }
        return acked - sent
    }

    // MARK: - The thread

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while keepGoing() {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(descriptor, &buffer, buffer.count, 0, address, &length)
                }
            }
            guard count > 0 else { continue }
            answer(Data(buffer[0..<count]), to: from)
        }
        close(descriptor)
    }

    private func keepGoing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func answer(_ datagram: Data, to client: sockaddr_in) {
        switch behaviour {
        case .gibberish:
            send(Data((0..<64).map { _ in UInt8.random(in: .min ... .max) }), to: client)
        case .speakMosh:
            guard let opened = crypto.open(datagram),
                  let packet = try? MoshPacket.decode(opened.plaintext)
            else { return }

            var instruction: MoshInstruction?
            if !packet.payload.isEmpty,
               let fragment = try? MoshFragment.decode(packet.payload),
               let payload = try? assembly.add(fragment) {
                instruction = try? MoshInstruction.decode(fragmentPayload: payload)
            }

            let reply = compose(answering: instruction)
            guard let sealed = try? seal(reply, replyingTo: packet.timestamp) else { return }
            send(sealed, to: client)
        }
    }

    private func compose(answering instruction: MoshInstruction?) -> MoshInstruction {
        lock.lock()
        defer { lock.unlock() }

        if let instruction {
            heard.append(instruction)
            if instruction.ackNumber != 0, ackedAt[instruction.ackNumber] == nil {
                ackedAt[instruction.ackNumber] = Self.now()
            }
            for (index, answer) in answers.enumerated().reversed()
            where instruction.diff.range(of: answer.typed) != nil {
                queued.append(answer.screen)
                answers.remove(at: index)
            }
        }

        // What the client says it is holding, which is what a frame has to be
        // computed against if it is to be usable.
        let held = instruction?.ackNumber ?? 0

        var reply = MoshInstruction()
        reply.ackNumber = instruction?.newNumber ?? 0
        reply.oldNumber = held

        if leaving {
            reply.newNumber = MoshTransport.shutdownNumber
            return reply
        }
        if !queued.isEmpty {
            state = max(state, held) + 1
            reply.newNumber = state
            reply.diff = Self.hostDiff(queued.removeFirst())
            sentAt[state] = Self.now()
            return reply
        }
        // Nothing to show: an acknowledgement, which is also a heartbeat.
        reply.oldNumber = state
        reply.newNumber = state
        return reply
    }

    private func seal(_ instruction: MoshInstruction, replyingTo timestamp: Int) throws -> Data {
        let fragments = try fragmenter.fragments(of: instruction, budget: 1_200)
        let packet = MoshPacket(
            timestamp: Int(Self.now() % 65_536),
            timestampReply: timestamp,
            payload: fragments[0].encoded
        )

        lock.lock()
        let nonce = MoshNonce(sequence: sequence, toClient: true)
        sequence += 1
        lock.unlock()

        return try crypto.seal(nonce: nonce, plaintext: packet.encoded)
    }

    private func send(_ datagram: Data, to client: sockaddr_in) {
        var address = client
        datagram.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    /// A host diff, which is the one piece of the wire format the app never has
    /// to write: `Instruction` (field 1) holding `HostBytes` (field 2) holding
    /// the bytes themselves (field 4). The three field numbers are the ones
    /// ``MoshDiffs`` reads.
    private static func hostDiff(_ bytes: Data) -> Data {
        let hostBytes = ProtoWriter().bytes(4, bytes).data
        let instruction = ProtoWriter().bytes(2, hostBytes).data
        return ProtoWriter().bytes(1, instruction).data
    }

    private static func now() -> MoshTime {
        MoshTime(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
