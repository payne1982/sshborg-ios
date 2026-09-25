// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// Keeps a `UITextView`'s colours in step with its text, a line at a time.
///
/// Android hands the file to sora-editor, which re-runs ``ConfigSyntax`` over
/// the whole text on a background thread after every edit and draws only the
/// lines on screen. UIKit gives us the drawing for free — `UITextView` lays out
/// lazily whatever the length — so what is left is the colouring, and doing it
/// whole on every keystroke is the one thing that would make a large file feel
/// slow.
///
/// So it is incremental, in the way a line-based lexer can be: each line is
/// coloured from the state the previous line left, that state is remembered, and
/// after an edit the work carries on downwards only while the state keeps
/// changing. For everything but XML the state is always "nothing carried", so a
/// one-line edit repaints one line; an XML comment opened at the top repaints
/// until the line where the carry settles again.
final class SyntaxHighlighter {

    var family: ConfigSyntax.Family

    /// What each line left open for the next one, by line index. Kept so an edit
    /// can stop as soon as the file's state is the same as it was.
    private var carried: [Bool] = []

    init(family: ConfigSyntax.Family) {
        self.family = family
    }

    // MARK: - Colours

    /// The palette, resolved against the view's current trait collection so a
    /// switch to dark mode is a re-colour and not a redesign.
    struct Palette {
        var plain: UIColor = .label
        var comment: UIColor = .systemGreen
        var string: UIColor = .systemOrange
        var number: UIColor = .systemPurple
        var keyword: UIColor = .systemBlue
        var key: UIColor = .systemTeal
        var tag: UIColor = .systemIndigo
        var variable: UIColor = .systemPink

        func colour(for token: ConfigSyntax.Token) -> UIColor {
            switch token {
            case .plain: return plain
            case .comment: return comment
            case .string: return string
            case .number: return number
            case .keyword: return keyword
            case .key: return key
            case .tag: return tag
            case .variable: return variable
            }
        }
    }

    var palette = Palette()
    var font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    // MARK: - Painting

    /// Colours the whole storage, which is what opening a file needs.
    func highlightAll(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        carried = []

        storage.beginEditing()
        storage.setAttributes(
            [.font: font, .foregroundColor: palette.plain],
            range: NSRange(location: 0, length: storage.length)
        )

        var open = false
        var line = 0
        var start = 0

        while start <= text.length {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            open = paint(text, lineRange: range, storage: storage, inComment: open)
            record(open, at: line)
            line += 1

            if range.length == 0 { break }
            start = range.location + range.length
            if start >= text.length { break }
        }

        storage.endEditing()
    }

    /// Re-colours what an edit touched, and only as far down as it reaches.
    ///
    /// `edited` is the range of the text *after* the change, as the text storage
    /// reports it.
    func update(_ storage: NSTextStorage, edited: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else {
            carried = []
            return
        }

        // Start at the beginning of the first line the edit touched, and with
        // the state the line before it left — which is what makes this safe to
        // do out of the middle of a file.
        let safeLocation = min(edited.location, text.length - 1)
        var range = text.lineRange(for: NSRange(location: safeLocation, length: 0))
        var line = lineIndex(of: range.location, in: text)
        var open = line > 0 && line - 1 < carried.count ? carried[line - 1] : false

        let touchedEnd = min(NSMaxRange(edited), text.length)

        storage.beginEditing()
        while true {
            let before = line < carried.count ? carried[line] : nil
            open = paint(text, lineRange: range, storage: storage, inComment: open)
            record(open, at: line)

            let end = range.location + range.length
            if end >= text.length { break }

            // Past the edit, a line whose carried state is unchanged colours
            // every line below it exactly as they already are.
            if end >= touchedEnd, before == open { break }

            range = text.lineRange(for: NSRange(location: end, length: 0))
            line += 1
        }
        storage.endEditing()
    }

    /// Colours one line and returns what it leaves open.
    @discardableResult
    private func paint(
        _ text: NSString,
        lineRange: NSRange,
        storage: NSTextStorage,
        inComment: Bool
    ) -> Bool {
        let line = text.substring(with: lineRange)
        storage.addAttributes(
            [.font: font, .foregroundColor: palette.plain],
            range: lineRange
        )

        let result = ConfigSyntax.highlight(line, family: family, inComment: inComment)

        // `ConfigSyntax` counts in characters, `NSString` in UTF-16 units, and
        // they differ the moment a file has an emoji or a CJK ideograph in it.
        // The map is built once per line rather than guessed.
        let offsets = utf16Offsets(of: line)

        for run in result.runs {
            guard run.start < offsets.count, run.end < offsets.count else { continue }
            let location = lineRange.location + offsets[run.start]
            let length = offsets[run.end] - offsets[run.start]
            guard length > 0, location + length <= NSMaxRange(lineRange) else { continue }

            storage.addAttribute(
                .foregroundColor,
                value: palette.colour(for: run.token),
                range: NSRange(location: location, length: length)
            )
        }

        return result.inComment
    }

    /// For each character index, how many UTF-16 units precede it — with one
    /// extra entry at the end, so a run's exclusive end can be looked up too.
    private func utf16Offsets(of line: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(line.count + 1)

        var total = 0
        for character in line {
            offsets.append(total)
            total += character.utf16.count
        }
        offsets.append(total)
        return offsets
    }

    private func record(_ open: Bool, at line: Int) {
        if line < carried.count {
            carried[line] = open
        } else {
            while carried.count < line { carried.append(false) }
            carried.append(open)
        }
    }

    /// Which line a location falls on. Counted rather than kept, because an edit
    /// that adds or removes lines moves every index below it.
    private func lineIndex(of location: Int, in text: NSString) -> Int {
        var index = 0
        var start = 0
        while start < location {
            let range = text.lineRange(for: NSRange(location: start, length: 0))
            let end = range.location + range.length
            if end > location || range.length == 0 { break }
            start = end
            index += 1
        }
        return index
    }
}
