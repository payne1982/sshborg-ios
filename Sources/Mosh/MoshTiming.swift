// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Milliseconds from an arbitrary monotonic origin.
///
/// Never a wall clock: a session has to survive the device's idea of the time
/// changing, and on iOS it also has to survive being suspended, where the only
/// thing that can be trusted to move forward is the uptime.
typealias MoshTime = Int64

/// The round-trip estimate, and the two sixteen-bit timestamps every packet
/// carries.
///
/// Mosh measures the round trip with the timestamps *inside* the encryption
/// rather than with the sequence numbers, which is what lets it keep measuring
/// across a change of address. The estimator is the ordinary Jacobson one with
/// mosh's own starting values: a pessimistic first guess that the first real
/// measurement replaces outright.
///
/// The reply field is the part that is easy to get wrong. It is not the
/// timestamp we received: it is that timestamp **plus the time we sat on it**,
/// so the far end's subtraction measures the network and not our own scheduling
/// delay. It is also used once — after it has gone into a packet it is cleared,
/// and a packet with nothing to report carries ``MoshPacket/none``.
final class MoshTiming {

    private(set) var smoothedRoundTrip = 1000.0
    private(set) var roundTripVariation = 500.0

    private var measured = false
    private var savedTimestamp = MoshPacket.none
    private var savedAt: MoshTime = 0

    /// Retransmission timeout: how long to wait before assuming a state did not
    /// arrive.
    var retransmitTimeout: MoshTime {
        let value = (smoothedRoundTrip + 4 * roundTripVariation).rounded(.up)
        return MoshTime(value).clamped(to: Self.minimumTimeout...Self.maximumTimeout)
    }

    /// The gap between frames we are willing to send: half the round trip,
    /// within reason.
    var sendInterval: MoshTime {
        let value = (smoothedRoundTrip / 2).rounded(.up)
        return MoshTime(value).clamped(to: Self.minimumInterval...Self.maximumInterval)
    }

    /// For every packet accepted as fresh: their clock to echo back, and our
    /// own measurement.
    func onPacketReceived(timestamp: Int, reply: Int, now: MoshTime) {
        if timestamp != MoshPacket.none {
            savedTimestamp = timestamp
            savedAt = now
        }
        guard reply != MoshPacket.none else { return }

        let measurement = Double(Self.difference(Self.stamp(now), reply))
        // A reply from before a suspend, or from a process that was stopped,
        // says nothing about the network — and on iOS that is not a corner case
        // but the ordinary way a session comes back. Mosh throws away anything
        // implausible rather than let it poison the estimate.
        guard measurement < Double(Self.implausibleRoundTrip) else { return }

        if measured {
            roundTripVariation = (1 - Self.beta) * roundTripVariation
                + Self.beta * abs(smoothedRoundTrip - measurement)
            smoothedRoundTrip = (1 - Self.alpha) * smoothedRoundTrip + Self.alpha * measurement
        } else {
            smoothedRoundTrip = measurement
            roundTripVariation = measurement / 2
            measured = true
        }
    }

    /// What to put in the reply field of a packet going out now, consuming it:
    /// a second packet in the same burst carries nothing, as mosh's does.
    func timestampReply(now: MoshTime) -> Int {
        guard savedTimestamp != MoshPacket.none, now - savedAt < Self.heldTooLong else {
            return MoshPacket.none
        }
        let reply = (savedTimestamp + Int(now - savedAt)) & 0xFFFF
        savedTimestamp = MoshPacket.none
        savedAt = 0
        return reply
    }

    /// Our millisecond clock as it goes on the wire.
    static func stamp(_ now: MoshTime) -> Int { Int(now & 0xFFFF) }

    /// The gap between two wire timestamps, taking the sixteen-bit wrap into
    /// account.
    static func difference(_ newer: Int, _ older: Int) -> Int { (newer - older) & 0xFFFF }

    static let minimumInterval: MoshTime = 20
    static let maximumInterval: MoshTime = 250
    static let minimumTimeout: MoshTime = 50
    static let maximumTimeout: MoshTime = 1000

    private static let alpha = 1.0 / 8.0
    private static let beta = 1.0 / 4.0
    private static let implausibleRoundTrip = 5000
    private static let heldTooLong: MoshTime = 1000
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
