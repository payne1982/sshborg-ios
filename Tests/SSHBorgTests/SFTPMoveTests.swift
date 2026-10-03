// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The two decisions a paste makes before it touches the server.
///
/// Everything else about a move is a rename and is measured against a real
/// server in ``SFTPIntegrationTests``; these two are arithmetic, and arithmetic
/// is where a quiet wrong answer hides — one refuses a move that is perfectly
/// legal, the other names a copy badly.
@MainActor
final class SFTPMoveTests: XCTestCase {

    private func entry(_ name: String, directory: Bool = false, link: Bool = false) -> SFTPEntry {
        SFTPEntry(
            name: name,
            isDirectory: directory,
            isSymlink: link,
            size: 0,
            modified: nil,
            permissions: 0o644
        )
    }

    // MARK: - A folder into itself

    func testAFolderCannotBeMovedIntoItselfOrBelowIt() {
        let folder = entry("work", directory: true)
        XCTAssertTrue(SFTPModel.wouldMoveIntoItself(folder, from: "/home/me", to: "/home/me/work"))
        XCTAssertTrue(SFTPModel.wouldMoveIntoItself(folder, from: "/home/me", to: "/home/me/work/notes"))
        XCTAssertTrue(SFTPModel.wouldMoveIntoItself(folder, from: "/home/me", to: "/home/me/work/a/b/c"))
    }

    /// The case the trailing slash exists for: a sibling whose name merely
    /// starts with the folder's. Without it this move would be refused for a
    /// reason the user could not possibly see.
    func testASiblingWithALongerNameIsNotInsideIt() {
        let folder = entry("notes", directory: true)
        XCTAssertFalse(SFTPModel.wouldMoveIntoItself(folder, from: "/home/me", to: "/home/me/notesbook"))
        XCTAssertFalse(SFTPModel.wouldMoveIntoItself(folder, from: "/home/me", to: "/home/me/notes.old"))
    }

    func testAFileIsNeverInsideItself() {
        XCTAssertFalse(SFTPModel.wouldMoveIntoItself(entry("a.txt"), from: "/x", to: "/x/a.txt"))
    }

    /// A link into the tree it points at moves one name and nests nothing.
    func testASymlinkedFolderIsNotTreatedAsTheFolder() {
        let link = entry("shortcut", directory: true, link: true)
        XCTAssertFalse(SFTPModel.wouldMoveIntoItself(link, from: "/home/me", to: "/home/me/shortcut"))
    }

    /// The root is a directory whose path already ends in a slash, so the join
    /// has to not double it.
    func testTheRootDirectoryJoinsWithoutADoubleSlash() {
        let folder = entry("srv", directory: true)
        XCTAssertTrue(SFTPModel.wouldMoveIntoItself(folder, from: "/", to: "/srv/data"))
        XCTAssertFalse(SFTPModel.wouldMoveIntoItself(folder, from: "/", to: "/srvdata"))
    }

    // MARK: - Where the number goes

    func testTheNumberGoesBeforeTheExtension() {
        let (base, ext) = SFTPModel.split(entry("report.txt"))
        XCTAssertEqual(base, "report")
        XCTAssertEqual(ext, ".txt")
    }

    /// The last dot, not the first: `archive.tar.gz` keeps `.gz` and the rest of
    /// the name, which is what every file manager does.
    func testOnlyTheLastDotCounts() {
        let (base, ext) = SFTPModel.split(entry("archive.tar.gz"))
        XCTAssertEqual(base, "archive.tar")
        XCTAssertEqual(ext, ".gz")
    }

    /// A leading dot is not an extension. Getting this wrong turns `.bashrc`
    /// into `(1).bashrc`, which sorts somewhere else entirely and is no longer
    /// recognisably the same file.
    func testADotfileKeepsItsWholeName() {
        let (base, ext) = SFTPModel.split(entry(".bashrc"))
        XCTAssertEqual(base, ".bashrc")
        XCTAssertEqual(ext, "")
    }

    func testAFolderIsNeverSplit() {
        let (base, ext) = SFTPModel.split(entry("backup.2026", directory: true))
        XCTAssertEqual(base, "backup.2026")
        XCTAssertEqual(ext, "")
    }

    func testANameWithNoDotIsLeftAlone() {
        let (base, ext) = SFTPModel.split(entry("Makefile"))
        XCTAssertEqual(base, "Makefile")
        XCTAssertEqual(ext, "")
    }
}
