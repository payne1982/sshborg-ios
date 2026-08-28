// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// What the file browser puts on screen, given what the server sent.
///
/// Both of these are display-only decisions, and that is the property worth
/// pinning: neither may change what a caller walking the directory gets, or a
/// folder download would quietly leave the dotfiles behind on the server.
@MainActor
final class SFTPListingTests: XCTestCase {

    private func entry(_ name: String, directory: Bool = false) -> SFTPEntry {
        SFTPEntry(
            name: name,
            isDirectory: directory,
            isSymlink: false,
            size: 0,
            modified: nil,
            permissions: 0o644
        )
    }

    /// A listing as `list` returns one: directories first, each half by name.
    private var listing: [SFTPEntry] {
        [
            entry(".config", directory: true),
            entry("bin", directory: true),
            entry("src", directory: true),
            entry(".bashrc"),
            entry("Makefile"),
            entry("readme.md"),
        ]
    }

    private func names(showingHidden: Bool, directoriesFirst: Bool) -> [String] {
        SFTPModel.visibleEntries(
            listing,
            showingHidden: showingHidden,
            directoriesFirst: directoriesFirst
        ).map(\.name)
    }

    func testDotfilesAreHiddenByDefault() {
        XCTAssertEqual(
            names(showingHidden: false, directoriesFirst: true),
            ["bin", "src", "Makefile", "readme.md"]
        )
    }

    func testShowingHiddenKeepsTheServersOrder() {
        XCTAssertEqual(
            names(showingHidden: true, directoriesFirst: true),
            [".config", "bin", "src", ".bashrc", "Makefile", "readme.md"]
        )
    }

    /// With folders-first off, a name is a name: `bin` and `Makefile` interleave
    /// where their letters put them, which is what Android does.
    func testSortingByNameMixesFoldersAndFiles() {
        XCTAssertEqual(
            names(showingHidden: false, directoriesFirst: false),
            ["bin", "Makefile", "readme.md", "src"]
        )
    }

    /// Case must not split the list into two alphabets, with every capital
    /// ahead of every lower-case name.
    func testSortingByNameIgnoresCase() {
        let mixed = [entry("zeta"), entry("Alpha"), entry("beta")]
        let sorted = SFTPModel.visibleEntries(mixed, showingHidden: true, directoriesFirst: false)
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "beta", "zeta"])
    }

    /// The filter looks at the leading dot only. A name with a dot in it is an
    /// ordinary file, and `..` is drawn by the screen rather than being an entry.
    func testOnlyALeadingDotHides() {
        let entries = [entry("archive.tar.gz"), entry(".hidden"), entry("a.b")]
        let shown = SFTPModel.visibleEntries(entries, showingHidden: false, directoriesFirst: true)
        XCTAssertEqual(shown.map(\.name), ["archive.tar.gz", "a.b"])
    }
}
