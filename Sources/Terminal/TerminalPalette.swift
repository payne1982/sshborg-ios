// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftTerm
import SwiftUI
import UIKit

/// The colours a terminal is drawn in.
///
/// Ported from the Android `TerminalView`, which keeps two palettes and swaps
/// between them on a `lightScheme` flag. The values below are copied from there
/// rather than chosen: the two apps read the same servers, and a `ls` that comes
/// out a different green on one of them is a difference nobody asked for.
///
/// It is a value type with no view in it so the choice can be tested. What it
/// gets applied to is `TerminalHostView`.
struct TerminalPalette {

    /// The 16 ANSI colours. SwiftTerm derives 16-255 — the 6×6×6 cube and the
    /// greyscale ramp — from these, which is what Android does too by sharing
    /// that whole range between its two palettes.
    let ansi: [SwiftTerm.Color]

    /// What text with no colour of its own is drawn in.
    let foreground: UIColor

    /// The background, and the colour anything that has to sit flush against
    /// the terminal must match.
    let background: UIColor

    /// Android draws the cursor as a filled cell in the default foreground at
    /// alpha 180, which is where the 0.706 comes from.
    let caret: UIColor

    /// Android's dark palette is the classic VGA one, entry for entry.
    ///
    /// Spelled out rather than taken from `SwiftTerm.Color.vgaColors`, which is
    /// the same sixteen values: that property is internal in SwiftTerm 1.15.0,
    /// the version pinned here. Writing them out is no loss — the source of
    /// truth is `TerminalView.kt`, not the library, and this way the numbers sit
    /// next to the ones the light palette changes.
    ///
    /// Worth saying out loud that installing them is a real change and not a
    /// no-op: SwiftTerm installs `terminalAppColors` by default, so until now
    /// the iOS terminal drew Apple's Terminal.app colours while Android drew
    /// VGA. The same `ls` really did come out a different green.
    ///
    /// ⚠️ And it is not a free change. Measured on 04/09/2026, VGA is the
    /// *worse* of the two on black: three entries fall below a 3.0 contrast
    /// ratio — blue (4) at 1.58, red (1) at 2.71, bright black (8) at 2.82 —
    /// where Apple's palette has one. Apple chose its sixteen looking at a
    /// black background; VGA inherited them from 1987 hardware.
    ///
    /// Kept anyway, and deliberately: matching Android matters more than the
    /// margin, the same weakness is there on Android so the two apps behave
    /// alike, and the practical cost is small — `ls` colours directories with
    /// *bright* blue (12), which measures 4.13 on black. The 1.58 case is plain
    /// blue, which turns up in some prompts and syntax highlighting rather than
    /// in everyday output. Decided with him, with the numbers in front of us.
    ///
    /// If it is ever revisited, the best-legibility pairing is Apple's palette
    /// on black with Android's on white — at the cost of the parity.
    static let dark = TerminalPalette(
        ansi: [
            rgb(0, 0, 0), rgb(170, 0, 0), rgb(0, 170, 0), rgb(170, 85, 0),
            rgb(0, 0, 170), rgb(170, 0, 170), rgb(0, 170, 170), rgb(170, 170, 170),
            rgb(85, 85, 85), rgb(255, 85, 85), rgb(85, 255, 85), rgb(255, 255, 85),
            rgb(85, 85, 255), rgb(255, 85, 255), rgb(85, 255, 255), rgb(255, 255, 255),
        ],
        foreground: UIColor(red: 204 / 255, green: 204 / 255, blue: 204 / 255, alpha: 1),
        background: .black,
        caret: UIColor(red: 204 / 255, green: 204 / 255, blue: 204 / 255, alpha: 180 / 255)
    )

    /// Same hues, with the entries that are unreadable on white darkened.
    ///
    /// Copied from Android's `lightPalette` exactly, **including what it leaves
    /// alone**: bright blue (12) keeps its (85, 85, 255) on white here as it
    /// does there. That reads like an omission and is not — measured, it is a
    /// WCAG contrast ratio of 5.09 against white, comfortably above the 3.0
    /// floor. It was left alone because it did not need darkening.
    ///
    /// The seven that are changed all sit below 3.0 untouched. Bright white
    /// (15) is the extreme: 1.20 on white, which is invisible.
    static let light = TerminalPalette(
        ansi: {
            var colors = dark.ansi
            colors[7] = rgb(115, 115, 115)
            colors[9] = rgb(220, 50, 50)
            colors[10] = rgb(0, 135, 0)
            colors[11] = rgb(140, 120, 0)
            colors[13] = rgb(200, 50, 200)
            colors[14] = rgb(0, 145, 160)
            colors[15] = rgb(50, 50, 50)
            return colors
        }(),
        foreground: UIColor(red: 51 / 255, green: 51 / 255, blue: 51 / 255, alpha: 1),
        background: .white,
        caret: UIColor(red: 51 / 255, green: 51 / 255, blue: 51 / 255, alpha: 180 / 255)
    )

    /// Android writes its colours as 8-bit channels; SwiftTerm's public
    /// initialiser takes 16-bit ones. 257 and not 256 is the expansion that
    /// keeps the ends: 255 × 257 = 65535, where 255 × 256 would fall one short
    /// of white.
    private static func rgb(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    /// Which palette the preference asks for.
    ///
    /// `app` is the appearance the app is actually showing, which is not the
    /// same as the system's: `nightMode` can override it. Android resolves
    /// "follow app" against its own `nightMode` for exactly that reason, and
    /// here the caller reads `\.colorScheme` from below the root's
    /// `preferredColorScheme`, which has already done that resolution.
    static func resolve(
        _ scheme: AppPreferences.TerminalColorScheme,
        app: ColorScheme
    ) -> TerminalPalette {
        switch scheme {
        case .dark: .dark
        case .light: .light
        case .followApp: app == .light ? .light : .dark
        }
    }
}
