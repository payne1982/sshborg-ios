// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import SSHBorg

/// The names a listing may contain, and the ones that are a path wearing a
/// name's clothes.
///
/// This is the only way to check it: a hostile SFTP server is not something
/// anyone can set up on the way to testing a download, and the behaviour being
/// refused — a download writing outside the folder it was given — leaves no
/// trace on the screen when it works.
final class SFTPNamesTests: XCTestCase {

    func testOrdinaryNamesAreNames() {
        for name in [
            "notes.txt", ".bashrc", "a file with spaces", "già", "日本語", "-rf", "a\\b", "~",
            "...", "..file", "file..", "a:b", "*", "C:", "name\twith\ttabs", " leading space",
            "trailing ", "\u{1B}[31m", String(repeating: "x", count: 255),
        ] {
            XCTAssertTrue(SFTPNames.isPlain(name), "\(name.debugDescription) is a good filename")
        }
    }

    func testAPathIsNotAName() {
        for name in [
            "..", ".", "", "../../somewhere.txt", "../..", "sub/file", "/etc/passwd", "/",
            "a/b/c", "name\0.txt", "..\u{0}", "./.",
        ] {
            XCTAssertFalse(
                SFTPNames.isPlain(name),
                "\(name.debugDescription) is not a single name and must not be used as one"
            )
        }
    }

    /// The reason the rule exists, spelled out where it can be seen: a name the
    /// rule refuses would otherwise decide where a file lands.
    func testWhatARefusedNameWouldHaveDone() throws {
        let documents = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents")

        let escaped = documents.appendingPathComponent("../../../../tmp/elsewhere.txt")

        XCTAssertEqual(escaped.standardized.path, "/var/mobile/Containers/tmp/elsewhere.txt")
        XCTAssertFalse(escaped.standardized.path.hasPrefix(documents.path))
        XCTAssertFalse(SFTPNames.isPlain("../../../../tmp/elsewhere.txt"))
    }
}
