// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A small syntax highlighter for the files people actually edit over SFTP.
///
/// A port of the Android `ConfigSyntax`, which is the app's own code rather than
/// anything taken from a grammar collection — on Android the editor *widget* is
/// sora-editor, a third-party dependency, but the colouring is this, and this is
/// what crosses. Here it feeds a `UITextView` instead, so no editor library is
/// needed at all.
///
/// It stays deliberately small: the families below cover configuration files,
/// which is what this editor is for, and everything else is left in plain text
/// rather than coloured by guesswork. Highlighting is appearance only — the
/// bytes go back exactly as they came whatever colour they were shown in — so
/// the worst a mistake here can do is look wrong.
///
/// It reads character by character instead of matching regular expressions,
/// which is what keeps it honest on the cases that catch naive highlighters: a
/// `#` inside a quoted string is not a comment, an apostrophe in a comment does
/// not open a string, and the `//` in a URL is not the start of anything.
enum ConfigSyntax {

    /// What a run of characters is. The editor maps these onto the theme's
    /// colours.
    enum Token {
        case plain, comment, string, number, keyword, key, tag, variable
    }

    /// The kinds of file the highlighter knows. ``plain`` is not a failure: it
    /// is the answer for prose, logs and anything whose shape we do not
    /// recognise, where colour would be noise.
    enum Family {
        case plain, shell, conf, ini, yaml, json, xml
    }

    /// One coloured run on a line: `start` until `end`, exclusive, in character
    /// offsets from the start of the line.
    struct Run: Equatable {
        let start: Int
        let end: Int
        let token: Token
    }

    private static let shellWords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
        "esac", "in", "function", "return", "local", "export", "readonly", "declare", "shift",
        "set", "unset", "source", "exit", "break", "continue", "echo", "printf", "cd", "trap",
    ]

    private static let constants: Set<String> = [
        "true", "false", "null", "yes", "no", "on", "off", "none", "None", "True", "False",
    ]

    /// Extensions that name a family outright. Everything else goes to ``sniff``.
    private static let byExtension: [String: Family] = [
        "sh": .shell, "bash": .shell, "zsh": .shell,
        "profile": .shell, "bashrc": .shell, "env": .shell,
        "conf": .conf, "config": .conf,
        "ini": .ini, "cfg": .ini, "toml": .ini,
        "properties": .ini, "service": .ini, "desktop": .ini,
        "yml": .yaml, "yaml": .yaml,
        "json": .json, "jsonc": .json,
        "xml": .xml, "html": .xml, "htm": .xml, "svg": .xml,
        "plist": .xml, "xhtml": .xml, "pom": .xml,
        "txt": .plain, "log": .plain, "md": .plain,
    ]

    /// Names with no extension that are worth knowing about.
    private static let byName: [String: Family] = [
        "sshd_config": .conf, "ssh_config": .conf, "nginx.conf": .conf,
        "fstab": .conf, "hosts": .conf, "crontab": .conf,
        "dockerfile": .conf, "makefile": .shell,
        "gitconfig": .ini, "editorconfig": .ini,
    ]

    /// Which family `name` belongs to, falling back to the shape of `text` when
    /// the name says nothing — a file called `config` could be anything, and a
    /// shebang or an opening brace settles it better than a guess.
    static func family(of name: String, text: String) -> Family {
        let lower = name.lowercased()
        if let known = byName[lower] { return known }
        if let known = byName[String(lower.drop(while: { $0 == "." }))] { return known }

        if let dot = lower.lastIndex(of: "."), let known = byExtension[String(lower[lower.index(after: dot)...])] {
            return known
        }
        if let known = byExtension[String(lower.drop(while: { $0 == "." }))] { return known }

        return sniff(text)
    }

    /// The family the first few lines look like, or ``Family/plain`` when
    /// nothing stands out.
    static func sniff(_ text: String) -> Family {
        let head = String(text.prefix(2048)).drop(while: \.isWhitespace)
        if head.hasPrefix("#!") { return .shell }
        if head.hasPrefix("<?xml") || head.hasPrefix("<!DOCTYPE") || head.hasPrefix("<") { return .xml }
        if head.hasPrefix("{") || head.hasPrefix("[\"") || head.hasPrefix("[{") { return .json }

        let lines = head
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmed.isEmpty && !$0.trimmed.hasPrefix("#") }
            .prefix(12)
        guard !lines.isEmpty else { return .plain }

        if lines.contains(where: { $0.trimmed.hasPrefix("[") && $0.trimmed.hasSuffix("]") }) {
            return .ini
        }

        // A colon-separated key at the start of a line is YAML's shape; an
        // equals sign is INI's.
        let yaml = lines.filter { looksLikeAssignment($0, separator: ":") }.count
        let ini = lines.filter { looksLikeAssignment($0, separator: "=") }.count
        if yaml > lines.count / 2 { return .yaml }
        if ini > lines.count / 2 { return .ini }
        return .plain
    }

    /// Whether a line starts with a bare word and then `separator` — the two
    /// regular expressions Android uses, written out, because building an
    /// `NSRegularExpression` per line of a sniffed file costs more than the walk
    /// it replaces.
    private static func looksLikeAssignment(_ line: String, separator: Character) -> Bool {
        var characters = Array(line)
        var i = 0
        while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }

        let wordStart = i
        while i < characters.count,
              characters[i].isLetter || characters[i].isNumber
                || characters[i] == "_" || characters[i] == "." || characters[i] == "-" {
            i += 1
        }
        guard i > wordStart else { return false }

        // YAML wants the colon to end the word or be followed by a space; INI
        // allows spaces around the equals sign.
        if separator == "=" {
            while i < characters.count, characters[i] == " " { i += 1 }
            return i < characters.count && characters[i] == "="
        }
        guard i < characters.count, characters[i] == ":" else { return false }
        let after = i + 1
        return after >= characters.count || characters[after] == " "
    }

    /// Colours one line, given `family` and whether the previous line left an
    /// XML comment open. Returns the runs and the state to carry into the next
    /// line.
    static func highlight(
        _ line: String,
        family: Family,
        inComment: Bool = false
    ) -> (runs: [Run], inComment: Bool) {
        guard family != .plain else { return ([], false) }

        let characters = Array(line)
        if family == .xml { return xml(characters, inComment: inComment) }

        var runs: [Run] = []
        var i = 0

        // A line comment swallows the rest of the line — but only outside a
        // string, which is why this cannot be done by looking for the marker
        // with `range(of:)`.
        let commentStarts: Set<Character>
        switch family {
        case .shell, .conf, .yaml: commentStarts = ["#"]
        case .ini: commentStarts = ["#", ";"]
        default: commentStarts = []
        }
        let firstWordIsDirective = family == .conf || family == .shell

        while i < characters.count {
            let c = characters[i]

            if commentStarts.contains(c) {
                runs.append(Run(start: i, end: characters.count, token: .comment))
                return (runs, false)
            }

            if c == "\"" || c == "'" {
                let end = closingQuote(characters, from: i, quote: c)
                runs.append(Run(start: i, end: end, token: .string))
                i = end
                continue
            }

            if c == "$", family == .shell || family == .conf {
                let end = variableEnd(characters, from: i)
                runs.append(Run(start: i, end: end, token: .variable))
                i = end
                continue
            }

            if c == "&" || c == "*" {
                // YAML anchors and references; elsewhere just an ampersand.
                let end = family == .yaml ? wordEnd(characters, from: i + 1) : i + 1
                if end > i + 1 {
                    runs.append(Run(start: i, end: end, token: .variable))
                }
                i = end
                continue
            }

            if c.isNumber, i == 0 || !(characters[i - 1].isLetter || characters[i - 1].isNumber || characters[i - 1] == "_") {
                let end = numberEnd(characters, from: i)
                runs.append(Run(start: i, end: end, token: .number))
                i = end
                continue
            }

            if c == "[", family == .ini, characters[..<i].allSatisfy(\.isWhitespace) {
                let end = characters[i...].firstIndex(of: "]").map { $0 + 1 } ?? characters.count
                runs.append(Run(start: i, end: end, token: .keyword))
                i = end
                continue
            }

            if c.isLetter || c == "_" || c == "/" {
                let end = wordEnd(characters, from: i)
                let word = String(characters[i..<end])
                let beforeIsBlank = characters[..<i].allSatisfy(\.isWhitespace)

                let token: Token
                if constants.contains(word) {
                    token = .number
                } else if family == .shell, shellWords.contains(word) {
                    token = .keyword
                } else if firstWordIsDirective, beforeIsBlank {
                    // The first word of a line is the directive in nginx,
                    // sshd_config and their kin; that one rule is what makes
                    // those files readable.
                    token = .keyword
                } else if keyFollows(characters, after: end, family: family) {
                    token = .key
                } else {
                    token = .plain
                }

                if token != .plain {
                    runs.append(Run(start: i, end: end, token: token))
                }
                i = end
                continue
            }

            i += 1
        }

        return (runs, inComment)
    }

    /// Whether the word ending at `end` is a key: followed by `=` in INI, by `:`
    /// in YAML and JSON.
    private static func keyFollows(_ line: [Character], after end: Int, family: Family) -> Bool {
        var j = end
        while j < line.count, line[j] == " " { j += 1 }
        guard j < line.count else { return false }

        switch family {
        case .ini, .conf: return line[j] == "="
        case .yaml, .json: return line[j] == ":"
        default: return false
        }
    }

    /// The index just past the closing quote, or the end of the line if it never
    /// closes.
    private static func closingQuote(_ line: [Character], from start: Int, quote: Character) -> Int {
        var j = start + 1
        while j < line.count {
            if line[j] == "\\", quote == "\"" {
                j += 2
                continue
            }
            if line[j] == quote { return j + 1 }
            j += 1
        }
        return line.count
    }

    private static func variableEnd(_ line: [Character], from start: Int) -> Int {
        var j = start + 1
        if j < line.count, line[j] == "{" {
            guard let close = line[j...].firstIndex(of: "}") else { return line.count }
            return close + 1
        }
        while j < line.count, line[j].isLetter || line[j].isNumber || line[j] == "_" { j += 1 }
        return j == start + 1 ? start + 1 : j
    }

    private static func wordEnd(_ line: [Character], from start: Int) -> Int {
        var j = start
        while j < line.count,
              line[j].isLetter || line[j].isNumber || "_-./".contains(line[j]) {
            j += 1
        }
        return max(j, start + 1)
    }

    private static func numberEnd(_ line: [Character], from start: Int) -> Int {
        var j = start
        while j < line.count, line[j].isNumber || line[j] == "." { j += 1 }
        // A trailing unit is part of the number to the eye: 30d, 20M, 443/tcp
        // stays a number.
        while j < line.count, line[j].isLetter, j - start <= 12 { j += 1 }
        return j
    }

    /// XML is its own shape: tags, attributes, entities, and comments that cross
    /// lines.
    private static func xml(_ line: [Character], inComment: Bool) -> (runs: [Run], inComment: Bool) {
        var runs: [Run] = []
        var open = inComment
        var i = 0

        while i < line.count {
            if open {
                let close = index(of: "-->", in: line, from: i)
                let end = close.map { $0 + 3 } ?? line.count
                runs.append(Run(start: i, end: end, token: .comment))
                open = close == nil
                i = end
                continue
            }

            if starts(line, at: i, with: "<!--") {
                open = true
                i += 1
                continue
            }

            if line[i] == "<" {
                let nameStart = i + 1 + (i + 1 < line.count && line[i + 1] == "/" ? 1 : 0)
                let end = wordEnd(line, from: nameStart)
                runs.append(Run(start: i, end: end, token: .tag))
                i = end
                continue
            }

            if line[i] == "\"" || line[i] == "'" {
                let end = closingQuote(line, from: i, quote: line[i])
                runs.append(Run(start: i, end: end, token: .string))
                i = end
                continue
            }

            if line[i] == "&", let close = line[i...].firstIndex(of: ";"), close <= i + 10, close > i + 1 {
                runs.append(Run(start: i, end: close + 1, token: .number))
                i = close + 1
                continue
            }

            if line[i].isLetter, attributeFollows(line, from: i) {
                let end = wordEnd(line, from: i)
                runs.append(Run(start: i, end: end, token: .key))
                i = end
                continue
            }

            i += 1
        }

        return (runs, open)
    }

    private static func attributeFollows(_ line: [Character], from start: Int) -> Bool {
        var j = start
        while j < line.count, line[j].isLetter || line[j].isNumber || "_-:".contains(line[j]) { j += 1 }
        return j < line.count && line[j] == "="
    }

    private static func starts(_ line: [Character], at index: Int, with text: String) -> Bool {
        let characters = Array(text)
        guard index + characters.count <= line.count else { return false }
        return Array(line[index..<(index + characters.count)]) == characters
    }

    private static func index(of text: String, in line: [Character], from start: Int) -> Int? {
        let characters = Array(text)
        guard characters.count <= line.count else { return nil }
        var i = start
        while i + characters.count <= line.count {
            if Array(line[i..<(i + characters.count)]) == characters { return i }
            i += 1
        }
        return nil
    }
}
