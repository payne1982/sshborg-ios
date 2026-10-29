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

    // MARK: - Saving a file that is already there

    /// The whole point of the atomic save: the bytes never sit in a file more
    /// open than the one they are replacing. Android's editor widened a 0600
    /// file to whatever the umask allowed, because it wrote to a *new* temp file
    /// and chmod'd it afterwards.
    func testASaveKeepsTheFilesOwnPermissions() async throws {
        let path = "\(workingDirectory!)/private.conf"
        let first = try scratchFile(containing: "secret\n")
        try await session.write(first, to: path, flags: SFTPSession.createExclusively, mode: 0o600)
        let asCreated = try await permissions(of: path)
        XCTAssertEqual(asCreated, 0o600, "the fixture did not get its mode")

        let second = try scratchFile(containing: "still secret\n")
        try await session.uploadReplacing(from: second, to: path)

        let afterSaving = try await permissions(of: path)
        let contents = try await text(at: path)
        XCTAssertEqual(afterSaving, 0o600, "the save widened the file")
        XCTAssertEqual(contents, "still secret\n")
    }

    /// A save that dies halfway must leave the file it was replacing exactly as
    /// it was — which a truncating write cannot do, and is the reason for all
    /// of this.
    func testASaveThatDiesHalfwayLeavesTheOriginalAlone() async throws {
        let path = "\(workingDirectory!)/notes.txt"
        let original = try scratchFile(containing: "the original\n")
        try await session.upload(from: original, to: path)

        // Bigger than one chunk, so the cancellation lands in the middle of the
        // write rather than before it.
        let replacement = try scratchFile(containing: String(repeating: "x", count: 300_000))
        let cancelled = Cancelled()

        do {
            try await session.uploadReplacing(
                from: replacement, to: path, isCancelled: { cancelled.afterFirstChunk() }
            )
            XCTFail("a cancelled save reported success")
        } catch {
            XCTAssertEqual(error as? SSHError, .cancelled)
        }

        let survived = try await text(at: path)
        XCTAssertEqual(survived, "the original\n", "the original was damaged")
        let leftovers = try await session.list(workingDirectory)
            .map(\.name)
            .filter { $0 != "notes.txt" }
        XCTAssertEqual(leftovers, [], "the save left litter behind")
    }

    /// `EXCL` is the guarantee the whole sequence rests on: the scratch name is
    /// *created*, so a name something is already using fails instead of being
    /// opened — and if that something is a symlink, "opened" would mean writing
    /// through it to a file somebody else chose.
    func testAnExclusiveCreateRefusesANameThatIsTaken() async throws {
        let path = "\(workingDirectory!)/taken"
        let file = try scratchFile(containing: "here first\n")
        try await session.upload(from: file, to: path)

        do {
            try await session.write(file, to: path, flags: SFTPSession.createExclusively, mode: 0o644)
            XCTFail("an exclusive create opened a file that already existed")
        } catch {
            // The server's refusal, whatever it calls it.
        }
        let untouched = try await text(at: path)
        XCTAssertEqual(untouched, "here first\n")
    }

    /// Somebody deleted the file while the editor was open. Save then means
    /// create, which is what the button says.
    func testSavingOverAFileThatHasGoneCreatesIt() async throws {
        let path = "\(workingDirectory!)/vanished.txt"
        let file = try scratchFile(containing: "back again\n")

        try await session.uploadReplacing(from: file, to: path)

        let created = try await text(at: path)
        XCTAssertEqual(created, "back again\n")
    }

    /// And the ordinary case leaves the directory with one file in it and no
    /// trace of how it got there.
    func testASuccessfulSaveLeavesNothingBehind() async throws {
        let path = "\(workingDirectory!)/config"
        try await session.upload(from: try scratchFile(containing: "one\n"), to: path)

        try await session.uploadReplacing(from: try scratchFile(containing: "two\n"), to: path)

        let listing = try await session.list(workingDirectory).map(\.name)
        let saved = try await text(at: path)
        XCTAssertEqual(listing, ["config"])
        XCTAssertEqual(saved, "two\n")
    }

    // MARK: - Helpers for the saving tests

    /// Saving a symbolic link does what Android does — his decision — and the
    /// link becomes a regular file. What it must not become is a file with the
    /// **link's** permissions: a link is usually 0777, so a save that read the
    /// mode with `lstat` published a 0600 target's contents to every account
    /// that could reach the directory.
    func testSavingALinkTakesTheTargetsPermissionsAndNotTheLinks() async throws {
        let shell = try await shellSession()
        defer { shell.disconnect() }
        let directory = workingDirectory!
        _ = try await shell.execute(
            "cd \(directory) && printf 'secret\\n' > real.conf && chmod 600 real.conf && ln -s real.conf link.conf"
        )
        let before = try await session.lstat("\(directory)/link.conf")
        XCTAssertEqual(before?.isSymlink, true, "the fixture is not a link")

        try await session.uploadReplacing(
            from: try scratchFile(containing: "edited\n"), to: "\(directory)/link.conf"
        )

        let afterSaving = try await session.lstat("\(directory)/link.conf")
        let saved = try XCTUnwrap(afterSaving)
        XCTAssertFalse(saved.isSymlink, "the link was kept, which is not what Android does")
        XCTAssertEqual(saved.permissions, 0o600, "the saved file took the link's mode")
        let contents = try await text(at: "\(directory)/link.conf")
        XCTAssertEqual(contents, "edited\n")
    }

    /// A mode the server's umask would narrow is put back exactly. The scratch
    /// file is created owner-only and given the real mode explicitly before it
    /// takes the original's place, so a group-writable 0664 no longer comes back
    /// 0644.
    func testASaveKeepsAModeTheUmaskWouldNarrow() async throws {
        let shell = try await shellSession()
        defer { shell.disconnect() }
        let path = "\(workingDirectory!)/shared.conf"
        _ = try await shell.execute("printf 'one\\n' > \(path) && chmod 664 \(path)")
        let asMade = try await permissions(of: path)
        XCTAssertEqual(asMade, 0o664, "the fixture did not get its mode")

        try await session.uploadReplacing(from: try scratchFile(containing: "two\n"), to: path)

        let afterSaving = try await permissions(of: path)
        XCTAssertEqual(afterSaving, 0o664, "the umask narrowed the saved file")
    }

    /// A shell on the same host, for the fixtures SFTP cannot make: a link, and
    /// a mode wider than the umask allows.
    private func shellSession() async throws -> SSHSession {
        let target = try XCTUnwrap(SSHTestCredentials.target())
        var params = SSHConnectionParams(
            hostname: target.host, port: target.port, username: target.username,
            auth: .password(target.password)
        )
        params.hostKeyPolicy = .acceptOnce
        params.connectTimeout = 15
        return try await SSHSession.connect(params)
    }

    private func scratchFile(containing text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshborg-test-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func permissions(of path: String) async throws -> UInt32 {
        let entry = try await session.lstat(path)
        return try XCTUnwrap(entry).permissions
    }

    private func text(at path: String) async throws -> String {
        String(decoding: try await session.readSmallFile(at: path), as: UTF8.self)
    }

    /// True from the second time it is asked, so the write has put a chunk on
    /// the wire before the cancellation lands.
    private final class Cancelled: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0

        func afterFirstChunk() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            asked += 1
            return asked > 1
        }
    }
}
