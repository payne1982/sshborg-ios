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
        try assertGlyphsExist(["\u{E0B0}", "\u{E0B2}", "\u{F09B}"])
    }

    /// The bundled file is **not** stock: the Android build patched in the
    /// media-control triangles, and this app copied that patched file rather
    /// than one from upstream.
    ///
    /// Worth its own test because of how it would break — someone refreshes the
    /// font from the Nerd Fonts release page, everything still builds, every
    /// other glyph still renders, and only these seven quietly disappear. The
    /// repository also carries an unpatched JetBrains Mono under `res/font/`,
    /// so copying the wrong one is an easy mistake to make.
    func testItKeepsTheMediaControlGlyphsAddedOnAndroid() throws {
        try assertGlyphsExist([
            "\u{23F4}", "\u{23F5}", "\u{23F6}", "\u{23F7}",
            "\u{23F8}", "\u{23F9}", "\u{23FA}",
        ])
    }

    private func assertGlyphsExist(
        _ scalars: [UnicodeScalar],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try XCTSkipUnless(TerminalFont.isBundledFontAvailable)

        for weight in [TerminalFont.regular(size: 14), TerminalFont.bold(size: 14)] {
            let font = weight as CTFont
            for scalar in scalars {
                var characters = Array(String(scalar).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                let mapped = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)

                let name = "U+\(String(scalar.value, radix: 16, uppercase: true))"
                XCTAssertTrue(mapped, "\(name) missing from \(weight.fontName)", file: file, line: line)
                XCTAssertNotEqual(glyphs.first, 0, "\(name) maps to .notdef in \(weight.fontName)", file: file, line: line)
            }
        }
    }
}
