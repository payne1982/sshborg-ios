// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The outermost layer of a mosh datagram: `nonce[8] || OCB-AES-128(plaintext)`,
/// where the 16-byte tag is part of the ciphertext and there is no associated
/// data at all.
///
/// Translated from Android's `MoshCrypto`, which was written against mosh 1.4.0
/// and verified against a live `mosh-server` rather than inferred. The cipher
/// itself is ``MoshOCB``, and the vectors that say it is the same algorithm
/// mosh carries are in `MoshPrimitiveTests`.
///
/// Nothing here touches UIKit, SwiftTerm or the session: the whole protocol is
/// plain Swift so the test suite can drive it and so the lab harness runs the
/// same code the app runs.
final class MoshCrypto {

    static let keyLength = 16
    /// Eight bytes of the nonce travel; twelve reach the cipher.
    static let nonceWireLength = 8

    private let key: Data

    /// OCB's security argument degrades with the number of blocks encrypted
    /// under one key, and mosh kills the session at 2^47 rather than let it
    /// drift into the unsafe region. Both ends share the key, so the budget is
    /// shared too.
    private var blocksEncrypted: UInt64 = 0

    init(key: Data) throws {
        guard key.count == Self.keyLength else {
            throw MoshProtocolError.keyLength(key.count)
        }
        self.key = key
    }

    /// The key as `mosh-server` prints it on its `MOSH CONNECT` line: 22 base64
    /// characters with the padding left off, which is why it is put back.
    convenience init(printableKey: String) throws {
        let trimmed = printableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let padded = trimmed + String(repeating: "=", count: (4 - trimmed.count % 4) % 4)
        guard let key = Data(base64Encoded: padded) else {
            throw MoshProtocolError.keyNotBase64
        }
        try self.init(key: key)
    }

    /// What ``open(_:)`` recovered: the nonce as it travelled, and the
    /// plaintext under it.
    struct Opened: Equatable {
        let nonce: MoshNonce
        let plaintext: Data
    }

    func seal(nonce: MoshNonce, plaintext: Data) throws -> Data {
        blocksEncrypted += UInt64((plaintext.count + 15) / 16)
        guard blocksEncrypted >> 47 == 0 else {
            throw MoshProtocolError.blockBudgetExhausted
        }

        let sealed = try MoshOCB.seal(
            plaintext: plaintext,
            aad: Data(),
            key: key,
            nonce: nonce.full
        )

        var datagram = nonce.wire
        datagram.append(sealed)
        return datagram
    }

    /// `nil` for a datagram that is not one of ours: too short, or its tag does
    /// not check out.
    ///
    /// **Not an error, and so not a throw.** A stray or tampered packet is the
    /// ordinary case on a UDP port — the caller drops it, counts it and carries
    /// on, and there is nothing else it could do with a reason. Android throws
    /// here and catches it one layer up, which is the same decision spelled
    /// differently.
    func open(_ datagram: Data) -> Opened? {
        // Eight bytes of nonce and sixteen of tag have to be there before there
        // can be a message at all.
        guard datagram.count >= Self.nonceWireLength + MoshOCB.tagLength else { return nil }

        let nonce = MoshNonce(wire: datagram.prefix(Self.nonceWireLength))
        let body = Data(datagram.dropFirst(Self.nonceWireLength))

        // `try?` flattens the double optional, so this one binding covers both
        // "the library refused" and "the tag did not check out" — which is
        // right, because the caller does the same thing with either.
        guard let plaintext = try? MoshOCB.open(
            sealed: body, aad: Data(), key: key, nonce: nonce.full
        ) else { return nil }

        return Opened(nonce: nonce, plaintext: plaintext)
    }
}

/// The 64-bit value in front of every datagram: the top bit says which way the
/// packet is going, the rest is a sequence number.
///
/// Twelve bytes reach the cipher — four zero bytes and these eight — and only
/// the eight travel. That is mosh's layout, not a choice of ours.
struct MoshNonce: Equatable {

    static let directionToClient: UInt64 = 1 << 63
    static let sequenceMask: UInt64 = ~directionToClient

    let sequence: UInt64
    let toClient: Bool

    init(sequence: UInt64, toClient: Bool) {
        self.sequence = sequence & Self.sequenceMask
        self.toClient = toClient
    }

    init(wire: Data) {
        let value = wire.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.sequence = value & Self.sequenceMask
        self.toClient = value & Self.directionToClient != 0
    }

    var value: UInt64 {
        (toClient ? Self.directionToClient : 0) | (sequence & Self.sequenceMask)
    }

    /// The eight bytes that travel, big-endian.
    var wire: Data {
        var bytes = Data(count: 8)
        let value = self.value
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: value >> (56 - 8 * index))
        }
        return bytes
    }

    /// The twelve the cipher is given: four zero bytes, then the eight.
    var full: Data {
        var bytes = Data(count: 4)
        bytes.append(wire)
        return bytes
    }
}

/// The sequence numbers we put on the wire.
///
/// OCB with a repeated nonce is not merely weakened, it is forgeable, so this
/// counter exists to make repetition impossible rather than merely unlikely: it
/// only ever goes up, it is guarded by a lock, and it refuses to wrap. **It must
/// outlive the socket** — a new local port after a network change is still the
/// same key, so the count carries on from where it was — and on iOS it must
/// also outlive the app going to the background, which is the one case Android
/// never had to think about.
final class MoshSequence {

    private let lock = NSLock()
    private var value: UInt64

    init(start: UInt64 = 1) {
        self.value = start
    }

    func next() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        guard value < MoshNonce.sequenceMask else {
            throw MoshProtocolError.sequenceExhausted
        }
        defer { value += 1 }
        return value
    }
}

/// The receiving half of the same rule, as mosh has it (`network.cc:513-519`),
/// and it is security-sensitive in two ways that are easy to miss.
///
/// A packet carrying our *own* direction bit is our own traffic played back at
/// us and is refused outright. A packet whose sequence number is not ahead of
/// what we have already seen is still handed on — the state layer is idempotent
/// and will do the right thing with a duplicate — but it must not be allowed to
/// move the peer address or the clock, because that is what a replay would
/// otherwise achieve.
///
/// In the lab this is the first thing to get wrong: a second probe run that
/// restarts its counter is authenticated and parsed, and then answered to the
/// previous run's port.
final class MoshReplayFilter {

    private let weAreClient: Bool
    private var expected: UInt64 = 0

    init(weAreClient: Bool = true) {
        self.weAreClient = weAreClient
    }

    /// `true` when this packet may also update timing and the peer's address.
    func accept(_ nonce: MoshNonce) throws -> Bool {
        guard nonce.toClient == weAreClient else {
            throw MoshProtocolError.wrongDirection
        }
        guard nonce.sequence >= expected else { return false }
        expected = nonce.sequence + 1
        return true
    }
}

/// Anything malformed or out of budget in the protocol layers.
///
/// A datagram that simply did not authenticate is **not** in here: that is a
/// `nil` from ``MoshCrypto/open(_:)``, because it is the ordinary weather on a
/// UDP port rather than a condition anybody can act on.
enum MoshProtocolError: Error, Equatable {
    case keyLength(Int)
    case keyNotBase64
    /// 2^47 blocks encrypted under one key. The session ends; it does not
    /// quietly carry on into the region where OCB's argument stops holding.
    case blockBudgetExhausted
    case sequenceExhausted
    /// Our own direction bit came back at us.
    case wrongDirection

    // The framing and the protobuf, all of which mean "this is not a datagram
    // mosh would have sent".
    case packetWithoutTimestamps
    case fragmentWithoutHeader
    case noRoomForAFragment(Int)
    case varintPastTheEnd
    case varintTooLong
    case fieldDoesNotFit(Int)
    case fixedFieldPastTheEnd
    case unknownWireType(Int)
    /// Mosh treats a version it does not know as fatal rather than as
    /// something to negotiate, and so do we: the state numbering is the
    /// protocol.
    case protocolVersion(Int)

    // The user stream's own bookkeeping, both of which would be our bug and
    // not the peer's.
    case actionsAlreadyFreed(from: UInt64, freed: UInt64)
    case noSuchAction(from: UInt64, count: UInt64)
}
