// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Tidying a server's banner for the screen.
///
/// The Android counterpart is `BannerTextTest`, over `SshManager.appendBanner`.
final class BannerTests: XCTestCase {

    /// A banner travels with CR LF. Left alone, every line of it would be
    /// followed by a blank one in the box.
    func testLineEndingsBecomeTheOneThingATextViewUnderstands() {
        XCTAssertEqual(Banner.readable("one\r\ntwo\r\nthree"), "one\ntwo\nthree")
        XCTAssertEqual(Banner.readable("old\rmac"), "old\nmac")
    }

    /// Most banners end with a blank line, which would push the password field
    /// down for nothing. Blank lines *inside* stay: a banner is laid out on
    /// purpose, and dropping them would take its layout apart.
    func testTrailingBlankLinesGoAndTheOnesInTheMiddleStay() {
        XCTAssertEqual(Banner.readable("terms\n\nand conditions\n\n\n"), "terms\n\nand conditions")
    }

    /// The spaces a banner is drawn with are the drawing.
    func testTheDrawingIsLeftExactlyAsItArrived() {
        let drawn = "+----------+\n|  WELCOME |\n+----------+"
        XCTAssertEqual(Banner.readable(drawn), drawn)
    }

    /// Nothing to show is nil and not an empty box.
    func testAnEmptyBannerIsNoBanner() {
        XCTAssertNil(Banner.readable(nil))
        XCTAssertNil(Banner.readable(""))
        XCTAssertNil(Banner.readable("\r\n   \r\n"))
    }
}
