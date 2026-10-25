// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest

@testable import SSHBorg

/// The lab: a real `mosh-server`, started by hand, answering a datagram we
/// built ourselves.
///
/// This is the gate of phases 1 to 3 together, and it is the only test here
/// whose answer cannot be arranged by agreement with itself. Everything else in
/// the mosh suite proves that our encoder and our decoder understand each
/// other; this proves that **mosh** understands our encoder — the nonce, the
/// cipher, the timestamps, the fragment header, the protobuf field numbers and
/// the zlib wrapper all at once. If the server answers, they are right. If it
/// does not, one of them is wrong and no amount of internal consistency would
/// have said so.
///
/// It skips itself when there is no server, the way the SSH integration tests
/// do. The recipe — where to start one, and how to hand its port and key over
/// without putting either in a command line in the clear — is in the local
/// runbook, BUILD-MAC.md. Three variables, all required:
///
/// ```
/// SSHBORG_MOSH_HOST=… SSHBORG_MOSH_PORT=… SSHBORG_MOSH_KEY_B64=…
/// ```
///
/// The key travels base64-encoded for the same reason the test password does:
/// it is a session secret. The host is not defaulted, because a machine name
/// is not something this repository should carry.
///
/// ⚠️ **One server, one test.** A `mosh-server` remembers the highest sequence
/// number it has seen, and every test here starts a transport that counts from
/// one — so the second test to use the same server is refused as a replay and
/// gets silence, which looks exactly like a blocked path. Measured on
/// 25/10/2026: the roaming test failed with `noAnswer` after its two
/// predecessors had each used the same server, and passed on its own against a
/// fresh one. So each test is run with `-only-testing` naming it alone, against
/// a server started for it. It is the same hazard Android's comment on
/// `MoshReplayFilter` describes from the other side, and it goes away in phase
/// 6, where the bootstrap starts a server per session.
final class MoshLabIntegrationTests: XCTestCase {

    private struct Lab {
        let host: String
        let port: UInt16
        let printableKey: String
    }

    private func lab() throws -> Lab {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SSHBORG_MOSH_HOST"], !host.isEmpty,
              let rawPort = environment["SSHBORG_MOSH_PORT"], let port = UInt16(rawPort),
              let encodedKey = environment["SSHBORG_MOSH_KEY_B64"],
              let keyData = Data(base64Encoded: encodedKey),
              let printableKey = String(data: keyData, encoding: .utf8)
        else {
            throw XCTSkip(
                "No mosh lab. Start one as BUILD-MAC.md says and pass SSHBORG_MOSH_HOST, "
                + "SSHBORG_MOSH_PORT and SSHBORG_MOSH_KEY_B64."
            )
        }
        return Lab(
            host: host,
            port: port,
            printableKey: printableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The whole handshake, in the order the layers sit in:
    ///
    /// an instruction that says we have done nothing and hold nothing, deflated,
    /// fragmented, wrapped in a packet with a timestamp, sealed under sequence
    /// number one, and sent. What comes back has to open under the same key with
    /// the direction bit the other way, parse as a packet, assemble as a
    /// fragment, inflate, parse as an instruction of protocol version 2, and
    /// carry the screen the shell has just drawn.
    func testTheServerAnswersOurFirstDatagram() throws {
        let lab = try lab()
        let crypto = try MoshCrypto(printableKey: lab.printableKey)
        let sequence = MoshSequence()

        // What is left for a fragment after mosh's 1280-byte *IP* datagram has
        // paid for the IPv4 and UDP headers (28), the nonce (8), the tag (16)
        // and the two timestamps (4). Getting this wrong by 28 bytes is the
        // mistake Android made and the wire-format document records.
        let budget = 1280 - 28 - MoshCrypto.nonceWireLength - MoshOCB.tagLength - 4

        var instruction = MoshInstruction()
        instruction.oldNumber = 0
        instruction.newNumber = 0
        instruction.ackNumber = 0
        instruction.throwawayNumber = 0

        let fragments = try MoshFragmenter().fragments(of: instruction, budget: budget)
        XCTAssertEqual(fragments.count, 1, "an empty instruction took more than one fragment")

        let packet = MoshPacket(
            timestamp: Int(DispatchTime.now().uptimeNanoseconds / 1_000_000 % 65536),
            timestampReply: MoshPacket.none,
            payload: fragments[0].encoded
        )
        let datagram = try crypto.seal(
            nonce: MoshNonce(sequence: try sequence.next(), toClient: false),
            plaintext: packet.encoded
        )

        // The first answer, and then as many as come in the next few seconds.
        //
        // Measured on 25/10/2026: the server's *first* reply is an empty frame
        // — it has our address and our timestamp, and nothing to show yet,
        // because the shell has not finished drawing its prompt in the
        // millisecond it took to answer. The screen arrives in a frame after
        // that. A gate that read one datagram and asserted on it would have
        // called a working protocol broken, which is how this was found.
        let session = try UDP.Session(host: lab.host, port: lab.port, probe: datagram, timeout: 5)

        // 1. It opened. Everything below this line is only reachable because the
        //    nonce, the key and the cipher were all right.
        let opened = try XCTUnwrap(
            crypto.open(session.firstAnswer),
            "the server answered \(session.firstAnswer.count) bytes that would not open"
        )
        XCTAssertTrue(opened.nonce.toClient, "the server's datagram was not addressed to a client")
        XCTAssertTrue(
            try MoshReplayFilter().accept(opened.nonce),
            "the first datagram of a session was refused as a replay"
        )

        // 2. The packet, and the proof that it read our timestamp: mosh echoes
        //    it back in the reply field.
        let replyPacket = try MoshPacket.decode(opened.plaintext)
        XCTAssertNotEqual(replyPacket.timestamp, MoshPacket.none)
        // Not equality: mosh echoes the timestamp it was given *plus* the time
        // it held it (`network.cc`, where `outgoing_timestamp_reply` is
        // `saved_timestamp + elapsed`), so what proves it read ours is that the
        // answer is ours plus a small delay rather than anything else.
        let echoed = (replyPacket.timestampReply &- packet.timestamp) & 0xFFFF
        XCTAssertLessThan(
            echoed, 1000,
            "the server echoed \(replyPacket.timestampReply) for our \(packet.timestamp), "
            + "so it did not read our packet the way we wrote it"
        )

        // 3. Every frame it sends in the next eight seconds, through all four
        //    layers — fragment, assembly, zlib, protobuf — and a command typed
        //    into the shell, because of what the first two runs of this gate
        //    measured.
        //
        //    The server's own state 0 already contains the prompt it drew before
        //    anybody connected, and we acknowledged state 0: so the difference
        //    between what it holds and what it believes we hold was *nothing*,
        //    quite correctly, and it had nothing to send for ever. Typing gives
        //    it a state we demonstrably do not have.
        //
        //    And the frame that comes straight back carries only the echo of the
        //    line, not its output, so a gate that stopped at the first frame
        //    with anything in it stopped one frame too early. Hence a marker: a
        //    command whose output cannot be confused with anything else, and a
        //    loop that reads until it arrives.
        let marker = "MOSHLAB-7F3A"
        let assembly = MoshFragmentAssembly()
        let stream = MoshUserStream()
        var output = Data()
        var summaries: [String] = []
        var held: UInt64 = 0
        var typed = false
        var pending = [session.firstAnswer]
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            if pending.isEmpty {
                guard let more = try? session.receive(timeout: 1) else {
                    if output.contains(Data(marker.utf8)) { break }
                    continue
                }
                pending.append(more)
            }
            let answer = pending.removeFirst()
            guard let opened = crypto.open(answer) else { continue }
            let decodedPacket = try MoshPacket.decode(opened.plaintext)
            guard !decodedPacket.payload.isEmpty else {
                summaries.append("empty")
                continue
            }
            let fragment = try MoshFragment.decode(decodedPacket.payload)
            guard let payload = assembly.add(fragment) else { continue }

            let instruction = try MoshInstruction.decode(fragmentPayload: payload)
            XCTAssertEqual(instruction.version, MoshInstruction.protocolVersion)
            held = max(held, instruction.newNumber)
            let drawn = try MoshDiffs.decodeHostDiff(instruction.diff)
            for action in drawn {
                if case .hostBytes(let data) = action { output.append(data) }
            }
            summaries.append(
                "\(instruction.oldNumber)=>\(instruction.newNumber) ack=\(instruction.ackNumber) "
                + "diff=\(instruction.diff.count)B drawn=\(drawn.count) out=\(output.count)B"
            )
            if output.contains(Data(marker.utf8)) { break }

            if !typed {
                typed = true
                stream.type(Data("echo \(marker)\r".utf8))
                var typing = MoshInstruction()
                typing.newNumber = stream.count
                typing.ackNumber = held
                typing.diff = try stream.diff(from: 0)
                for piece in try MoshFragmenter().fragments(of: typing, budget: budget) {
                    try session.send(
                        crypto.seal(
                            nonce: MoshNonce(sequence: try sequence.next(), toClient: false),
                            plaintext: MoshPacket(
                                timestamp: Int(DispatchTime.now().uptimeNanoseconds / 1_000_000 % 65536),
                                timestampReply: decodedPacket.timestamp,
                                payload: piece.encoded
                            ).encoded
                        )
                    )
                }
            }
        }

        let report = summaries.joined(separator: " | ")
        XCTAssertEqual(assembly.conflictingFragments, 0, "it reused a fragment id for other bytes")

        // 4. And the screen, which is the point of the whole protocol: a command
        //    typed here reached a shell on another machine over UDP, and its
        //    output came back through every layer of this.
        XCTAssertTrue(
            output.contains(Data(marker.utf8)),
            "the marker never came back. Frames: \(report). "
            + "What did: \(output.map { String(format: "%02X", $0) }.joined())"
        )
    }

    /// **The roaming, which is the whole reason the feature exists.**
    ///
    /// A session is opened, a command is run, and then the socket is thrown away
    /// and a new one opened — a new local port, which is what a change of
    /// network looks like from here — while the same ``MoshTransport`` carries
    /// on with the same key and the same sequence counter. Then another command.
    ///
    /// If the second one answers, three things are true at once: the sequence
    /// counter survived the socket (or the server would have refused us as a
    /// replay, which is the first thing Android's lab got wrong), the server
    /// adopted the address it heard from, and the session on the far end never
    /// noticed. That is phase 4's gate about the local port and the one about
    /// resynchronising, which are the same event from the client's side.
    func testTheSessionFollowsUsToANewLocalPort() throws {
        let lab = try lab()
        let collector = Collector()
        let transport = try MoshTransport(
            crypto: MoshCrypto(printableKey: lab.printableKey), listener: collector
        )
        // The lab's server binds `0.0.0.0`, so the socket that answers is IPv4
        // and the budget is the larger of the two.
        transport.useMTU(forIPv4: true)

        // Opening: the first tick is the datagram that introduces us, and the
        // answer is what tells the transport the far end is there.
        var socket = try open(transport: transport, lab: lab)
        try transport.onDatagram(socket.firstAnswer, now: Self.now())

        transport.type(Data("echo LAB-ONE\r".utf8))
        try pump(transport, through: socket, until: { collector.sawText("LAB-ONE") }, seconds: 8)
        XCTAssertTrue(collector.sawText("LAB-ONE"), "the first command never answered")

        // The network changes underneath: a new local port, nothing else.
        let before = transport.receivedDatagrams
        transport.type(Data("echo LAB-TWO\r".utf8))
        socket = try open(transport: transport, lab: lab)
        try transport.onDatagram(socket.firstAnswer, now: Self.now())

        try pump(transport, through: socket, until: { collector.sawText("LAB-TWO") }, seconds: 8)

        XCTAssertTrue(
            collector.sawText("LAB-TWO"),
            "the session did not follow us to a new local port. Received "
            + "\(transport.receivedDatagrams - before) datagrams after the hop, "
            + "stray \(transport.strayDatagrams), stale \(transport.staleFrames), "
            + "round trip \(Int(transport.timing.smoothedRoundTrip)) ms"
        )
        XCTAssertEqual(transport.conflictingFragments, 0)
        XCTAssertFalse(transport.counterpartyShutdown, "the far end gave up on us")
    }

    /// The third step of phase 5's gate: **a resize propagates both ways.**
    ///
    /// The width goes up as a user action inside the state diff, the far end
    /// resizes the pty, and the shell is asked what it thinks — `tput cols`
    /// reads the terminal it is attached to, so the number that comes back is
    /// the server's answer and not ours. An unlikely width, so that finding it
    /// in the output cannot be a coincidence.
    func testAResizeReachesTheShellAndItsAnswerComesBack() throws {
        let lab = try lab()
        let collector = Collector()
        let transport = try MoshTransport(
            crypto: MoshCrypto(printableKey: lab.printableKey), listener: collector
        )
        transport.useMTU(forIPv4: true)

        let socket = try open(transport: transport, lab: lab)
        try transport.onDatagram(socket.firstAnswer, now: Self.now())

        transport.resize(width: 123, height: 37)
        transport.type(Data("tput cols\r".utf8))
        try pump(transport, through: socket, until: { collector.sawText("123") }, seconds: 8)

        XCTAssertTrue(
            collector.sawText("123"),
            "the shell never answered 123 columns. What came back: "
            + String(decoding: collector.output.suffix(400), as: UTF8.self).debugDescription
        )
    }

    /// Opens a socket with whatever the transport wants to send next, which is
    /// what a client does after a network change: there is always something to
    /// say, if only an acknowledgement.
    private func open(transport: MoshTransport, lab: Lab) throws -> UDP.Session {
        for _ in 0..<50 {
            if let datagram = try transport.tick(now: Self.now()).first {
                return try UDP.Session(
                    host: lab.host, port: lab.port, probe: datagram, timeout: 5
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw Failure.nothingToSend
    }

    /// The I/O loop the transport is written to be driven by: tick, send what it
    /// hands back, read what arrives, tick again. The real one belongs to the
    /// session and uses `Network.framework`; this is the same shape in twelve
    /// lines.
    private func pump(
        _ transport: MoshTransport,
        through socket: UDP.Session,
        until done: () -> Bool,
        seconds: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            for datagram in try transport.tick(now: Self.now()) {
                try socket.send(datagram)
            }
            if let answer = try? socket.receive(timeout: 0.2) {
                try transport.onDatagram(answer, now: Self.now())
            }
        }
    }

    private enum Failure: Error { case nothingToSend }

    /// Milliseconds of uptime, which is what the transport's clock is: never a
    /// wall clock, because a session has to survive the time changing.
    private static func now() -> MoshTime {
        MoshTime(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private final class Collector: MoshTransportListener {
        private(set) var output = Data()

        func onHostBytes(_ bytes: Data) { output.append(bytes) }

        func sawText(_ text: String) -> Bool { output.contains(Data(text.utf8)) }
    }

    /// A datagram under the wrong key must be ignored rather than answered,
    /// which is the other half of the same claim: the server is really
    /// authenticating us and not merely replying to whoever speaks.
    func testTheServerIgnoresADatagramUnderTheWrongKey() throws {
        let lab = try lab()
        let wrong = try MoshCrypto(key: Data(repeating: 0xAB, count: 16))

        let packet = MoshPacket(
            timestamp: 1,
            timestampReply: MoshPacket.none,
            payload: try MoshFragmenter()
                .fragments(of: MoshInstruction(), budget: 1224)[0]
                .encoded
        )
        let datagram = try wrong.seal(
            nonce: MoshNonce(sequence: 1, toClient: false), plaintext: packet.encoded
        )

        XCTAssertThrowsError(
            try UDP.exchange(host: lab.host, port: lab.port, payload: datagram, timeout: 2)
        ) {
            XCTAssertEqual($0 as? UDP.Failure, .noAnswer, "the server answered an unauthenticated packet")
        }
    }
}

/// One datagram out, one datagram in, with a timeout. Deliberately the smallest
/// thing that can ask the question — the socket the app will use is
/// `Network.framework` and belongs to the transport, which is phase 4.
///
/// It tries **every** address the name resolves to, and that is not
/// defensiveness: it is the first thing the lab taught. For UDP a `connect()`
/// proves nothing — it only records a peer — so the first address that accepts
/// one is not the first that answers. Measured on 25/10/2026: the development
/// host's name resolves to IPv6 before IPv4, `mosh-server` had bound `0.0.0.0`
/// and so was listening on IPv4 only, and the ICMPv6 port-unreachable came back
/// as an immediate `ECONNREFUSED` on `recv`. Three hundred milliseconds, not the
/// five seconds of a timeout, which is the tell.
///
/// The same trap is waiting for the real transport, where it is worse: a mosh
/// session is bound to the family it was born on, because `mosh-server -s`
/// listens on the one address the SSH connection arrived on. It is why Android
/// grew a per-host IPv4/IPv6 preference, and it has now arrived here in a lab
/// instead of in somebody's field report.
private enum UDP {

    enum Failure: Error, Equatable {
        case cannotResolve(String)
        case cannotSend
        case noAnswer
    }

    /// One datagram out, one in, and the socket closed again: enough for the
    /// question "does it answer at all".
    static func exchange(host: String, port: UInt16, payload: Data, timeout: TimeInterval) throws -> Data {
        try Session(host: host, port: port, probe: payload, timeout: timeout).firstAnswer
    }

    /// A socket that stays open, because mosh is a conversation: the first
    /// answer is an acknowledgement and the screen comes after it.
    final class Session {

        private let descriptor: Int32
        let firstAnswer: Data

        /// Sends `probe` to every address the name resolves to and keeps the
        /// socket belonging to the one that answers.
        init(host: String, port: UInt16, probe: Data, timeout: TimeInterval) throws {
            var failure = Failure.cannotResolve(host)
            for address in try UDP.resolve(host: host, port: port) {
                do {
                    let open = try UDP.attempt(address, payload: probe, timeout: timeout)
                    self.descriptor = open.descriptor
                    self.firstAnswer = open.answer
                    return
                } catch let caught as Failure {
                    failure = caught
                }
            }
            throw failure
        }

        deinit { close(descriptor) }

        func send(_ payload: Data) throws {
            let sent = payload.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress, payload.count, 0)
            }
            guard sent == payload.count else { throw Failure.cannotSend }
        }

        func receive(timeout: TimeInterval) throws -> Data {
            var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size)
            )
            var buffer = [UInt8](repeating: 0, count: 65535)
            let received = recv(descriptor, &buffer, buffer.count, 0)
            guard received > 0 else { throw Failure.noAnswer }
            return Data(buffer[0..<received])
        }
    }

    static func resolve(host: String, port: UInt16) throws -> [UnsafeMutablePointer<addrinfo>] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let list = resolved else {
            throw Failure.cannotResolve(host)
        }
        // Copied out rather than walked lazily, so the list can be freed here
        // and the caller cannot hold a pointer into it.
        var addresses: [UnsafeMutablePointer<addrinfo>] = []
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let address = candidate {
            let copy = UnsafeMutablePointer<addrinfo>.allocate(capacity: 1)
            copy.initialize(to: address.pointee)
            let socketAddress = UnsafeMutablePointer<sockaddr>.allocate(
                capacity: Int(address.pointee.ai_addrlen)
            )
            memcpy(socketAddress, address.pointee.ai_addr, Int(address.pointee.ai_addrlen))
            copy.pointee.ai_addr = socketAddress
            copy.pointee.ai_next = nil
            addresses.append(copy)
            candidate = address.pointee.ai_next
        }
        freeaddrinfo(list)
        return addresses
    }

    static func attempt(
        _ address: UnsafeMutablePointer<addrinfo>, payload: Data, timeout: TimeInterval
    ) throws -> (descriptor: Int32, answer: Data) {
        defer {
            address.pointee.ai_addr.deallocate()
            address.deallocate()
        }

        let descriptor = socket(
            address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol
        )
        guard descriptor >= 0 else { throw Failure.cannotSend }

        guard connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            close(descriptor)
            throw Failure.cannotSend
        }

        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size)
        )

        let sent = payload.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, payload.count, 0)
        }
        guard sent == payload.count else {
            close(descriptor)
            throw Failure.cannotSend
        }

        var buffer = [UInt8](repeating: 0, count: 65535)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 0 else {
            close(descriptor)
            throw Failure.noAnswer
        }
        return (descriptor, Data(buffer[0..<received]))
    }
}
