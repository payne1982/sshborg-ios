// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// The extra-key bar's model: the presets, the escapes in a custom text key,
/// and the JSON that has to survive a trip through the Android app.
final class ExtraBarTests: XCTestCase {

    // MARK: - Presets

    /// Every preset carries the switch key. Without it the only way back to
    /// another bar is three screens away in Settings, which is the friction the
    /// on-bar switch exists to remove — and a bar you cannot leave from is a
    /// trap for anyone who picked "Minimal" to see what it was.
    func testEveryPresetCanSwitchAway() {
        for bar in ExtraBarPresets.all {
            let keys = bar.rows.flatMap(\.keys)
            XCTAssertTrue(
                keys.contains(.action(.switchBar)),
                "\(bar.id) has no switch key"
            )
        }
    }

    func testPresetsHaveAtMostThreeRowsAndAtLeastOneKey() {
        for bar in ExtraBarPresets.all {
            XCTAssertLessThanOrEqual(bar.rows.count, ExtraBar.maxRows, bar.id)
            XCTAssertFalse(bar.rows.allSatisfy(\.keys.isEmpty), bar.id)
        }
    }

    /// The two-row preset is the arrangement the Android issue asked for, and
    /// its point is that the arrows line up in a cross. That only works if both
    /// rows have the same number of columns and both stretch to the width.
    func testTheTwoRowPresetHasAlignedColumns() {
        let rows = ExtraBarPresets.natural2.rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].keys.count, rows[1].keys.count)
        XCTAssertTrue(rows.allSatisfy(\.fit))
    }

    func testPresetIDsAreDistinctAndMarkedAsPresets() {
        let ids = ExtraBarPresets.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ExtraBarPresets.all.allSatisfy(\.isPreset))
    }

    func testAnUnknownIDResolvesToNothingRatherThanTheWrongBar() {
        XCTAssertNil(ExtraBarPresets.byID("preset:invented"))
        XCTAssertNil(ExtraBarPresets.byID("custom:00000000"))
    }

    // MARK: - Keys

    /// F1–F4 use the SS3 form and F5 upwards the CSI form. That split is what
    /// xterm sends, and getting it wrong is invisible until someone presses F3
    /// in an editor that has bound it.
    func testFunctionKeysUseTheFormsXtermSends() {
        let cursor: (Character) -> Data = { _ in Data() }
        XCTAssertEqual(SpecialKey.f1.bytes(cursorKeys: cursor), Data("\u{1B}OP".utf8))
        XCTAssertEqual(SpecialKey.f4.bytes(cursorKeys: cursor), Data("\u{1B}OS".utf8))
        XCTAssertEqual(SpecialKey.f5.bytes(cursorKeys: cursor), Data("\u{1B}[15~".utf8))
        XCTAssertEqual(SpecialKey.f12.bytes(cursorKeys: cursor), Data("\u{1B}[24~".utf8))
    }

    /// Arrows are the one kind of key whose bytes are not fixed: they go
    /// through the session, because only it knows whether the program on the
    /// far end has asked for application-cursor mode.
    func testArrowsAskTheSessionRatherThanHardcodingTheSequence() {
        let cursor: (Character) -> Data = { Data("APPLIED-\($0)".utf8) }
        XCTAssertEqual(SpecialKey.up.bytes(cursorKeys: cursor), Data("APPLIED-A".utf8))
        XCTAssertEqual(SpecialKey.down.bytes(cursorKeys: cursor), Data("APPLIED-B".utf8))
        XCTAssertEqual(SpecialKey.right.bytes(cursorKeys: cursor), Data("APPLIED-C".utf8))
        XCTAssertEqual(SpecialKey.left.bytes(cursorKeys: cursor), Data("APPLIED-D".utf8))
    }

    func testOnlyKeysWorthRepeatingRepeat() {
        XCTAssertTrue(SpecialKey.left.repeats)
        XCTAssertTrue(SpecialKey.bksp.repeats)
        XCTAssertTrue(SpecialKey.pgdn.repeats)
        // Repeating these would be a bug, not a feature.
        XCTAssertFalse(SpecialKey.esc.repeats)
        XCTAssertFalse(SpecialKey.tab.repeats)
        XCTAssertFalse(SpecialKey.enter.repeats)
        XCTAssertFalse(SpecialKey.f1.repeats)
    }

    // MARK: - Text keys

    func testEscapesBecomeTheCharactersTheyName() {
        XCTAssertEqual(unescapeKeyText("ls -la\\n"), "ls -la\n")
        XCTAssertEqual(unescapeKeyText("a\\tb"), "a\tb")
        XCTAssertEqual(unescapeKeyText("\\e[A"), "\u{1B}[A")
        XCTAssertEqual(unescapeKeyText("\\r"), "\r")
    }

    func testADoubledBackslashIsOneBackslash() {
        XCTAssertEqual(unescapeKeyText("C:\\\\path"), "C:\\path")
    }

    /// A backslash before anything else is not an escape, and dropping it would
    /// silently change what a key sends. `\d` in a regular expression typed
    /// into a macro is the case this protects.
    func testAnUnknownEscapeKeepsItsBackslash() {
        XCTAssertEqual(unescapeKeyText("\\d+"), "\\d+")
        XCTAssertEqual(unescapeKeyText("ends with \\"), "ends with \\")
    }

    func testTextWithNoBackslashIsUntouched() {
        XCTAssertEqual(unescapeKeyText("sudo "), "sudo ")
    }

    /// A text key shows its own text unless it was given a label, which is what
    /// lets `ls -la\n` sit on the bar as "ll".
    func testALabelReplacesTheTextOnTheKeyFace() {
        XCTAssertEqual(ExtraKeyDef.text("ls -la\\n").displayLabel, "ls -la\\n")
        XCTAssertEqual(ExtraKeyDef.text("ls -la\\n", label: "ll").displayLabel, "ll")
        // An empty label is not a label.
        XCTAssertEqual(ExtraKeyDef.text("~", label: "").displayLabel, "~")
    }

    // MARK: - JSON

    func testACustomBarSurvivesARoundTrip() throws {
        let bar = ExtraBar(
            id: "custom:abc",
            name: "Mine",
            rows: [
                ExtraBarRow(keys: [.special(.esc), .modifier(.ctrl), .text("~")], fit: true),
                ExtraBarRow(keys: [.action(.paste), .special(.f7, label: "Run")], fit: false),
            ],
            fontScale: .large
        )

        let decoded = try XCTUnwrap(ExtraBarJSON.decode(ExtraBarJSON.encode(bar)))
        XCTAssertEqual(decoded, bar)
    }

    func testTheStringFormRoundTripsTheWholeList() {
        let bars = [
            ExtraBar(id: "custom:1", name: "One", rows: [ExtraBarRow(keys: [.special(.tab)])]),
            ExtraBar(id: "custom:2", name: "Two", rows: [ExtraBarRow(keys: [.action(.pin)], fit: true)]),
        ]
        XCTAssertEqual(ExtraBarJSON.decodeAll(ExtraBarJSON.encodeAllToString(bars)), bars)
    }

    /// Written by the Android app. A reader tested only against our own writer
    /// would agree with our own mistakes, which is the whole point of the
    /// shared format.
    func testReadsABarWrittenByAndroid() throws {
        let json = """
        [{"format":1,"id":"custom:9f3","name":"Phone","font":"MEDIUM",
          "rows":[{"fit":true,"keys":[
            {"k":"special","v":"ESC"},
            {"k":"mod","v":"CTRL"},
            {"k":"text","v":"ls -la\\\\n","l":"ll"},
            {"k":"action","v":"SWITCH_BAR"}]}]}]
        """

        let bars = ExtraBarJSON.decodeAll(json)
        XCTAssertEqual(bars.count, 1)

        let bar = try XCTUnwrap(bars.first)
        XCTAssertEqual(bar.name, "Phone")
        XCTAssertEqual(bar.fontScale, .medium)
        XCTAssertEqual(bar.rows.count, 1)
        XCTAssertTrue(bar.rows[0].fit)
        XCTAssertEqual(bar.rows[0].keys, [
            .special(.esc),
            .modifier(.ctrl),
            .text("ls -la\\n", label: "ll"),
            .action(.switchBar),
        ])
    }

    /// A newer version of either app may invent a key kind. Losing that one key
    /// is a bar with a gap in it; failing the parse is a user who lost every
    /// bar they had.
    func testAnUnknownKeyIsDroppedAndTheRestOfTheBarSurvives() throws {
        let json = """
        [{"id":"custom:1","name":"N","font":"SMALL","rows":[{"fit":false,"keys":[
          {"k":"special","v":"ESC"},
          {"k":"special","v":"MOON"},
          {"k":"invented","v":"X"},
          {"k":"action","v":"TELEPORT"},
          {"k":"mod","v":"ALT"}]}]}]
        """

        let bar = try XCTUnwrap(ExtraBarJSON.decodeAll(json).first)
        XCTAssertEqual(bar.rows[0].keys, [.special(.esc), .modifier(.alt)])
    }

    func testAnUnknownFontFallsBackRatherThanFailing() throws {
        let json = #"[{"id":"custom:1","name":"N","font":"ENORMOUS","rows":[{"keys":[{"k":"mod","v":"CTRL"}]}]}]"#
        let bar = try XCTUnwrap(ExtraBarJSON.decodeAll(json).first)
        XCTAssertEqual(bar.fontScale, .small)
    }

    /// Presets are code, never storage. A file claiming to carry one is either
    /// hand-edited or from a version that changed its mind, and honouring it
    /// would let a stale copy shadow the real preset for good.
    func testABarClaimingToBeAPresetIsRefused() {
        let json = #"[{"id":"preset:standard","name":"Fake","rows":[{"keys":[{"k":"mod","v":"CTRL"}]}]}]"#
        XCTAssertTrue(ExtraBarJSON.decodeAll(json).isEmpty)
    }

    func testABarWithNoUsableRowsIsRefused() {
        XCTAssertTrue(ExtraBarJSON.decodeAll(#"[{"id":"custom:1","name":"N"}]"#).isEmpty)
        XCTAssertTrue(ExtraBarJSON.decodeAll(#"[{"id":"custom:1","name":"N","rows":[]}]"#).isEmpty)
    }

    func testGarbageDecodesToNothingRatherThanCrashing() {
        XCTAssertTrue(ExtraBarJSON.decodeAll(nil).isEmpty)
        XCTAssertTrue(ExtraBarJSON.decodeAll("").isEmpty)
        XCTAssertTrue(ExtraBarJSON.decodeAll("not json at all").isEmpty)
        XCTAssertTrue(ExtraBarJSON.decodeAll(#"{"not":"an array"}"#).isEmpty)
    }

    /// Three rows is the ceiling: a fourth would push the terminal off the
    /// screen on a phone in landscape.
    func testMoreRowsThanAllowedAreTruncatedOnLoad() throws {
        let row = #"{"fit":true,"keys":[{"k":"mod","v":"CTRL"}]}"#
        let json = #"[{"id":"custom:1","name":"N","rows":[\#(row),\#(row),\#(row),\#(row)]}]"#
        let bar = try XCTUnwrap(ExtraBarJSON.decodeAll(json).first)
        XCTAssertEqual(bar.rows.count, ExtraBar.maxRows)
    }
}
