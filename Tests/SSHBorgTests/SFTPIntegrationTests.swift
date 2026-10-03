// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Exercises the SFTP layer against a real server, in a directory it creates
/// and removes itself. Skipped unless a target is configured — see
/// ``SSHIntegrationTests`` for how the credentials arrive.
final class SFTPIntegrationTests: XCTestCase {

    private var session: SFTPSession!
    private var workingDirectory: String!

    override func setUp() async throws {
        guard let target = SSHTestCredentials.target() else {
            throw XCTSkip(SSHTestCredentials.skipReason)
        }

        var params = SSHConnectionParams(
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15

        session = try await SFTPSession.connect(params)

        // Everything happens inside one scratch directory so a failed run
        // cannot leave debris anywhere that matters.
        workingDirectory = "\(session.homePath)/sshborg-tests-\(UUID().uuidString.prefix(8))"
        try await session.createDirectory(at: workingDirectory)
    }

    override func tearDown() async throws {
        guard let session, let workingDirectory else { return }

        for entry in (try? await session.list(workingDirectory)) ?? [] {
            let path = "\(workingDirectory)/\(entry.name)"
            if entry.isDirectory {
                try? await session.removeDirectory(at: path)
            } else {
                try? await session.removeFile(at: path)
            }
        }
        try? await session.removeDirectory(at: workingDirectory)
        session.disconnect()
    }

    // MARK: - Connecting and listing

    func testResolvesHomeDirectory() {
        XCTAssertTrue(session.homePath.hasPrefix("/"), "home should be absolute, got \(session.homePath)")
        XCTAssertFalse(session.homePath.isEmpty)
    }

    func testNewDirectoryIsEmpty() async throws {
        let entries = try await session.list(workingDirectory)
        XCTAssertTrue(entries.isEmpty)
    }

    func testDotEntriesAreNotListed() async throws {
        let entries = try await session.list(session.homePath)
        XCTAssertFalse(entries.contains { $0.name == "." || $0.name == ".." })
    }

    /// Directories first, then files, each alphabetically — the ordering the
    /// Android list uses.
    func testListingIsSortedDirectoriesFirst() async throws {
        try await session.createDirectory(at: "\(workingDirectory!)/zeta-dir")
        try await session.createDirectory(at: "\(workingDirectory!)/alpha-dir")
        try await upload(text: "x", named: "beta-file.txt")
        try await upload(text: "x", named: "alpha-file.txt")

        let names = try await session.list(workingDirectory).map(\.name)
        XCTAssertEqual(names, ["alpha-dir", "zeta-dir", "alpha-file.txt", "beta-file.txt"])
    }

    // MARK: - Transfers

    func testUploadThenDownloadRoundTrip() async throws {
        let contents = "SSHBorg round trip \(UUID().uuidString)\nsecond line\n"
        try await upload(text: contents, named: "round-trip.txt")

        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try await session.download(from: "\(workingDirectory!)/round-trip.txt", to: local)

        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), contents)
    }

    /// A file larger than the 32 KiB transfer chunk, so the loops that stitch
    /// chunks together are actually exercised.
    func testMultiChunkTransferIsExact() async throws {
        let payload = String(repeating: "0123456789abcdef", count: 8 * 1024) // 128 KiB
        try await upload(text: payload, named: "large.bin")

        var reported: [UInt64] = []
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try await session.download(from: "\(workingDirectory!)/large.bin", to: local) { bytes in
            reported.append(bytes)
        }

        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), payload)
        XCTAssertGreaterThan(reported.count, 1, "a multi-chunk file should report progress more than once")
        XCTAssertEqual(reported.last, UInt64(payload.utf8.count))
        XCTAssertEqual(reported, reported.sorted(), "progress must only ever increase")
    }

    func testEmptyFileRoundTrips() async throws {
        try await upload(text: "", named: "empty.txt")

        let entry = try await session.stat("\(workingDirectory!)/empty.txt")
        XCTAssertEqual(entry?.size, 0)
    }

    func testReadSmallFile() async throws {
        try await upload(text: "history line\n", named: "small.txt")

        let data = try await session.readSmallFile(at: "\(workingDirectory!)/small.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "history line\n")
    }

    // MARK: - Metadata

    func testStatReportsSizeAndType() async throws {
        try await upload(text: "12345", named: "sized.txt")
        try await session.createDirectory(at: "\(workingDirectory!)/a-directory")

        let file = try await session.stat("\(workingDirectory!)/sized.txt")
        XCTAssertEqual(file?.size, 5)
        XCTAssertEqual(file?.isDirectory, false)

        let directory = try await session.stat("\(workingDirectory!)/a-directory")
        XCTAssertEqual(directory?.isDirectory, true)
    }

    func testStatOfMissingPathIsNil() async throws {
        let entry = try await session.stat("\(workingDirectory!)/definitely-not-here")
        XCTAssertNil(entry)
    }

    func testListingCarriesSizeAndModificationDate() async throws {
        try await upload(text: "abcdefghij", named: "dated.txt")

        let listing = try await session.list(workingDirectory)
        let entry = try XCTUnwrap(listing.first)
        XCTAssertEqual(entry.size, 10)
        let modified = try XCTUnwrap(entry.modified)
        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 300, "mtime should be roughly now")
    }

    // MARK: - Mutating

    func testRename() async throws {
        try await upload(text: "x", named: "before.txt")
        try await session.rename(
            from: "\(workingDirectory!)/before.txt",
            to: "\(workingDirectory!)/after.txt"
        )

        let names = try await session.list(workingDirectory).map(\.name)
        XCTAssertEqual(names, ["after.txt"])
    }

    func testRemoveFile() async throws {
        try await upload(text: "x", named: "doomed.txt")
        try await session.removeFile(at: "\(workingDirectory!)/doomed.txt")

        let entries = try await session.list(workingDirectory)
        XCTAssertTrue(entries.isEmpty)
    }

    func testRemoveDirectory() async throws {
        try await session.createDirectory(at: "\(workingDirectory!)/gone")
        try await session.removeDirectory(at: "\(workingDirectory!)/gone")

        let entries = try await session.list(workingDirectory)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Failures worth naming

    func testListingAMissingDirectoryFails() async throws {
        do {
            _ = try await session.list("\(workingDirectory!)/not-there")
            XCTFail("listing a missing directory should fail")
        } catch {
            XCTAssertTrue(error is SSHError)
        }
    }

    func testDownloadingAMissingFileFails() async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")

        do {
            try await session.download(from: "\(workingDirectory!)/not-there", to: local)
            XCTFail("downloading a missing file should fail")
        } catch {
            XCTAssertTrue(error is SSHError)
            // A failed download must not leave a half-made local file behind.
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        }
    }

    func testRemovingANonEmptyDirectoryFails() async throws {
        try await session.createDirectory(at: "\(workingDirectory!)/full")
        try await upload(text: "x", named: "full/inside.txt")

        do {
            try await session.removeDirectory(at: "\(workingDirectory!)/full")
            XCTFail("removing a non-empty directory should fail")
        } catch {
            XCTAssertTrue(error is SSHError)
        }

        // Clean up what tearDown's shallow sweep cannot.
        try await session.removeFile(at: "\(workingDirectory!)/full/inside.txt")
        try await session.removeDirectory(at: "\(workingDirectory!)/full")
    }

    // MARK: - Moving, and the rename rule behind it

    /// The claim the whole move feature rests on, measured against a real
    /// OpenSSH server rather than taken from the specification: a rename onto a
    /// name that is already taken **fails** here.
    ///
    /// It is the opposite of what the Android app gets from JSch, which uses
    /// `posix-rename@openssh.com` and overwrites silently, and the reason both
    /// apps check the destination themselves. If this ever starts passing — a
    /// libssh2 that negotiates version 5, or one that adopts the extension in
    /// `rename` — then the iOS half of `docs/sftp-move.md` is out of date and
    /// the app is quietly destroying files.
    func testARenameOntoAnExistingNameIsRefused() async throws {
        try await upload(text: "one", named: "a.txt")
        try await upload(text: "two", named: "b.txt")

        do {
            try await session.rename(
                from: "\(workingDirectory!)/a.txt",
                to: "\(workingDirectory!)/b.txt"
            )
            XCTFail("the rename overwrote b.txt — libssh2 now replaces an existing destination")
        } catch {
            // And nothing moved: both names are still there, with their own
            // contents. A failure that half-happened would be worse than either
            // behaviour.
            let names = try await session.list(workingDirectory).map(\.name).sorted()
            XCTAssertEqual(names, ["a.txt", "b.txt"])
        }
    }

    /// `lstat` is what the destination is checked with, and this is why: a
    /// symbolic link whose target is gone still owns its name, and `stat` — which
    /// follows it — reports nothing at all. Checking with `stat` would call the
    /// name free and the rename would then be refused by the server.
    func testADanglingSymlinkStillOwnsItsName() async throws {
        try await upload(text: "gone", named: "target.txt")
        try await session.createSymbolicLink(
            at: "\(workingDirectory!)/link.txt",
            pointingAt: "\(workingDirectory!)/target.txt"
        )
        try await session.removeFile(at: "\(workingDirectory!)/target.txt")

        let followed = try await session.stat("\(workingDirectory!)/link.txt")
        let direct = try await session.lstat("\(workingDirectory!)/link.txt")

        XCTAssertNil(followed, "stat followed the link to a file that is gone")
        XCTAssertNotNil(direct, "lstat lost a name that is still taken")
        XCTAssertEqual(direct?.isSymlink, true)

        try await session.removeFile(at: "\(workingDirectory!)/link.txt")
    }

    /// Moving between directories is one rename, and the file arrives whole.
    func testAMoveCarriesTheFileIntoAnotherDirectory() async throws {
        try await upload(text: "moved", named: "travels.txt")
        try await session.createDirectory(at: "\(workingDirectory!)/elsewhere")

        try await session.rename(
            from: "\(workingDirectory!)/travels.txt",
            to: "\(workingDirectory!)/elsewhere/travels.txt"
        )

        let here = try await session.list(workingDirectory).map(\.name)
        XCTAssertFalse(here.contains("travels.txt"))

        let there = try await session.list("\(workingDirectory!)/elsewhere")
        XCTAssertEqual(there.map(\.name), ["travels.txt"])
        XCTAssertEqual(there.first?.size, 5)

        try await session.removeFile(at: "\(workingDirectory!)/elsewhere/travels.txt")
        try await session.removeDirectory(at: "\(workingDirectory!)/elsewhere")
    }

    /// The three renames that stand in for an overwrite, run against the real
    /// server in the order the app runs them: park, move, delete the parked
    /// copy. What it proves is the part that matters — every step has a free
    /// destination, so none of them is the rename the server would refuse.
    func testOverwritingIsThreeRenamesAndTheDataIsNeverNameless() async throws {
        try await upload(text: "incoming", named: "source.txt")
        try await upload(text: "already here", named: "destination.txt")

        let parked = "\(workingDirectory!)/destination.txt.parked"
        try await session.rename(from: "\(workingDirectory!)/destination.txt", to: parked)
        // Between the first and the second rename the old file is still on the
        // server under its parking name. That is the invariant.
        let parkedExists = try await session.lstat(parked)
        XCTAssertNotNil(parkedExists)

        try await session.rename(
            from: "\(workingDirectory!)/source.txt",
            to: "\(workingDirectory!)/destination.txt"
        )
        try await session.removeFile(at: parked)

        let names = try await session.list(workingDirectory).map(\.name).sorted()
        XCTAssertEqual(names, ["destination.txt"])

        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try await session.download(from: "\(workingDirectory!)/destination.txt", to: local)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "incoming")
    }

    // MARK: - Helpers

    private func upload(text: String, named name: String) async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try text.write(to: local, atomically: true, encoding: .utf8)
        try await session.upload(from: local, to: "\(workingDirectory!)/\(name)")
    }
}
