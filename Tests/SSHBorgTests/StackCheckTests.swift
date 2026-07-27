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

    /// libssh2 must be at least 1.11: `libssh2_channel_request_auth_agent()` and
    /// UNIX socket support are required for agent forwarding (phase 7).
    func testLibssh2IsAtLeast1_11() {
        let outcome = StackCheck.checkLibssh2()
        XCTAssertTrue(outcome.ok, outcome.detail)

        let parts = outcome.detail.split(separator: ".").compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 2, "unparsable version: \(outcome.detail)")
        guard parts.count >= 2 else { return }
        XCTAssertTrue(
            parts[0] > 1 || (parts[0] == 1 && parts[1] >= 11),
            "libssh2 >= 1.11 required, found \(outcome.detail)"
        )
    }
}
