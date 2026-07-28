// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
}
