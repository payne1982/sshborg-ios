// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

@MainActor
final class StackCheckTests: XCTestCase {

    /// Fails CI if any of the three dependencies stops linking or initialising.
    func testWholeStackInitialises() {
        for outcome in StackCheck.runAll() {
            XCTAssertTrue(outcome.ok, "\(outcome.component) failed to initialise: \(outcome.detail)")
        }
    }

    /// Pins the libssh2 floor at 1.11.1, the current upstream stable release.
    ///
    /// 1.11 is where `libssh2_channel_request_auth_agent()` and UNIX socket
    /// support arrived, both of which agent forwarding needs in phase 7, and
    /// 1.11.1 carries the fixes on top of it. If a resolved dependency ever
    /// drags in something older, this fails rather than quietly regressing.
    func testLibssh2IsAtLeast1_11_1() {
        let outcome = StackCheck.checkLibssh2()
        XCTAssertTrue(outcome.ok, outcome.detail)

        // libssh2 reports "1.11.1_DEV" even at the official 1.11.1 tag — the
        // suffix is only stripped when the release tarball is rolled, not in
        // git. Take the leading numeric part of each component.
        let parts = outcome.detail
            .split(separator: ".")
            .map { $0.prefix { $0.isNumber } }
            .compactMap { Int($0) }

        XCTAssertGreaterThanOrEqual(parts.count, 3, "unparsable version: \(outcome.detail)")
        guard parts.count >= 3 else { return }

        let version = (major: parts[0], minor: parts[1], patch: parts[2])
        XCTAssertTrue(
            version >= (1, 11, 1),
            "libssh2 >= 1.11.1 required, found \(outcome.detail)"
        )
    }

    /// Fails once the toolchain outgrows the reason Perception is pinned, so the
    /// pin cannot quietly become permanent.
    ///
    /// `project.yml` pins Perception to exactly 2.0.11. Nothing is wrong with
    /// 2.0.12 — it is a bump for IssueReporting 2.1 and a documentation link —
    /// but its manifest declares `swift-tools-version: 6.4`, and a 6.3 toolchain
    /// will not read a 6.4 manifest at all: the build dies at package
    /// resolution, before compiling a line. The pin is a fact about the Xcode
    /// installed here, not a judgement about the library.
    ///
    /// So the day Xcode ships Swift 6.4, this test says so.
    func testPerceptionPinIsStillNeeded() {
        #if compiler(>=6.4)
        XCTFail("Swift 6.4 is here: in project.yml replace `exactVersion: 2.0.11` with `from: 2.0.0`, then delete this test.")
        #endif
    }
}
