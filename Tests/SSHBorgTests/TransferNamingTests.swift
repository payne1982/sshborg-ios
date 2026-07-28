// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The "keep both" naming. It has to match the Android downloader's shape,
/// `name(1).ext`, so a user moving between platforms sees the same thing.
@MainActor
final class TransferNamingTests: XCTestCase {

    func testUntakenNameIsLeftAlone() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(for: "report.pdf", existing: ["other.pdf"]),
            "report.pdf"
        )
    }

    func testClashGainsACounterBeforeTheExtension() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(for: "report.pdf", existing: ["report.pdf"]),
            "report(1).pdf"
        )
    }

    func testCounterSkipsNamesAlreadyTaken() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(
                for: "report.pdf",
                existing: ["report.pdf", "report(1).pdf", "report(2).pdf"]
            ),
            "report(3).pdf"
        )
    }

    func testExtensionlessNamesGetTheCounterAtTheEnd() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(for: "Makefile", existing: ["Makefile"]),
            "Makefile(1)"
        )
    }

    /// A dotfile is all extension by one reading and none by another. What
    /// matters is that the result stays hidden and keeps its name recognisable.
    func testDotfileKeepsItsLeadingDot() {
        let result = TransferManager.uniqueRemoteName(for: ".bashrc", existing: [".bashrc"])
        XCTAssertTrue(result.hasPrefix("."), "a dotfile must not stop being hidden, got \(result)")
        XCTAssertNotEqual(result, ".bashrc")
    }

    func testMultipleDotsOnlySplitAtTheLast() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(for: "archive.tar.gz", existing: ["archive.tar.gz"]),
            "archive.tar(1).gz"
        )
    }

    func testEmptyDirectoryNeverClashes() {
        XCTAssertEqual(
            TransferManager.uniqueRemoteName(for: "anything.txt", existing: []),
            "anything.txt"
        )
    }
}
