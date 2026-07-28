// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The shell history read off the server, and the matching that turns it into
/// suggestions.
///
/// All of this is pure text work on purpose: it is the part worth testing, and
/// it can be exercised without a server.
struct CommandHistory: Sendable {

    /// Most recent first, deduplicated.
    let commands: [String]

    static let empty = CommandHistory(commands: [])

    /// History files worth trying, in the order a login shell is likely to use.
    static let candidatePaths = [
        ".bash_history",
        ".zsh_history",
        ".local/share/fish/fish_history",
    ]

    // MARK: - Parsing

    /// Reads one history file.
    ///
    /// Handles zsh's extended format, `: 1700000000:0;command`, and fish's YAML
    /// -ish `- cmd: command`. A plain bash file is one command per line.
    /// Anything unrecognisable is taken literally rather than dropped: a command
    /// shown that should not have been is a smaller problem than one missing.
    static func parse(_ data: Data) -> CommandHistory {
        let text = String(decoding: data, as: UTF8.self)

        var seen = Set<String>()
        var result: [String] = []

        // Reversed so the most recent survives deduplication and comes first.
        for rawLine in text.split(whereSeparator: \.isNewline).reversed() {
            let command = normalise(String(rawLine))

            guard !command.isEmpty, command.count >= 2 else { continue }
            guard seen.insert(command).inserted else { continue }
            result.append(command)
        }

        return CommandHistory(commands: result)
    }

    private static func normalise(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)

        // zsh extended: ": <epoch>:<elapsed>;<command>"
        if line.hasPrefix(":"), let semicolon = line.firstIndex(of: ";") {
            let header = line[line.startIndex..<semicolon]
            if header.contains(":") {
                line = String(line[line.index(after: semicolon)...])
            }
        }

        // fish: "- cmd: <command>"
        if line.hasPrefix("- cmd:") {
            line = String(line.dropFirst("- cmd:".count))
        }

        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Merges several files, keeping the first occurrence of each command.
    static func merging(_ histories: [CommandHistory]) -> CommandHistory {
        var seen = Set<String>()
        var result: [String] = []

        for history in histories {
            for command in history.commands where seen.insert(command).inserted {
                result.append(command)
            }
        }
        return CommandHistory(commands: result)
    }

    // MARK: - Matching

    /// Suggestions for a partially typed command.
    ///
    /// Commands that *start* with what was typed come first, then commands that
    /// merely contain it — a prefix match is almost always what was meant, but
    /// the substring match finds the long pipeline you half remember.
    func suggestions(for partial: String, limit: Int = 12) -> [String] {
        let query = partial.trimmingCharacters(in: .whitespaces)

        // Below two characters everything matches and the bar is just noise.
        // Same threshold as the Android bar.
        guard query.count >= 2 else { return [] }

        var prefixMatches: [String] = []
        var containsMatches: [String] = []

        for command in commands {
            guard command != query else { continue }

            if command.hasPrefix(query) {
                prefixMatches.append(command)
            } else if command.contains(query) {
                containsMatches.append(command)
            }

            if prefixMatches.count >= limit { break }
        }

        return Array((prefixMatches + containsMatches).prefix(limit))
    }
}

/// Extracts what the user has typed so far from the visible terminal line.
enum PromptParser {

    /// The characters a shell prompt conventionally ends with.
    private static let terminators: [Character] = ["$", "#", ">", "%"]

    /// Strips the prompt from a terminal line, returning what was typed.
    ///
    /// Rather than learning the prompt once and remembering it, this looks for
    /// the last prompt terminator followed by a space. That survives a prompt
    /// that changes as you move around — which is normal, since most prompts
    /// carry the working directory — and needs no state.
    ///
    /// Returns `nil` when no prompt is recognisable, so the caller can leave the
    /// suggestions alone instead of matching against a whole line of output.
    static func typedPortion(of line: String) -> String? {
        var lastTerminator: String.Index?

        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if terminators.contains(line[index]), next < line.endIndex, line[next] == " " {
                lastTerminator = next
            }
            index = next
        }

        guard let lastTerminator else { return nil }
        return String(line[line.index(after: lastTerminator)...])
            .trimmingCharacters(in: .whitespaces)
    }
}
