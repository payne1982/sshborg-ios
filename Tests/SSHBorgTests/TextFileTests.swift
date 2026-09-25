// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import SSHBorg

/// Reading a remote file as text, and writing it back byte for byte.
///
/// The round trip is the property worth pinning: what the user did not touch
/// must reach the server unchanged, whatever the file turned out to be encoded
/// in. Everything else here — which charset is guessed, which line ending wins —
/// only decides how it looks while being edited.
final class TextFileTests: XCTestCase {

    private func bytes(_ values: [UInt8]) -> Data { Data(values) }

    // MARK: - What is text

    func testNULMakesItBinary() {
        XCTAssertTrue(TextFile.isBinary(bytes([0x68, 0x69, 0x00, 0x68])))
        XCTAssertFalse(TextFile.isBinary(Data("hello\nworld\n".utf8)))
    }

    func testAnEmptyFileIsNotBinary() {
        XCTAssertFalse(TextFile.isBinary(Data()))
    }

    func testAFileFullOfControlCharactersIsBinary() {
        XCTAssertTrue(TextFile.isBinary(Data((0..<200).map { _ in UInt8(0x01) })))
    }

    // MARK: - Reading

    func testUTF8IsReadAsItself() throws {
        let decoded = try XCTUnwrap(TextFile.decode(Data("ciao, però\n".utf8)))
        XCTAssertEqual(decoded.text, "ciao, però\n")
        XCTAssertEqual(decoded.charset.name, "UTF-8")
        XCTAssertNil(decoded.bom)
    }

    /// A byte-order mark decides on its own, and is kept out of the text.
    func testAMarkedFileKeepsItsMarkOutOfTheText() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8)
        let decoded = try XCTUnwrap(TextFile.decode(data))

        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.bom, .utf8)
        XCTAssertEqual(decoded.label, "UTF-8 BOM")
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), data, "the mark did not come back")
    }

    /// Latin-1 bytes are not valid UTF-8, so the guess has to move on — and
    /// whichever it lands on, the bytes must come back.
    func testALatinFileRoundTrips() throws {
        let original = bytes([0x70, 0x65, 0x72, 0xF2, 0x0A])   // "però\n" in ISO-8859-*
        let decoded = try XCTUnwrap(TextFile.decode(original))

        XCTAssertEqual(decoded.text, "però\n")
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), original)
    }

    /// The Windows code pages put quotes and dashes where ISO-8859 has control
    /// characters, so a file using that range is read as windows-1252 first.
    func testAFileWithC1BytesPrefersWindows1252() throws {
        let original = bytes([0x93, 0x68, 0x69, 0x94, 0x0A])   // “hi”
        let decoded = try XCTUnwrap(TextFile.decode(original))

        XCTAssertEqual(decoded.charset.name, "windows-1252")
        XCTAssertEqual(decoded.text, "“hi”\n")
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), original)
    }

    func testUnmarkedUTF16IsRecognised() throws {
        let original = try XCTUnwrap("hello".data(using: .utf16LittleEndian))
        let decoded = try XCTUnwrap(TextFile.decode(original))

        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.charset.name, "UTF-16LE")
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), original)
    }

    func testABinaryIsNotDecodedUnlessAsked() {
        let data = bytes([0x00, 0x01, 0x02, 0x68, 0x69])
        XCTAssertNil(TextFile.decode(data))
        XCTAssertNotNil(TextFile.decode(data, allowBinary: true), "an odd file must still be openable")
    }

    // MARK: - Line endings

    func testCRLFIsNormalisedForEditingAndRestoredForSaving() throws {
        let original = Data("one\r\ntwo\r\n".utf8)
        let decoded = try XCTUnwrap(TextFile.decode(original))

        XCTAssertEqual(decoded.text, "one\ntwo\n", "the editor sees one kind of newline")
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertFalse(decoded.mixedEndings)
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), original)
    }

    func testAMixedFileIsFlaggedAndSettledOnSave() throws {
        let decoded = try XCTUnwrap(TextFile.decode(Data("one\r\ntwo\nthree\r\n".utf8)))

        XCTAssertTrue(decoded.mixedEndings, "the user is not told the file is inconsistent")
        XCTAssertEqual(decoded.lineEnding, .crlf, "the majority wins")
        XCTAssertEqual(
            TextFile.encode(decoded.text, from: decoded),
            Data("one\r\ntwo\r\nthree\r\n".utf8)
        )
    }

    /// A file that ends without a newline still does after saving.
    func testAMissingFinalNewlineIsNotAdded() throws {
        let original = Data("no newline here".utf8)
        let decoded = try XCTUnwrap(TextFile.decode(original))
        XCTAssertEqual(TextFile.encode(decoded.text, from: decoded), original)
    }

    // MARK: - Writing

    /// Typing a character the file's charset cannot write is a thing to say out
    /// loud, not to replace with a "?".
    ///
    /// Not the euro sign, which is exactly what ISO-8859-15 was made for and
    /// what a Latin file here is read as — a Cyrillic word is the honest test.
    func testACharacterTheCharsetCannotWriteIsRefused() throws {
        let decoded = try XCTUnwrap(TextFile.decode(bytes([0x70, 0x65, 0x72, 0xF2])))
        XCTAssertNil(TextFile.encode(decoded.text + " привет", from: decoded))
    }

    func testEditedTextIsWrittenInTheFilesOwnCharset() throws {
        let decoded = try XCTUnwrap(TextFile.decode(bytes([0x70, 0x65, 0x72, 0xF2])))
        let saved = try XCTUnwrap(TextFile.encode("però sì", from: decoded))

        XCTAssertEqual(saved, bytes([0x70, 0x65, 0x72, 0xF2, 0x20, 0x73, 0xEC]))
    }

    // MARK: - The picker

    /// Only charsets that survive the round trip are offered: one that would
    /// corrupt the file on save is a trap, not a choice.
    func testThePickerOffersOnlyWhatWouldSurviveASave() {
        let utf8 = Data("ciao però".utf8)
        let offered = TextFile.readableCharsets(of: utf8).map(\.name)

        XCTAssertEqual(offered.first, "UTF-8", "the best guess is not first")
        XCTAssertFalse(offered.isEmpty)
        for name in offered {
            let charset = TextFile.all.first { $0.name == name }
            XCTAssertNotNil(TextFile.decode(utf8, as: charset!, bom: nil), "\(name) does not round-trip")
        }
    }

    /// The phone's language is a better hint than anything the bytes can say,
    /// since the same bytes are legal Cyrillic and legal Greek.
    func testTheDeviceLanguageIsTriedBeforeTheLatinFallback() throws {
        // Cyrillic "привет" in windows-1251.
        let original = bytes([0xEF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])

        let asRussian = try XCTUnwrap(TextFile.decode(original, language: "ru"))
        XCTAssertEqual(asRussian.charset.name, "windows-1251")
        XCTAssertEqual(asRussian.text, "привет")

        // With no such hint the same bytes are legal Latin, and still round-trip.
        let asItalian = try XCTUnwrap(TextFile.decode(original, language: "it"))
        XCTAssertNotEqual(asItalian.charset.name, "windows-1251")
        XCTAssertEqual(TextFile.encode(asItalian.text, from: asItalian), original)
    }
}
