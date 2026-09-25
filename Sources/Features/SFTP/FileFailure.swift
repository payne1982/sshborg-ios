// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One file that did not make it, and why.
///
/// Counterpart of the Android `FileFailure`, and it exists for the same reason:
/// an operation over several files used to end as one line — "3 skipped" — with
/// the errors themselves thrown away. Which file, and what the server said about
/// it, is the whole of what the user needs to do something about it.
struct FileFailure: Identifiable, Equatable {

    let id = UUID()

    /// The file, as the user knows it: a name, not a path, unless the path is
    /// what distinguishes two files in the same report.
    let name: String

    /// One line, shown next to the name.
    let message: String

    /// Everything else, behind a disclosure: the error as the type system has
    /// it, which for an ``SSHError`` names the case and carries the server's own
    /// code. Android puts a stack trace here; Swift errors do not carry one, and
    /// the case with its payload is the equivalent thing — what a bug report
    /// needs and a person does not.
    let detail: String

    init(name: String, message: String, detail: String) {
        self.name = name
        self.message = message
        self.detail = detail
    }

    init(name: String, error: Error) {
        self.name = name
        self.message = error.localizedDescription
        // `String(reflecting:)` on an enum with associated values prints the
        // case and its payload; `localizedDescription` is the sentence.
        self.detail = String(reflecting: error)
    }

    static func == (lhs: FileFailure, rhs: FileFailure) -> Bool {
        lhs.name == rhs.name && lhs.message == rhs.message && lhs.detail == rhs.detail
    }
}

/// What went wrong in one operation: a single file, a batch, or a transfer.
///
/// It stays on screen until it is closed, and it copies as text, because the
/// alternative — the message that disappears after three seconds — is no use to
/// anyone typing the problem into a search box or a bug report. That was the
/// state here until now: `actionError`, one line, no detail, gone on the next
/// tap.
struct ErrorReport: Identifiable, Equatable {

    let id = UUID()
    let title: String
    var failures: [FileFailure]

    /// Files a lost connection never reached. Naming them matters: without it a
    /// batch that stopped halfway looks like a batch that finished.
    var notAttempted: [String] = []

    init(title: String, failures: [FileFailure], notAttempted: [String] = []) {
        self.title = title
        self.failures = failures
        self.notAttempted = notAttempted
    }

    /// One failure, which is the common case.
    init(title: String, name: String, error: Error) {
        self.init(title: title, failures: [FileFailure(name: name, error: error)])
    }

    var isEmpty: Bool { failures.isEmpty && notAttempted.isEmpty }

    /// The whole report as plain text, details included — what Copy puts on the
    /// clipboard.
    var asText: String {
        var lines = [title]

        for failure in failures {
            let headline = [failure.name, failure.message]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            lines.append("✗ \(headline)")
            if !failure.detail.isEmpty, failure.detail != failure.message {
                lines.append("   \(failure.detail)")
            }
        }

        if !notAttempted.isEmpty {
            lines.append(
                String(localized: .sftpReportNotAttempted)
                    .replacingOccurrences(of: "%1$@", with: notAttempted.joined(separator: ", "))
            )
        }

        return lines.joined(separator: "\n")
    }

    static func == (lhs: ErrorReport, rhs: ErrorReport) -> Bool {
        lhs.title == rhs.title && lhs.failures == rhs.failures && lhs.notAttempted == rhs.notAttempted
    }
}
