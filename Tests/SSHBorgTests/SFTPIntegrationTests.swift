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
        let environment = ProcessInfo.processInfo.environment

        func setting(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty, !value.hasPrefix("$(") else {
                return nil
            }
            return value
        }

        guard let host = setting("SSHBORG_TEST_HOST"),
              let username = setting("SSHBORG_TEST_USER"),
              let password = setting("SSHBORG_TEST_PASSWORD")
        else {
            throw XCTSkip("No SSH target configured; set SSHBORG_TEST_HOST, _USER and _PASSWORD.")
        }

        var params = SSHConnectionParams(
            hostname: host,
            port: Int(setting("SSHBORG_TEST_PORT") ?? "22") ?? 22,
            username: username,
            auth: .password(password)
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

    // MARK: - Helpers

    private func upload(text: String, named name: String) async throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }

        try text.write(to: local, atomically: true, encoding: .utf8)
        try await session.upload(from: local, to: "\(workingDirectory!)/\(name)")
    }
}
