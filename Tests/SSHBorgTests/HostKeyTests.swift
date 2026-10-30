// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import XCTest

@testable import SSHBorg

final class HostKeyTests: XCTestCase {

    // MARK: - Markers

    func testDefaultPortIsUnbracketed() {
        XCTAssertEqual(KnownHostsLine.marker(host: "example.com", port: 22), "example.com")
    }

    func testNonDefaultPortIsBracketed() {
        XCTAssertEqual(KnownHostsLine.marker(host: "example.com", port: 2222), "[example.com]:2222")
    }

    func testMarkerRoundTrip() {
        for port in [22, 2222, 65535] {
            let marker = KnownHostsLine.marker(host: "example.com", port: port)
            let parsed = KnownHostsLine.hostAndPort(fromMarker: marker)
            XCTAssertEqual(parsed?.host, "example.com")
            XCTAssertEqual(parsed?.port, port)
        }
    }

    func testMalformedMarkersAreRejected() {
        XCTAssertNil(KnownHostsLine.hostAndPort(fromMarker: "[example.com"))
        XCTAssertNil(KnownHostsLine.hostAndPort(fromMarker: "[example.com]"))
        XCTAssertNil(KnownHostsLine.hostAndPort(fromMarker: "[example.com]:notaport"))
        XCTAssertNil(KnownHostsLine.hostAndPort(fromMarker: "[]:22"))
        XCTAssertNil(KnownHostsLine.hostAndPort(fromMarker: ""))
    }

    // MARK: - Lines

    func testParseSplitsThreeFields() {
        let parsed = KnownHostsLine.parse("example.com ssh-ed25519 AAAAC3Nza")
        XCTAssertEqual(parsed?.marker, "example.com")
        XCTAssertEqual(parsed?.algorithm, "ssh-ed25519")
        XCTAssertEqual(parsed?.base64Key, "AAAAC3Nza")
    }

    func testParseIgnoresTrailingComment() {
        let parsed = KnownHostsLine.parse("example.com ssh-rsa AAAAB3N some comment")
        XCTAssertEqual(parsed?.base64Key, "AAAAB3N")
    }

    func testParseRejectsShortLines() {
        XCTAssertNil(KnownHostsLine.parse("example.com ssh-ed25519"))
        XCTAssertNil(KnownHostsLine.parse(""))
    }

    // MARK: - Matching

    func testMatchingKeyIsAccepted() {
        XCTAssertTrue(KnownHostsLine.matches(
            storedLine: "example.com ssh-ed25519 AAAAC3Nza",
            algorithm: "ssh-ed25519",
            base64Key: "AAAAC3Nza"
        ))
    }

    /// A changed key is the case that matters: it must never silently pass.
    func testChangedKeyIsRejected() {
        XCTAssertFalse(KnownHostsLine.matches(
            storedLine: "example.com ssh-ed25519 AAAAC3Nza",
            algorithm: "ssh-ed25519",
            base64Key: "AAAADIFFERENT"
        ))
    }

    func testSameKeyMaterialUnderADifferentAlgorithmIsRejected() {
        XCTAssertFalse(KnownHostsLine.matches(
            storedLine: "example.com ssh-ed25519 AAAAC3Nza",
            algorithm: "ssh-rsa",
            base64Key: "AAAAC3Nza"
        ))
    }

    /// The marker is deliberately not compared: SSHBorg stores one line per host
    /// record, so renaming a host or moving it to another port must not look
    /// like a key change.
    func testMarkerIsIgnoredWhenMatching() {
        XCTAssertTrue(KnownHostsLine.matches(
            storedLine: "[old-name]:2222 ssh-ed25519 AAAAC3Nza",
            algorithm: "ssh-ed25519",
            base64Key: "AAAAC3Nza"
        ))
    }

    func testGarbageStoredLineNeverMatches() {
        XCTAssertFalse(KnownHostsLine.matches(
            storedLine: "nonsense",
            algorithm: "ssh-ed25519",
            base64Key: "AAAAC3Nza"
        ))
    }

    // MARK: - Indexing

    func testIndexNormalisesBothMarkerForms() {
        let index = KnownHostsLine.indexByHostPort("""
        plain ssh-ed25519 AAAAONE
        [ported]:2222 ssh-rsa AAAATWO

        garbage
        """)

        XCTAssertEqual(index["plain:22"], "plain ssh-ed25519 AAAAONE")
        XCTAssertEqual(index["ported:2222"], "[ported]:2222 ssh-rsa AAAATWO")
        XCTAssertEqual(index.count, 2, "unparsable lines must be dropped")
    }

    func testIndexOfNilIsEmpty() {
        XCTAssertTrue(KnownHostsLine.indexByHostPort(nil).isEmpty)
    }

    // MARK: - Fingerprints

    /// OpenSSH prints `SHA256:` followed by unpadded base64 of the digest.
    /// This is the string the user compares against `ssh-keyscan`, so the
    /// formatting has to be exact.
    func testFingerprintFormat() {
        let fingerprint = KnownHostsLine.fingerprint(forKeyBlob: Data("test".utf8))

        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(fingerprint.contains("="), "OpenSSH strips base64 padding")

        let expected = Data(SHA256.hash(data: Data("test".utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(fingerprint, "SHA256:" + expected)
    }

    func testHostKeyInfoBuildsAStorableLine() {
        let info = HostKeyInfo(
            marker: "[example.com]:2222",
            algorithm: "ssh-ed25519",
            base64Key: "AAAAC3Nza",
            fingerprint: "SHA256:whatever"
        )
        XCTAssertEqual(info.knownHostsLine, "[example.com]:2222 ssh-ed25519 AAAAC3Nza")

        // What we store must be readable back by the matcher.
        XCTAssertTrue(KnownHostsLine.matches(
            storedLine: info.knownHostsLine,
            algorithm: info.algorithm,
            base64Key: info.base64Key
        ))
    }

    // MARK: - An entry holds a key per algorithm

    /// Any line of the entry is a match, not only the first. Android keeps the
    /// other algorithms when one is replaced, so such an entry arrives through a
    /// backup — and reading only its first line would turn the second algorithm
    /// into a "changed key" every time it was offered.
    func testAnyLineOfTheEntryIsAMatch() {
        let entry = "h ssh-ed25519 AAAAED\nh ecdsa-sha2-nistp256 AAAAEC"
        XCTAssertTrue(KnownHostsLine.matches(storedLine: entry, algorithm: "ssh-ed25519", base64Key: "AAAAED"))
        XCTAssertTrue(KnownHostsLine.matches(storedLine: entry, algorithm: "ecdsa-sha2-nistp256", base64Key: "AAAAEC"))
        XCTAssertFalse(KnownHostsLine.matches(storedLine: entry, algorithm: "ssh-ed25519", base64Key: "AAAAEC"),
                       "a key was matched against another algorithm's line")
        XCTAssertFalse(KnownHostsLine.matches(storedLine: entry, algorithm: "ssh-ed25519", base64Key: "OTHER"))
    }

    /// Accepting a key replaces that algorithm's line and keeps the others:
    /// accepting one key says nothing about them. Android's `KnownHosts.replacing`.
    func testAcceptingAKeyReplacesOnlyItsOwnAlgorithm() {
        let pinned = "h ssh-ed25519 OLD\nh ecdsa-sha2-nistp256 KEEP"
        let stored = KnownHostsLine.replacing(pinned: pinned, arriving: "h ssh-ed25519 NEW")
        XCTAssertEqual(
            Set(stored.split(separator: "\n").map(String.init)),
            ["h ecdsa-sha2-nistp256 KEEP", "h ssh-ed25519 NEW"]
        )
        XCTAssertEqual(KnownHostsLine.replacing(pinned: nil, arriving: "h ssh-ed25519 NEW"), "h ssh-ed25519 NEW")
        XCTAssertEqual(KnownHostsLine.replacing(pinned: "", arriving: "h ssh-ed25519 NEW"), "h ssh-ed25519 NEW")
    }

    /// A typed chain's hop keys are looked up by machine, and a machine with two
    /// algorithms keeps both lines rather than whichever came last.
    func testAHopWithTwoAlgorithmsKeepsBoth() {
        let blob = "edge ssh-ed25519 ED\n[mid]:2222 ssh-ed25519 MID\nedge ecdsa-sha2-nistp256 EC"
        let index = KnownHostsLine.indexByHostPort(blob)
        let edge = index["edge:22"] ?? ""
        XCTAssertTrue(KnownHostsLine.matches(storedLine: edge, algorithm: "ssh-ed25519", base64Key: "ED"))
        XCTAssertTrue(KnownHostsLine.matches(storedLine: edge, algorithm: "ecdsa-sha2-nistp256", base64Key: "EC"))
        XCTAssertEqual(index["mid:2222"], "[mid]:2222 ssh-ed25519 MID")
    }
}
