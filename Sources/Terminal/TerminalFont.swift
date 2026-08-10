// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// The terminal typeface.
///
/// The app bundles JetBrains Mono Nerd Font Mono, the same file the Android
/// build ships, because a prompt built with Powerline or Nerd Font glyphs — the
/// arrows and branch symbols `starship`, `oh-my-posh` and most zsh themes emit —
/// renders as replacement boxes in any system monospace font. That is not a
/// cosmetic loss: the prompt is the first thing on screen and it looks broken.
///
/// Roughly 4.9 MB for both weights, which is the cost of it. The licence is
/// SIL OFL 1.1 and `OFL.txt` ships beside the fonts, as that licence requires.
///
/// Falls back to the system monospace font if the family is ever missing, so a
/// packaging mistake degrades the glyphs rather than crashing the terminal.
enum TerminalFont {

    /// PostScript names, which is what `UIFont(name:)` matches — not the family
    /// name and not the file name. Every one of them differs here, which is why
    /// this is written down rather than guessed:
    ///
    /// - file: `JetBrainsMonoNerdFontMono-Regular.ttf`
    /// - `name` table, first family record: `JetBrainsMono NFM`
    /// - family CoreText reports: `JetBrainsMono Nerd Font Mono`
    /// - PostScript name, the one below: `JetBrainsMonoNFM-Regular`
    private static let regularName = "JetBrainsMonoNFM-Regular"
    private static let boldName = "JetBrainsMonoNFM-Bold"

    static func regular(size: CGFloat) -> UIFont {
        UIFont(name: regularName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func bold(size: CGFloat) -> UIFont {
        UIFont(name: boldName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// Whether the bundled font actually loaded.
    ///
    /// Registering a font through `UIAppFonts` fails silently: a wrong file name
    /// in the plist, or a file left out of the target, leaves the app running
    /// with the system font and no error anywhere. This is what the test asserts.
    static var isBundledFontAvailable: Bool {
        UIFont(name: regularName, size: 12) != nil
    }
}
