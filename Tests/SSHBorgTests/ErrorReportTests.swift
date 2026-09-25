// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// What an operation says when it goes wrong over several files.
///
/// Ported from Android's error reports (19/09/2026). The behaviour worth pinning
/// is not the wording: it is that a batch does not stop at the first refusal, and
/// that what it did not do is named rather than silently dropped.
final class ErrorReportTests: XCTestCase {

    private struct Refused: LocalizedError {
        let errorDescription: String? = "Permission denied"
    }

    func testTheReportCopiesAsTextWithEveryFile() {
        let report = ErrorReport(
            title: "Delete failed",
            failures: [
                FileFailure(name: "one.txt", message: "Permission denied", detail: "SSHError.library(3)"),
                FileFailure(name: "two.txt", message: "No such file", detail: ""),
            ],
            notAttempted: ["three.txt", "four.txt"]
        )

        let text = report.asText
        XCTAssertTrue(text.hasPrefix("Delete failed"))
        XCTAssertTrue(text.contains("✗ one.txt — Permission denied"))
        XCTAssertTrue(text.contains("SSHError.library(3)"), "the detail is what a bug report needs")
        XCTAssertTrue(text.contains("✗ two.txt — No such file"))
        XCTAssertTrue(text.contains("three.txt, four.txt"), "the files never reached are not named")
    }

    /// A failure whose detail says nothing the message did not must not print
    /// the same sentence twice.
    func testADetaillessFailureIsNotRepeated() {
        let report = ErrorReport(
            title: "Upload failed",
            failures: [FileFailure(name: "x", message: "Broken pipe", detail: "Broken pipe")]
        )
        XCTAssertEqual(report.asText.components(separatedBy: "Broken pipe").count - 1, 1)
    }

    func testAnErrorBecomesAFailureWithItsOwnDetail() {
        let failure = FileFailure(name: "notes.txt", error: SSHError.notConnected)

        XCTAssertEqual(failure.name, "notes.txt")
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertTrue(failure.detail.contains("notConnected"), "got \(failure.detail)")
    }

    // MARK: - What a transfer reports

    func testAFinishedTransferWithSkippedFilesIsPartial() {
        var transfer = TransferManager.Transfer(kind: .download, name: "photos")
        transfer.fileCount = 10
        transfer.status = .finished
        transfer.failures = [FileFailure(name: "a.jpg", error: Refused())]

        XCTAssertTrue(transfer.isPartial)
        XCTAssertEqual(transfer.doneCount, 9)
        XCTAssertEqual(transfer.report?.failures.count, 1)
    }

    func testACleanTransferHasNothingToReport() {
        var transfer = TransferManager.Transfer(kind: .download, name: "photos")
        transfer.status = .finished

        XCTAssertFalse(transfer.isPartial)
        XCTAssertNil(transfer.report)
    }

    /// A transfer the user stopped is not a failure, and must not offer a report
    /// of its own cancellation.
    func testACancelledTransferReportsNothing() {
        var transfer = TransferManager.Transfer(kind: .upload, name: "big.iso")
        transfer.status = .cancelled
        transfer.failures = [FileFailure(name: "big.iso", error: SSHError.cancelled)]

        XCTAssertNil(transfer.report)
    }

    /// A single file that failed outright still has something to show, even
    /// though nothing walked a tree to collect it.
    func testAFailedSingleFileStillHasAReport() {
        var transfer = TransferManager.Transfer(kind: .download, name: "notes.txt")
        transfer.status = .failed("Permission denied")

        let report = transfer.report
        XCTAssertEqual(report?.failures.first?.name, "notes.txt")
        XCTAssertEqual(report?.failures.first?.message, "Permission denied")
    }
}
