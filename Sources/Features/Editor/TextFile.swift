// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turning a remote file's bytes into text the editor can show, and back again
/// byte for byte.
///
/// A port of the Android `TextFile`, and the round trip is the whole point:
/// whatever the user does not touch must go back to the server exactly as it
/// arrived. Nothing is guessed silently — a charset is only ever used once
/// decoding it and re-encoding the result has been shown to give back the
/// original bytes, so a wrong guess cannot corrupt the file, it can only look
/// wrong on screen. What the user does see they can correct: the editor lets
/// them pick another charset and reads the same bytes again.
///
/// The only thing normalised on the way in is the line ending, which is put back
/// on the way out; nothing is added, and a file that ended without a newline
/// still ends without one after saving.
enum TextFile {

    enum LineEnding: String {
        case lf = "\n"
        case crlf = "\r\n"
    }

    /// A byte-order mark: the one part of the encoding a file states about
    /// itself.
    enum BOM: CaseIterable {
        case utf32LE, utf32BE, utf8, utf16LE, utf16BE

        var bytes: [UInt8] {
            switch self {
            case .utf32LE: return [0xFF, 0xFE, 0x00, 0x00]
            case .utf32BE: return [0x00, 0x00, 0xFE, 0xFF]
            case .utf8: return [0xEF, 0xBB, 0xBF]
            // Must come after the UTF-32 marks, whose first two bytes are the same.
            case .utf16LE: return [0xFF, 0xFE]
            case .utf16BE: return [0xFE, 0xFF]
            }
        }

        var charset: Charset {
            switch self {
            case .utf32LE: return Charset(name: "UTF-32LE", encoding: .utf32LittleEndian)
            case .utf32BE: return Charset(name: "UTF-32BE", encoding: .utf32BigEndian)
            case .utf8: return Charset(name: "UTF-8", encoding: .utf8)
            case .utf16LE: return Charset(name: "UTF-16LE", encoding: .utf16LittleEndian)
            case .utf16BE: return Charset(name: "UTF-16BE", encoding: .utf16BigEndian)
            }
        }
    }

    /// One encoding the picker can offer: the name a person recognises and the
    /// `String.Encoding` that does the work.
    ///
    /// Several of these have no constant in `String.Encoding` and come from
    /// CoreFoundation instead — the Windows code pages, the KOI8 pair, the CJK
    /// encodings. Java names every one of them out of the box, which is why the
    /// Android list is a list of strings; here the mapping is the list.
    struct Charset: Equatable, Identifiable, Hashable {
        let name: String
        let encoding: String.Encoding

        var id: String { name }

        static func == (lhs: Charset, rhs: Charset) -> Bool { lhs.name == rhs.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    /// A file we can edit as text: the text plus everything needed to rebuild
    /// the original bytes.
    struct Decoded: Equatable {
        let text: String
        let charset: Charset
        /// Present in the file and kept out of ``text``; written back untouched.
        let bom: BOM?
        let lineEnding: LineEnding
        /// The file mixed LF and CRLF; saving settles on ``lineEnding`` for the
        /// whole file.
        let mixedEndings: Bool

        var label: String { bom == nil ? charset.name : "\(charset.name) BOM" }

        static func == (lhs: Decoded, rhs: Decoded) -> Bool {
            lhs.text == rhs.text && lhs.charset == rhs.charset && lhs.bom == rhs.bom
                && lhs.lineEnding == rhs.lineEnding && lhs.mixedEndings == rhs.mixedEndings
        }
    }

    /// Every charset the picker can offer. The order here is for the list, not
    /// for guessing.
    static let all: [Charset] = [
        Charset(name: "UTF-8", encoding: .utf8),
        Charset(name: "UTF-16LE", encoding: .utf16LittleEndian),
        Charset(name: "UTF-16BE", encoding: .utf16BigEndian),
        Charset(name: "ISO-8859-15", encoding: cf(.isoLatin9)),
        Charset(name: "windows-1252", encoding: .windowsCP1252),
        Charset(name: "ISO-8859-1", encoding: .isoLatin1),
        Charset(name: "windows-1250", encoding: .windowsCP1250),
        Charset(name: "ISO-8859-2", encoding: .isoLatin2),
        Charset(name: "windows-1251", encoding: .windowsCP1251),
        Charset(name: "KOI8-R", encoding: cf(.KOI8_R)),
        Charset(name: "KOI8-U", encoding: cf(.KOI8_U)),
        Charset(name: "ISO-8859-5", encoding: cf(.isoLatinCyrillic)),
        Charset(name: "windows-1253", encoding: .windowsCP1253),
        Charset(name: "ISO-8859-7", encoding: cf(.isoLatinGreek)),
        Charset(name: "windows-1254", encoding: .windowsCP1254),
        Charset(name: "ISO-8859-9", encoding: cf(.isoLatin5)),
        Charset(name: "windows-1257", encoding: cf(.windowsBalticRim)),
        Charset(name: "windows-1255", encoding: cf(.windowsHebrew)),
        Charset(name: "windows-1256", encoding: cf(.windowsArabic)),
        Charset(name: "GB18030", encoding: cf(.GB_18030_2000)),
        Charset(name: "GBK", encoding: cf(.GBK_95)),
        Charset(name: "Big5", encoding: cf(.big5)),
        Charset(name: "Shift_JIS", encoding: .shiftJIS),
        Charset(name: "EUC-JP", encoding: .japaneseEUC),
        Charset(name: "EUC-KR", encoding: cf(.EUC_KR)),
    ]

    /// Charsets to try first for a given device language, before the rest.
    private static let byLanguage: [String: [String]] = [
        "ru": ["windows-1251", "KOI8-R", "ISO-8859-5"],
        "uk": ["windows-1251", "KOI8-U", "KOI8-R"],
        "bg": ["windows-1251", "ISO-8859-5"],
        "zh": ["GB18030", "GBK", "Big5"],
        "ja": ["Shift_JIS", "EUC-JP"],
        "ko": ["EUC-KR"],
        "el": ["windows-1253", "ISO-8859-7"],
        "tr": ["windows-1254", "ISO-8859-9"],
        "pl": ["windows-1250", "ISO-8859-2"],
        "cs": ["windows-1250", "ISO-8859-2"],
        "hu": ["windows-1250", "ISO-8859-2"],
        "he": ["windows-1255"],
        "ar": ["windows-1256"],
    ]

    /// A CoreFoundation encoding as a `String.Encoding`.
    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(encoding.rawValue)
            )
        )
    }

    // MARK: - Reading

    /// Whether these bytes are not text, and so can only be shown in the hex
    /// view.
    ///
    /// A NUL byte settles it — no single-byte text file has one, every binary
    /// format does. Failing that we look at the control characters: a handful
    /// means an odd file, a quarter of it means a binary that happens to have no
    /// NUL in it. UTF-16 and UTF-32 are full of NULs, which is why they are
    /// recognised by their mark before this is ever asked.
    static func isBinary(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }

        let sample = min(bytes.count, 8 * 1024)
        var controls = 0

        for byte in bytes.prefix(sample) {
            if byte == 0 { return true }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { controls += 1 }
        }
        return controls * 4 > sample
    }

    /// Reads `bytes` as text, or returns `nil` if they are not text at all.
    ///
    /// A byte-order mark decides on its own. Otherwise the candidates are tried
    /// in order and the first one whose round trip is exact wins, the ones
    /// suggested by `language` first — the phone's language is a better hint
    /// than anything the bytes can say, since the same bytes are legal Cyrillic
    /// and legal Greek.
    ///
    /// `allowBinary` reads bytes the binary test rejects anyway. Safe, because
    /// the round trip still has to be exact — the Latin charsets map all 256
    /// byte values, NUL included — so a file with a stray NUL in it can be
    /// opened, repaired and saved without losing the rest.
    static func decode(
        _ bytes: Data,
        language: String = Locale.current.language.languageCode?.identifier ?? "en",
        allowBinary: Bool = false
    ) -> Decoded? {
        if let bom = bom(of: bytes), let decoded = decode(bytes, as: bom.charset, bom: bom) {
            return decoded
        }
        // Unmarked UTF-16 is the one text format the control-character test
        // would throw away, so it is asked about first, on the evidence of its
        // alternating NUL bytes.
        if let unmarked = unmarkedUTF16(bytes) { return unmarked }

        if !allowBinary, isBinary(bytes) { return nil }

        for charset in candidates(language: language, bytes: bytes) {
            if let decoded = decode(bytes, as: charset, bom: nil) { return decoded }
        }
        return nil
    }

    /// Reads `bytes` as `charset`, or returns `nil` if that would not survive
    /// the way back: either the bytes are not valid in it, or re-encoding what
    /// came out gives different bytes.
    ///
    /// Verifying instead of trusting costs one pass over a file this small, and
    /// it is what makes an unknown charset safe to open — if the round trip is
    /// exact, saving cannot corrupt the parts the user never touched, whatever
    /// the charset turns out to really be.
    static func decode(_ bytes: Data, as charset: Charset, bom: BOM?) -> Decoded? {
        let body = bom.map { bytes.dropFirst($0.bytes.count) } ?? bytes[...]

        guard let raw = String(data: body, encoding: charset.encoding),
              let backAgain = raw.data(using: charset.encoding, allowLossyConversion: false),
              backAgain == Data(body)
        else { return nil }

        // Counted in scalars, not characters. Swift joins CR and LF into a
        // single grapheme cluster, so `raw.filter { $0 == "\n" }` sees only the
        // lone line feeds and a file of pure CRLF reports none at all — which
        // made `mixedEndings` false for the very files it exists to flag.
        let crlf = raw.components(separatedBy: "\r\n").count - 1
        let lf = raw.unicodeScalars.filter { $0 == "\n" }.count - crlf

        return Decoded(
            text: crlf > 0 ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw,
            charset: charset,
            bom: bom,
            lineEnding: crlf > lf ? .crlf : .lf,
            mixedEndings: crlf > 0 && lf > 0
        )
    }

    /// The charsets `bytes` could be read as, for the picker: every candidate
    /// whose round trip is exact, best guess first. Anything left out would not
    /// survive being saved, so it is not offered at all rather than offered as a
    /// trap.
    static func readableCharsets(
        of bytes: Data,
        language: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) -> [Charset] {
        let mark = bom(of: bytes)
        var seen: Set<String> = []
        let order = candidates(language: language, bytes: bytes) + all

        return order.filter { charset in
            guard seen.insert(charset.name).inserted else { return false }
            return decode(bytes, as: charset, bom: mark) != nil
        }
    }

    // MARK: - Writing

    /// Rebuilds the file's bytes from edited `text`, restoring `from`'s ending,
    /// mark and charset.
    ///
    /// Returns `nil` if the text now holds characters that charset cannot write
    /// — typing a € into a Latin-1 file, say — which is a thing to say out loud,
    /// not to replace with a "?".
    static func encode(_ text: String, from decoded: Decoded) -> Data? {
        let withEndings = decoded.lineEnding == .crlf
            ? text.replacingOccurrences(of: "\n", with: "\r\n")
            : text

        guard let body = withEndings.data(using: decoded.charset.encoding, allowLossyConversion: false),
              String(data: body, encoding: decoded.charset.encoding) == withEndings
        else { return nil }

        guard let bom = decoded.bom else { return body }
        return Data(bom.bytes) + body
    }

    // MARK: - Guessing

    /// What is tried automatically, in order — and deliberately short.
    ///
    /// Only evidence belongs here. UTF-8 either decodes or it does not, and that
    /// is a fact about the bytes. Everything after it is a guess, so the only
    /// guesses made are the ones with a reason behind them: the phone's
    /// language, and then Latin, which is what a file on a European server that
    /// is not UTF-8 nearly always is.
    ///
    /// The rest of ``all`` is left out on purpose. A single-byte charset accepts
    /// *any* bytes, so windows-1251 in this list would claim every Italian file
    /// before ISO-8859-15 was ever tried and show Cyrillic where there are
    /// accents; GB18030 accepts nearly any bytes too and would claim the
    /// Japanese and Taiwanese files along with them. Both really happened on
    /// Android. Without a reason to prefer one, the machine cannot tell them
    /// apart — only the reader can, which is what the picker is for.
    private static func candidates(language: String, bytes: Data) -> [Charset] {
        let latin = hasC1(bytes)
            ? ["windows-1252", "ISO-8859-15"]
            : ["ISO-8859-15", "windows-1252"]
        let names = ["UTF-8"] + (byLanguage[language] ?? []) + latin + ["ISO-8859-1"]

        var seen: Set<String> = []
        return names.compactMap { name in
            guard seen.insert(name).inserted else { return nil }
            return all.first { $0.name == name }
        }
    }

    /// Whether any byte falls in 0x80–0x9F. ISO-8859 puts control characters
    /// there and would show nothing at all, while the Windows code pages put the
    /// quotes and dashes that Windows editors actually write — so a file using
    /// that range is read as windows-1252 first.
    private static func hasC1(_ bytes: Data) -> Bool {
        bytes.contains { $0 >= 0x80 && $0 <= 0x9F }
    }

    /// UTF-16 with no mark: every other byte is NUL in plain text, and the side
    /// says which one.
    private static func unmarkedUTF16(_ bytes: Data) -> Decoded? {
        guard bytes.count >= 4, bytes.count % 2 == 0 else { return nil }

        let sample = min(bytes.count, 2048)
        var evenNULs = 0
        var oddNULs = 0

        for (index, byte) in bytes.prefix(sample).enumerated() where byte == 0 {
            if index % 2 == 0 { evenNULs += 1 } else { oddNULs += 1 }
        }

        let name: String
        if oddNULs * 4 > sample, evenNULs == 0 {
            name = "UTF-16LE"
        } else if evenNULs * 4 > sample, oddNULs == 0 {
            name = "UTF-16BE"
        } else {
            return nil
        }

        guard let charset = all.first(where: { $0.name == name }) else { return nil }
        return decode(bytes, as: charset, bom: nil)
    }

    private static func bom(of bytes: Data) -> BOM? {
        BOM.allCases.first { bom in
            bytes.count >= bom.bytes.count && Array(bytes.prefix(bom.bytes.count)) == bom.bytes
        }
    }
}
