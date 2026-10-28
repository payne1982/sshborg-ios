// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The local ports: which one sends, which ones are read, and when they go.
///
/// None of this needs a server — a UDP socket to an address nobody answers is
/// still a socket, and what is being checked is our own bookkeeping. What needs
/// a server is that a datagram gets there and the answer comes back, and that is
/// the lab's.
final class MoshSocketTests: XCTestCase {

    /// Somewhere nothing will answer: the documentation range, which is reserved
    /// for exactly this and routed nowhere.
    private let nowhere = MoshSocket.Peer(host: "192.0.2.1", port: 60001)

    func testItOpensOnePortAndThenSendsFromTheNewest() async {
        let socket = MoshSocket(peer: nowhere)
        await socket.start()

        var ports = await socket.openPorts
        var hops = await socket.hops
        XCTAssertEqual(ports, 1)
        XCTAssertEqual(hops, 0)

        await socket.hop()

        ports = await socket.openPorts
        hops = await socket.hops
        XCTAssertEqual(hops, 1)
        XCTAssertEqual(ports, 2, "the retired port was closed instead of being left readable")

        await socket.close()
    }

    /// A retired port is kept **readable**, and that is not tidiness: the server
    /// does not know about the new port until a packet from it arrives, so what
    /// it is sending at that moment is still addressed to the old one.
    func testARetiredPortIsKeptUntilItsGraceIsUp() async {
        let socket = MoshSocket(peer: nowhere, retiredGrace: 0.2)
        await socket.start()

        await socket.hop()
        var ports = await socket.openPorts
        XCTAssertEqual(ports, 2)

        try? await Task.sleep(nanoseconds: 300_000_000)
        await socket.prune()

        ports = await socket.openPorts
        XCTAssertEqual(ports, 1, "the retired port outstayed its grace")

        await socket.close()
    }

    /// Nine, as in mosh: a session hopping faster than the grace period must not
    /// be able to accumulate ports, whatever the clock says.
    func testTheNumberOfPortsHasACeilingWhateverTheClockSays() async {
        let socket = MoshSocket(peer: nowhere, retiredGrace: 600)
        await socket.start()

        for _ in 0..<20 { await socket.hop() }

        let ports = await socket.openPorts
        let hops = await socket.hops
        XCTAssertEqual(hops, 20)
        XCTAssertLessThanOrEqual(ports, MoshSocket.maximumPorts)
        XCTAssertGreaterThan(ports, 1, "it kept only the newest and threw away the answers in flight")

        await socket.close()
    }

    func testClosingTakesEveryPortWithItAndEndsTheStream() async {
        let socket = MoshSocket(peer: nowhere)
        await socket.start()
        await socket.hop()

        await socket.close()

        let ports = await socket.openPorts
        XCTAssertEqual(ports, 0)
        // The stream is finished, so a consumer sees the end rather than waiting
        // for a datagram that cannot come.
        var arrived = 0
        for await _ in socket.arrivals { arrived += 1 }
        XCTAssertEqual(arrived, 0)
    }

    /// Sending to a port nobody is listening on is not an error here: the
    /// datagram leaves, and whether anything answers is the protocol's problem.
    /// What must not happen is a throw or a hang.
    func testSendingIntoNowhereIsNotAFailureOfOurs() async {
        let socket = MoshSocket(peer: nowhere)
        await socket.start()

        await socket.send(Data(repeating: 0x41, count: 64))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let refused = await socket.refusedSends
        XCTAssertEqual(refused, 0, "a datagram into the void was counted as a refusal")

        await socket.close()
    }

    /// Nothing happens after `close`, which is what lets a session be closed
    /// from the main thread while its loop is still coming round.
    func testNothingHappensAfterClosing() async {
        let socket = MoshSocket(peer: nowhere)
        await socket.start()
        await socket.close()

        await socket.send(Data([1, 2, 3]))
        await socket.hop()
        await socket.start()

        let ports = await socket.openPorts
        let hops = await socket.hops
        XCTAssertEqual(ports, 0)
        XCTAssertEqual(hops, 0)
    }
}
