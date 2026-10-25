// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The packet layer: the nonce as it travels, the counter that must never
/// repeat one, and the filter that refuses a replay.
///
/// All of it is pure, so none of it needs a server. What does need one is the
/// claim that this *is* mosh's format, and that is the lab's job — the gate
/// there is a datagram from a real `mosh-server` opening with these classes.
final class MoshCryptoTests: XCTestCase {

    /// Not a real session key: sixteen bytes that are easy to read in a hex
    /// dump when something is off by one.
    private let key = Data((0..<16).map { UInt8($0) })

    // MARK: - The nonce

    /// Mosh's layout, which is not ours to choose: the top bit is the
    /// direction, the other 63 are the sequence number, and the eight bytes
    /// travel big-endian.
    func testTheNonceIsEightBigEndianBytesWithTheDirectionOnTop() {
        let toServer = MoshNonce(sequence: 1, toClient: false)
        XCTAssertEqual(Array(toServer.wire), [0, 0, 0, 0, 0, 0, 0, 1])

        let toClient = MoshNonce(sequence: 1, toClient: true)
        XCTAssertEqual(Array(toClient.wire), [0x80, 0, 0, 0, 0, 0, 0, 1])

        let big = MoshNonce(sequence: 0x0102_0304_0506_07, toClient: false)
        XCTAssertEqual(Array(big.wire), [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
    }

    /// Twelve bytes reach the cipher and only eight travel, so the four zeroes
    /// in front are part of the format rather than padding we invented.
    func testTheCipherSeesTwelveBytes() {
        let nonce = MoshNonce(sequence: 0xFF, toClient: true)

        XCTAssertEqual(nonce.full.count, 12)
        XCTAssertEqual(Array(nonce.full.prefix(4)), [0, 0, 0, 0])
        XCTAssertEqual(Array(nonce.full.suffix(8)), Array(nonce.wire))
    }

    func testANonceSurvivesTheWireBothWays() {
        for sequence in [UInt64(0), 1, 2, 255, 65536, 1 << 40, MoshNonce.sequenceMask - 1] {
            for toClient in [true, false] {
                let original = MoshNonce(sequence: sequence, toClient: toClient)
                XCTAssertEqual(MoshNonce(wire: original.wire), original, "\(sequence) \(toClient)")
            }
        }
    }

    // MARK: - Sealing

    func testADatagramIsTheNonceThenTheSealedBody() throws {
        let crypto = try MoshCrypto(key: key)
        let nonce = MoshNonce(sequence: 7, toClient: false)
        let plaintext = Data("hello".utf8)

        let datagram = try crypto.seal(nonce: nonce, plaintext: plaintext)

        XCTAssertEqual(Array(datagram.prefix(8)), Array(nonce.wire))
        // Nonce, body, tag — and nothing else: mosh sends no associated data.
        XCTAssertEqual(datagram.count, 8 + plaintext.count + MoshOCB.tagLength)
    }

    func testWhatWeSealWeCanOpen() throws {
        let crypto = try MoshCrypto(key: key)

        for length in [0, 1, 15, 16, 17, 1200] {
            let plaintext = Data((0..<length).map { UInt8($0 % 251) })
            let nonce = MoshNonce(sequence: UInt64(length) + 1, toClient: false)

            let datagram = try crypto.seal(nonce: nonce, plaintext: plaintext)
            let opened = crypto.open(datagram)

            XCTAssertEqual(opened?.plaintext, plaintext, "length \(length)")
            XCTAssertEqual(opened?.nonce, nonce, "length \(length)")
        }
    }

    /// The nonce travels in the clear and is the only thing that does, so it had
    /// better be authenticated by the tag — which it is, because it *is* the
    /// cipher's nonce. Editing it in flight must not produce a readable packet.
    func testEditingTheNonceInFlightBreaksTheDatagram() throws {
        let crypto = try MoshCrypto(key: key)
        var datagram = try crypto.seal(
            nonce: MoshNonce(sequence: 9, toClient: false), plaintext: Data("hello".utf8)
        )

        datagram[7] ^= 0x01
        XCTAssertNil(crypto.open(datagram))
    }

    func testRubbishIsRefusedRatherThanCrashing() throws {
        let crypto = try MoshCrypto(key: key)

        XCTAssertNil(crypto.open(Data()))
        XCTAssertNil(crypto.open(Data(count: 8)), "a nonce and no tag is not a datagram")
        XCTAssertNil(crypto.open(Data(count: 23)), "one byte short of nonce plus tag")
        XCTAssertNil(crypto.open(Data(count: 24)), "the right length, and random")
        XCTAssertNil(crypto.open(Data(repeating: 0xFF, count: 400)))
    }

    func testTheKeyIsSixteenBytesOrItIsNotAKey() {
        XCTAssertThrowsError(try MoshCrypto(key: Data(count: 15))) {
            XCTAssertEqual($0 as? MoshProtocolError, .keyLength(15))
        }
        XCTAssertThrowsError(try MoshCrypto(key: Data())) {
            XCTAssertEqual($0 as? MoshProtocolError, .keyLength(0))
        }
    }

    /// `mosh-server` prints 22 base64 characters with the padding left off,
    /// measured against mosh 1.4.0's own output on 25/10/2026.
    func testThePrintableKeyIsReadWithItsPaddingPutBack() throws {
        let crypto = try MoshCrypto(printableKey: "AAECAwQFBgcICQoLDA0ODw")
        let datagram = try crypto.seal(
            nonce: MoshNonce(sequence: 1, toClient: false), plaintext: Data("x".utf8)
        )

        // The same sixteen bytes as `key`, so the two agree about the session.
        let other = try MoshCrypto(key: key)
        XCTAssertEqual(other.open(datagram)?.plaintext, Data("x".utf8))
    }

    func testAKeyThatIsNotBase64IsRefused() {
        XCTAssertThrowsError(try MoshCrypto(printableKey: "not a key at all!!!!!!")) {
            XCTAssertEqual($0 as? MoshProtocolError, .keyNotBase64)
        }
    }

    // MARK: - The counter

    func testTheCounterOnlyEverGoesUp() throws {
        let sequence = MoshSequence()

        XCTAssertEqual(try sequence.next(), 1)
        XCTAssertEqual(try sequence.next(), 2)
        XCTAssertEqual(try sequence.next(), 3)
    }

    /// A repeated nonce does not weaken OCB, it makes forgery possible, so
    /// running out is a refusal and not a wrap.
    func testTheCounterRefusesToWrap() {
        let sequence = MoshSequence(start: MoshNonce.sequenceMask - 1)

        XCTAssertEqual(try? sequence.next(), MoshNonce.sequenceMask - 1)
        XCTAssertThrowsError(try sequence.next()) {
            XCTAssertEqual($0 as? MoshProtocolError, .sequenceExhausted)
        }
    }

    /// Threads, because the counter is read from the protocol loop and from
    /// whoever is typing, and two of them getting the same number is the one
    /// failure that cannot be recovered from.
    func testTheCounterNeverHandsOutTheSameNumberTwice() {
        let sequence = MoshSequence()
        let lock = NSLock()
        var handed: [UInt64] = []

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            if let value = try? sequence.next() {
                lock.lock()
                handed.append(value)
                lock.unlock()
            }
        }

        XCTAssertEqual(handed.count, 500)
        XCTAssertEqual(Set(handed).count, 500, "a number was handed out twice")
    }

    // MARK: - The replay filter

    func testAPacketAheadOfWhatWeHaveSeenMayMoveTheClock() throws {
        let filter = MoshReplayFilter()

        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 5, toClient: true)))
        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 6, toClient: true)))
        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 99, toClient: true)))
    }

    /// A duplicate is handed on — the state layer is idempotent — but it must
    /// not move the peer's address or the clock, because that is exactly what a
    /// replay would otherwise achieve.
    func testADuplicateIsAcceptedAsDataAndRefusedAsEvidence() throws {
        let filter = MoshReplayFilter()

        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 10, toClient: true)))
        XCTAssertFalse(try filter.accept(MoshNonce(sequence: 10, toClient: true)))
        XCTAssertFalse(try filter.accept(MoshNonce(sequence: 3, toClient: true)))
        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 11, toClient: true)))
    }

    /// Our own direction bit coming back at us is our own traffic played back,
    /// and there is no innocent reason for it.
    func testOurOwnTrafficPlayedBackIsRefusedOutright() {
        let filter = MoshReplayFilter()

        XCTAssertThrowsError(try filter.accept(MoshNonce(sequence: 1, toClient: false))) {
            XCTAssertEqual($0 as? MoshProtocolError, .wrongDirection)
        }
    }

    /// The server's half of the same filter, which is what the lab harness is
    /// when it stands in for one.
    func testTheServerSideFilterWantsTheOtherDirection() throws {
        let filter = MoshReplayFilter(weAreClient: false)

        XCTAssertTrue(try filter.accept(MoshNonce(sequence: 1, toClient: false)))
        XCTAssertThrowsError(try filter.accept(MoshNonce(sequence: 2, toClient: true)))
    }
}
