// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Description of the terminal's extra-key bar: one to three rows of keys, a
/// font size, and per row whether the keys stretch to the width or keep their
/// natural size and scroll.
///
/// Ported from the Android `ExtraBar` (issue #12 there). Presets live in
/// ``ExtraBarPresets``; custom bars are the same type persisted as JSON by
/// ``ExtraBarJSON``, in the shape the Android app writes, so a settings backup
/// carries them between the two platforms.
struct ExtraBar: Equatable, Identifiable {

    static let presetPrefix = "preset:"
    static let customPrefix = "custom:"
    static let maxRows = 3

    /// `preset:<name>` or `custom:<uuid>`.
    var id: String

    /// Display name of a custom bar; presets resolve theirs from the catalog,
    /// see ``localizedName``.
    var name: String

    var rows: [ExtraBarRow]

    var fontScale: BarFontScale = .small

    var isPreset: Bool { id.hasPrefix(Self.presetPrefix) }

    /// What to call the bar on screen: a preset's translated name, or the name
    /// the user typed.
    var localizedName: String {
        isPreset ? String(localized: ExtraBarPresets.nameResource(for: id)) : name
    }

    /// Whether any row already carries the show/hide keyboard action, in which
    /// case the bar must not add its own copy on iPhone. See
    /// ``ExtraKeyBar`` for why that key is there at all.
    var containsKeyboardAction: Bool {
        rows.contains { row in row.keys.contains { $0 == .action(.keyboard) } }
    }

    static func newCustomID() -> String {
        customPrefix + UUID().uuidString.lowercased()
    }
}

struct ExtraBarRow: Equatable {

    var keys: [ExtraKeyDef]

    /// `true`: the keys share the row's width equally. `false`: natural widths,
    /// and the row scrolls sideways.
    var fit = false
}

/// The three key sizes. Raw values are the names Android stores, so a bar
/// written there reads here.
enum BarFontScale: String, CaseIterable {
    case small = "SMALL"
    case medium = "MEDIUM"
    case large = "LARGE"

    /// Android's 12/14/16 sp, taken as points.
    var pointSize: CGFloat {
        switch self {
        case .small: 12
        case .medium: 14
        case .large: 16
        }
    }

    var localizedName: String {
        switch self {
        case .small: String(localized: .extraBarFontSmall)
        case .medium: String(localized: .extraBarFontMedium)
        case .large: String(localized: .extraBarFontLarge)
        }
    }
}

/// Fixed terminal keys. Arrows are resolved through the emulator's cursor-key
/// mode; everything else is a constant sequence.
enum SpecialKey: String, CaseIterable {
    case esc = "ESC", tab = "TAB", enter = "ENTER", bksp = "BKSP", del = "DEL", ins = "INS"
    case home = "HOME", end = "END", pgup = "PGUP", pgdn = "PGDN"
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT"
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6"
    case f7 = "F7", f8 = "F8", f9 = "F9", f10 = "F10", f11 = "F11", f12 = "F12"

    var label: String {
        switch self {
        case .esc: "ESC"
        case .tab: "Tab"
        case .enter: "Enter"
        case .bksp: "⌫"
        case .del: "Del"
        case .ins: "Ins"
        case .home: "Home"
        case .end: "End"
        case .pgup: "PgUp"
        case .pgdn: "PgDn"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        default: rawValue
        }
    }

    /// Holding keeps firing, the way the keyboard's own backspace behaves. A
    /// property of the key, not something the user sets: repeating Esc or Tab
    /// would be a bug, not a feature.
    var repeats: Bool {
        switch self {
        case .bksp, .del, .pgup, .pgdn, .up, .down, .left, .right: true
        default: false
        }
    }

    var isArrow: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }

    var isFunctionKey: Bool { rawValue.hasPrefix("F") }

    /// The bytes to send. `cursorKeys` maps a CSI final character (A/B/C/D)
    /// honouring application-cursor mode, which only the session knows.
    ///
    /// F1–F4 use the SS3 form, F5 upwards the CSI form. That split is what
    /// xterm sends and what curses applications expect.
    func bytes(cursorKeys: (Character) -> Data) -> Data {
        switch self {
        case .esc: Data([0x1B])
        case .tab: Data([0x09])
        case .enter: Data([0x0D])
        case .bksp: Data([0x7F])
        case .del: Self.escape("[3~")
        case .ins: Self.escape("[2~")
        case .home: Self.escape("[H")
        case .end: Self.escape("[F")
        case .pgup: Self.escape("[5~")
        case .pgdn: Self.escape("[6~")
        case .up: cursorKeys("A")
        case .down: cursorKeys("B")
        case .right: cursorKeys("C")
        case .left: cursorKeys("D")
        case .f1: Self.escape("OP")
        case .f2: Self.escape("OQ")
        case .f3: Self.escape("OR")
        case .f4: Self.escape("OS")
        case .f5: Self.escape("[15~")
        case .f6: Self.escape("[17~")
        case .f7: Self.escape("[18~")
        case .f8: Self.escape("[19~")
        case .f9: Self.escape("[20~")
        case .f10: Self.escape("[21~")
        case .f11: Self.escape("[23~")
        case .f12: Self.escape("[24~")
        }
    }

    private static func escape(_ tail: String) -> Data {
        Data([0x1B]) + Data(tail.utf8)
    }
}

/// Sticky one-shot modifiers, applied to the next byte by the session.
enum ModKey: String, CaseIterable {
    case ctrl = "CTRL"
    case alt = "ALT"

    var label: String {
        switch self {
        case .ctrl: "Ctrl"
        case .alt: "Alt"
        }
    }
}

/// Bar and app actions, drawn as icon keys.
enum BarAction: String, CaseIterable {
    case paste = "PASTE"
    case pin = "PIN"
    case wordMode = "WORD_MODE"
    case switchBar = "SWITCH_BAR"
    case keyboard = "KEYBOARD"

    var localizedName: String {
        switch self {
        case .paste: String(localized: .extraKeyActionPaste)
        case .pin: String(localized: .extraKeyActionPin)
        case .wordMode: String(localized: .extraKeyActionWordMode)
        case .switchBar: String(localized: .extraKeyActionSwitch)
        case .keyboard: String(localized: .extraKeyActionKeyboard)
        }
    }
}

/// One key on the bar.
enum ExtraKeyDef: Equatable {
    case special(SpecialKey, label: String? = nil)
    case modifier(ModKey)
    /// Literal text sent as-is; `\n \r \t \e \\` escapes are expanded by
    /// ``unescaped``. Several characters make a macro.
    case text(String, label: String? = nil)
    case action(BarAction)

    /// The label drawn on the key. Actions draw icons instead and return "".
    var displayLabel: String {
        switch self {
        case .special(let key, let label):
            return label.flatMap { $0.isEmpty ? nil : $0 } ?? key.label
        case .modifier(let mod):
            return mod.label
        case .text(let text, let label):
            return label.flatMap { $0.isEmpty ? nil : $0 } ?? text
        case .action:
            return ""
        }
    }

    var repeatsOnHold: Bool {
        if case .special(let key, _) = self { return key.repeats }
        return false
    }

    var isArrow: Bool {
        if case .special(let key, _) = self { return key.isArrow }
        return false
    }

    /// The text of a text key with its escapes expanded.
    var unescaped: String? {
        if case .text(let text, _) = self { return unescapeKeyText(text) }
        return nil
    }
}

/// Expands `\n \r \t \e \\` in the text of a custom key. Anything else after a
/// backslash is kept as typed, backslash included.
func unescapeKeyText(_ text: String) -> String {
    guard text.contains("\\") else { return text }
    var out = ""
    var iterator = text.makeIterator()
    while let char = iterator.next() {
        guard char == "\\" else {
            out.append(char)
            continue
        }
        guard let next = iterator.next() else {
            out.append(char)
            break
        }
        switch next {
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "e": out.append("\u{1B}")
        case "\\": out.append("\\")
        default:
            out.append("\\")
            out.append(next)
        }
    }
    return out
}

// MARK: - Presets

/// The built-in layouts. Never persisted, so they may change between versions
/// without a migration.
///
/// Key for key the Android presets, deliberately: someone moving between the
/// two builds should find the same bar. The one iOS-only key, show/hide
/// keyboard, is not in any preset — the bar adds it on iPhone outside the rows,
/// see ``ExtraKeyBar``.
enum ExtraBarPresets {

    static let standardID = ExtraBar.presetPrefix + "standard"
    static let naturalID = ExtraBar.presetPrefix + "natural"
    static let natural2ID = ExtraBar.presetPrefix + "natural_2"
    static let natural3ID = ExtraBar.presetPrefix + "natural_3"
    static let minimalID = ExtraBar.presetPrefix + "minimal"

    private static func sp(_ key: SpecialKey) -> ExtraKeyDef { .special(key) }
    private static func mod(_ mod: ModKey) -> ExtraKeyDef { .modifier(mod) }
    private static func txt(_ text: String) -> ExtraKeyDef { .text(text) }
    private static func act(_ action: BarAction) -> ExtraKeyDef { .action(action) }

    private static let fKeys: [ExtraKeyDef] = SpecialKey.allCases.filter(\.isFunctionKey).map { .special($0) }

    /// The bar as it has always been: one scrolling row.
    static let standard = ExtraBar(
        id: standardID, name: "",
        rows: [ExtraBarRow(keys: [
            mod(.ctrl), mod(.alt), act(.wordMode),
            sp(.esc), sp(.tab),
            sp(.up), sp(.down), sp(.left), sp(.right),
            sp(.home), sp(.end), sp(.pgup), sp(.pgdn),
            sp(.del), act(.paste), act(.pin),
        ] + fKeys + [act(.switchBar)])],
        fontScale: .small
    )

    /// One scrolling row ordered by frequency of use: modifiers and ESC/Tab
    /// first, the shell symbols hidden behind a layer on phone keyboards,
    /// arrows in physical-keyboard order (← ↑ ↓ →), page navigation, then the
    /// F keys in the tail.
    static let natural = ExtraBar(
        id: naturalID, name: "",
        rows: [ExtraBarRow(keys: [
            sp(.esc), sp(.tab), mod(.ctrl), mod(.alt), act(.wordMode),
            txt("/"), txt("-"), txt("|"), txt("~"),
            sp(.left), sp(.up), sp(.down), sp(.right),
            sp(.home), sp(.end), sp(.pgup), sp(.pgdn),
            sp(.del), act(.paste), act(.pin),
        ] + fKeys + [act(.switchBar)])],
        fontScale: .medium
    )

    /// The widespread two-row arrangement: arrows in a cross, page keys at the
    /// ends. Nine columns in each row, so the cross lines up.
    private static let naturalRows = [
        ExtraBarRow(keys: [
            sp(.esc), txt("/"), txt("-"), sp(.home), sp(.up),
            sp(.end), sp(.pgup), act(.paste), act(.pin),
        ], fit: true),
        ExtraBarRow(keys: [
            sp(.tab), mod(.ctrl), mod(.alt), sp(.left), sp(.down),
            sp(.right), sp(.pgdn), act(.wordMode), act(.switchBar),
        ], fit: true),
    ]

    static let natural2 = ExtraBar(id: natural2ID, name: "", rows: naturalRows, fontScale: .medium)

    static let natural3 = ExtraBar(
        id: natural3ID, name: "",
        rows: naturalRows + [ExtraBarRow(keys: fKeys, fit: false)],
        fontScale: .medium
    )

    static let minimal = ExtraBar(
        id: minimalID, name: "",
        rows: [ExtraBarRow(keys: [
            sp(.esc), sp(.tab), mod(.ctrl),
            sp(.up), sp(.down), sp(.left), sp(.right),
            act(.switchBar),
        ], fit: true)],
        fontScale: .medium
    )

    static let all: [ExtraBar] = [standard, natural, natural2, natural3, minimal]

    static func byID(_ id: String) -> ExtraBar? {
        all.first { $0.id == id }
    }

    static func nameResource(for id: String) -> LocalizedStringResource {
        switch id {
        case naturalID: .extraBarPresetNatural
        case natural2ID: .extraBarPresetNatural2
        case natural3ID: .extraBarPresetNatural3
        case minimalID: .extraBarPresetMinimal
        default: .extraBarPresetStandard
        }
    }
}

// MARK: - JSON

/// (De)serialiser for custom bars, in the Android shape:
///
///     {"format":1,"id":"custom:…","name":"…","font":"MEDIUM",
///      "rows":[{"fit":true,"keys":[{"k":"special","v":"ESC","l":"Esc"}, …]}]}
///
/// Tolerant on the way in, like the Android reader: an unknown key kind or
/// value is dropped rather than failing, so a bar from a newer version loses
/// a key instead of the whole bar. A bar whose id is not `custom:` is refused —
/// presets are never stored, and a file claiming one is not to be trusted.
enum ExtraBarJSON {

    static let format = 1

    static func encode(_ bar: ExtraBar) -> [String: Any] {
        [
            "format": format,
            "id": bar.id,
            "name": bar.name,
            "font": bar.fontScale.rawValue,
            "rows": bar.rows.map { row -> [String: Any] in
                ["fit": row.fit, "keys": row.keys.map(encode)]
            },
        ]
    }

    static func encodeAll(_ bars: [ExtraBar]) -> [[String: Any]] {
        bars.map(encode)
    }

    /// The array as one string, which is how the preference stores it.
    static func encodeAllToString(_ bars: [ExtraBar]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: encodeAll(bars)),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    static func decode(_ object: [String: Any]) -> ExtraBar? {
        guard let id = object["id"] as? String, id.hasPrefix(ExtraBar.customPrefix) else { return nil }
        let font = (object["font"] as? String).flatMap(BarFontScale.init(rawValue:)) ?? .small
        guard let rawRows = object["rows"] as? [Any] else { return nil }

        let rows = rawRows.prefix(ExtraBar.maxRows).compactMap { raw -> ExtraBarRow? in
            guard let row = raw as? [String: Any] else { return nil }
            let keys = (row["keys"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap(decodeKey)
            return ExtraBarRow(keys: keys, fit: row["fit"] as? Bool ?? false)
        }
        guard !rows.isEmpty else { return nil }

        return ExtraBar(id: id, name: object["name"] as? String ?? "", rows: rows, fontScale: font)
    }

    static func decodeAll(_ array: [Any]) -> [ExtraBar] {
        array.compactMap { $0 as? [String: Any] }.compactMap(decode)
    }

    static func decodeAll(_ json: String?) -> [ExtraBar] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return decodeAll(array)
    }

    private static func encode(_ key: ExtraKeyDef) -> [String: Any] {
        switch key {
        case .special(let special, let label):
            var object: [String: Any] = ["k": "special", "v": special.rawValue]
            if let label { object["l"] = label }
            return object
        case .modifier(let mod):
            return ["k": "mod", "v": mod.rawValue]
        case .text(let text, let label):
            var object: [String: Any] = ["k": "text", "v": text]
            if let label { object["l"] = label }
            return object
        case .action(let action):
            return ["k": "action", "v": action.rawValue]
        }
    }

    private static func decodeKey(_ object: [String: Any]) -> ExtraKeyDef? {
        let value = object["v"] as? String ?? ""
        let label = object["l"] as? String
        switch object["k"] as? String {
        case "special": return SpecialKey(rawValue: value).map { .special($0, label: label) }
        case "mod": return ModKey(rawValue: value).map { .modifier($0) }
        case "text": return .text(value, label: label)
        case "action": return BarAction(rawValue: value).map { .action($0) }
        default: return nil
        }
    }
}
