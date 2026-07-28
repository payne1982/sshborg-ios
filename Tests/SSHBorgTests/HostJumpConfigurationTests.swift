// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The jump-host configuration a host carries. These fields are plain strings in
/// the schema and travel verbatim in the shared backup, so they can arrive
/// hand-edited or written by the Android app.
final class HostJumpConfigurationTests: XCTestCase {

    private func host(_ configure: (inout Host) -> Void = { _ in }) -> Host {
        var host = Host(label: "h", hostname: "example.com", username: "u")
        configure(&host)
        return host
    }

    // MARK: - ID list

    func testParsesIDListInOrder() {
        XCTAssertEqual(Host.parseIDList("3,1,2"), [3, 1, 2])
    }

    func testToleratesSpacesAndJunk() {
        XCTAssertEqual(Host.parseIDList(" 3 , 1 "), [3, 1])
        XCTAssertEqual(Host.parseIDList("3,notanid,1"), [3, 1])
    }

    func testEmptyIDListIsNoHops() {
        XCTAssertTrue(Host.parseIDList(nil).isEmpty)
        XCTAssertTrue(Host.parseIDList("").isEmpty)
    }

    func testFormatsIDList() {
        XCTAssertEqual(Host.formatIDList([3, 1, 2]), "3,1,2")
    }

    /// A row the user added but never filled in carries the sentinel 0. Storing
    /// it would mean a hop pointing at no host.
    func testFormatDropsUnfilledRows() {
        XCTAssertEqual(Host.formatIDList([3, 0, 2]), "3,2")
        XCTAssertNil(Host.formatIDList([0, 0]))
        XCTAssertNil(Host.formatIDList([]))
    }

    func testIDListRoundTrip() {
        let ids: [Int64] = [7, 4, 9]
        let stored = Host.formatIDList(ids)
        XCTAssertEqual(Host.parseIDList(stored), ids)
    }

    func testHostExposesItsHops() {
        let configured = host { $0.jumpHostIdList = "5,6" }
        XCTAssertEqual(configured.jumpHostIDs, [5, 6])
    }

    // MARK: - Selectability as a hop

    /// A hop authenticates with nobody at the keyboard, so it must already hold
    /// a credential.
    func testHostWithAKeyCanBeAHop() {
        XCTAssertTrue(host { $0.keyId = 1 }.canBeJumpHost)
    }

    func testHostWithAPasswordCanBeAHop() {
        XCTAssertTrue(host { $0.password = "secret" }.canBeJumpHost)
    }

    func testHostWithAnEncryptedPasswordCanBeAHop() {
        XCTAssertTrue(host { $0.encryptedPassword = "blob" }.canBeJumpHost)
    }

    func testHostWithNoCredentialCannotBeAHop() {
        XCTAssertFalse(host().canBeJumpHost)
        XCTAssertFalse(host { $0.password = "" }.canBeJumpHost)
        XCTAssertFalse(host { $0.encryptedPassword = "" }.canBeJumpHost)
    }

    // MARK: - Modes

    func testJumpModeFallsBackToSimple() {
        XCTAssertEqual(host { $0.jumpMode = "host_list" }.parsedJumpMode, .hostList)
        XCTAssertEqual(host { $0.jumpMode = "nonsense" }.parsedJumpMode, .simple)
    }

    func testSFTPStartModeFallsBackToLast() {
        XCTAssertEqual(host { $0.sftpStartMode = "fixed" }.parsedSFTPStartMode, .fixed)
        XCTAssertEqual(host { $0.sftpStartMode = "home" }.parsedSFTPStartMode, .home)
        XCTAssertEqual(host { $0.sftpStartMode = "nonsense" }.parsedSFTPStartMode, .last)
    }

    /// The raw strings are what the Android app writes; changing them would
    /// break a restored backup.
    func testRawValuesMatchAndroid() {
        XCTAssertEqual(Host.JumpMode.simple.rawValue, "simple")
        XCTAssertEqual(Host.JumpMode.hostList.rawValue, "host_list")
        XCTAssertEqual(Host.SFTPStartMode.last.rawValue, "last")
        XCTAssertEqual(Host.SFTPStartMode.fixed.rawValue, "fixed")
        XCTAssertEqual(Host.SFTPStartMode.home.rawValue, "home")
    }
}
