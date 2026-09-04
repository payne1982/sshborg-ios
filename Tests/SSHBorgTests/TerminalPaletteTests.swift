// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import SwiftUI
import UIKit
import XCTest

@testable import SSHBorg

/// The terminal's colours, which until 04/09/2026 the preference did not pick.
///
/// `terminalColorScheme` was offered in Settings, stored, and carried in
/// backups, and nothing read it: the terminal was dark because two constants
/// said so. The sixth instance of a setting that promises something and
/// delivers nothing.
///
/// The values come from the Android `TerminalView`, not from taste, so these
/// tests compare against Android's numbers. A divergence here is a divergence a
/// user would see as the same `ls` in two different greens.
final class TerminalPaletteTests: XCTestCase {

    private func rgb8(_ color: SwiftTerm.Color) -> (Int, Int, Int) {
        (Int(color.red >> 8), Int(color.green >> 8), Int(color.blue >> 8))
    }

    private func rgb8(_ color: UIColor) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testBothPalettesHaveTheSixteenColoursSwiftTermRequires() {
        // installPalette silently does nothing when the count is not 16, so a
        // short array would leave the terminal on its previous colours with no
        // error anywhere. Exactly the kind of silence this defect was made of.
        XCTAssertEqual(TerminalPalette.dark.ansi.count, 16)
        XCTAssertEqual(TerminalPalette.light.ansi.count, 16)
    }

    /// Android's `darkPalette`, entries 0-15.
    func testTheDarkPaletteIsAndroidsDarkPalette() {
        let expected: [(Int, Int, Int)] = [
            (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
            (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
            (85, 85, 85), (255, 85, 85), (85, 255, 85), (255, 255, 85),
            (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255),
        ]
        for (index, want) in expected.enumerated() {
            let got = rgb8(TerminalPalette.dark.ansi[index])
            XCTAssertTrue(got == want, "ANSI \(index): got \(got), Android has \(want)")
        }
    }

    /// Android's `lightPalette` is its dark one with seven entries darkened —
    /// and, deliberately, bright blue left alone.
    func testTheLightPaletteDarkensExactlyWhatAndroidDarkens() {
        let overridden: [Int: (Int, Int, Int)] = [
            7: (115, 115, 115),
            9: (220, 50, 50),
            10: (0, 135, 0),
            11: (140, 120, 0),
            13: (200, 50, 200),
            14: (0, 145, 160),
            15: (50, 50, 50),
        ]

        for index in 0..<16 {
            let got = rgb8(TerminalPalette.light.ansi[index])
            if let want = overridden[index] {
                XCTAssertTrue(got == want, "ANSI \(index): got \(got), Android has \(want)")
            } else {
                let dark = rgb8(TerminalPalette.dark.ansi[index])
                XCTAssertTrue(
                    got == dark,
                    "ANSI \(index) is not one Android darkens, so it has to match the dark palette"
                )
            }
        }

        // Named, because it looks like an omission and is not: bright blue
        // stays (85, 85, 255) on Android, and measured that is a 5.09 contrast
        // ratio against white — above the 3.0 floor, so there was nothing to
        // fix. The seven that are darkened are all below it untouched.
        XCTAssertTrue(rgb8(TerminalPalette.light.ansi[12]) == (85, 85, 255))
    }

    func testDefaultForegroundAndBackground() {
        XCTAssertTrue(rgb8(TerminalPalette.dark.foreground) == (204, 204, 204))
        XCTAssertTrue(rgb8(TerminalPalette.dark.background) == (0, 0, 0))
        XCTAssertTrue(rgb8(TerminalPalette.light.foreground) == (51, 51, 51))
        XCTAssertTrue(rgb8(TerminalPalette.light.background) == (255, 255, 255))
    }

    /// Android draws the cursor in the default foreground at alpha 180.
    func testTheCaretFollowsTheForegroundAtAndroidsAlpha() {
        var alpha: CGFloat = 0
        TerminalPalette.dark.caret.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(Int((alpha * 255).rounded()), 180)
        XCTAssertTrue(rgb8(TerminalPalette.dark.caret) == rgb8(TerminalPalette.dark.foreground))
        XCTAssertTrue(rgb8(TerminalPalette.light.caret) == rgb8(TerminalPalette.light.foreground))
    }

    // MARK: - Choosing

    func testTheTwoFixedChoicesIgnoreTheApp() {
        for appearance in [ColorScheme.light, .dark] {
            XCTAssertTrue(
                rgb8(TerminalPalette.resolve(.dark, app: appearance).background) == (0, 0, 0)
            )
            XCTAssertTrue(
                rgb8(TerminalPalette.resolve(.light, app: appearance).background) == (255, 255, 255)
            )
        }
    }

    func testFollowAppFollowsTheApp() {
        XCTAssertTrue(
            rgb8(TerminalPalette.resolve(.followApp, app: .light).background) == (255, 255, 255)
        )
        XCTAssertTrue(
            rgb8(TerminalPalette.resolve(.followApp, app: .dark).background) == (0, 0, 0)
        )
    }

    /// The default is dark, and stays dark whatever the phone is set to: it is
    /// what every terminal on the machine looks like, and what this app looked
    /// like before the preference did anything.
    func testTheDefaultPreferenceIsDarkOnALightPhone() throws {
        let name = "TerminalPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)

        let palette = TerminalPalette.resolve(preferences.terminalColorScheme, app: .light)
        XCTAssertTrue(rgb8(palette.background) == (0, 0, 0))
    }
}
