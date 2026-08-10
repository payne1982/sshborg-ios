// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

@testable import SSHBorg

/// Guards the bundled terminal font.
///
/// `UIAppFonts` fails quietly: a misspelt file name, or a font left out of the
/// target's resources, leaves the app running in the system monospace with no
/// error logged anywhere. The only symptom is that every Powerline glyph in a
/// prompt turns into a box — which no other test would notice, and which the
/// fallback in `TerminalFont` is designed to make survivable rather than silent.
final class TerminalFontTests: XCTestCase {

    func testBundledFontIsRegistered() {
        XCTAssertTrue(
            TerminalFont.isBundledFontAvailable,
            """
            JetBrainsMonoNFM did not resolve. Either the .ttf files are missing \
            from the target's resources, or the names under UIAppFonts in \
            project.yml no longer match the files.
            """
        )
    }

    /// The family iOS reports is *not* the one the file's `name` table lists
    /// first. Reading the TTF gives "JetBrainsMono NFM"; CoreText resolves the
    /// typographic family, "JetBrainsMono Nerd Font Mono". Both weights must land
    /// on the same one, which is what makes the regular/bold pair coherent.
    func testBothWeightsResolveToTheBundledFamily() throws {
        try XCTSkipUnless(TerminalFont.isBundledFontAvailable)

        let regular = TerminalFont.regular(size: 14)
        let bold = TerminalFont.bold(size: 14)

        XCTAssertEqual(regular.familyName, "JetBrainsMono Nerd Font Mono")
        XCTAssertEqual(bold.familyName, regular.familyName)
        // The fallback is the system monospace, so this also proves the bundled
        // font is the one in use rather than a silent substitution.
        XCTAssertNotEqual(regular.familyName, UIFont.monospacedSystemFont(ofSize: 14, weight: .regular).familyName)
    }

    /// The point of the font is the glyphs the system monospace lacks. U+E0B0 is
    /// the Powerline separator every themed prompt starts with.
    func testItHasThePowerlineGlyphs() throws {
        try XCTSkipUnless(TerminalFont.isBundledFontAvailable)

        let font = TerminalFont.regular(size: 14) as CTFont
        for scalar: UnicodeScalar in ["\u{E0B0}", "\u{E0B2}", "\u{F09B}"] {
            var characters = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            let mapped = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
            XCTAssertTrue(mapped, "U+\(String(scalar.value, radix: 16, uppercase: true)) is missing")
            XCTAssertNotEqual(glyphs.first, 0)
        }
    }
}
