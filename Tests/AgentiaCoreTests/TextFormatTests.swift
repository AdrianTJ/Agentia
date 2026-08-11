import XCTest
@testable import AgentiaCore

/// Saving a file must produce the same file.
///
/// A viewer can decode bytes any way that yields readable text. An editor
/// cannot: whatever the read guessed at has to be reproduced, or saving an
/// untouched document silently rewrites it — and the text on screen is
/// identical either way, so nothing tells the reader.
final class TextFormatTests: XCTestCase {

    /// Read the bytes, write them straight back, and require the file to be
    /// unchanged. This is the property that matters; the individual cases below
    /// only say which way it broke.
    private func roundTrip(_ bytes: [UInt8],
                           file: StaticString = #filePath, line: UInt = #line) {
        let data = Data(bytes)
        guard let decoded = TextFormat.decode(data) else {
            XCTFail("nothing could decode these bytes", file: file, line: line)
            return
        }
        XCTAssertEqual(decoded.format.encode(decoded.text), data,
                       "saving an unedited file changed it on disk",
                       file: file, line: line)
    }

    func testPlainUTF8RoundTrips() {
        roundTrip(Array("# Title\n\nBody.\n".utf8))
    }

    /// Measured: `e9` came back as `c3 a9` — the file silently became UTF-8.
    func testLatin1RoundTripsAsLatin1() {
        roundTrip([0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café\n" in Latin-1

        let (text, format) = TextFormat.decode(Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))!
        XCTAssertEqual(format.encoding, .isoLatin1)
        XCTAssertEqual(text, "café\n")
    }

    /// Measured: the BOM was dropped and the file shrank by three bytes.
    func testByteOrderMarkSurvives() {
        roundTrip([0xEF, 0xBB, 0xBF] + Array("# Title\n".utf8))

        let (text, format) = TextFormat.decode(
            Data([0xEF, 0xBB, 0xBF] + Array("# Title\n".utf8)))!
        XCTAssertTrue(format.hasByteOrderMark)
        XCTAssertEqual(text, "# Title\n", "the BOM is not part of the text")
    }

    /// Line endings live inside the String and neither step touches them, but
    /// an editor that silently normalises CRLF rewrites every line of the file.
    func testLineEndingsSurvive() {
        roundTrip(Array("# Title\r\n\r\nBody.\r\n".utf8))
        roundTrip(Array("mixed\r\nendings\nhere\r\n".utf8))
        roundTrip(Array("no trailing newline".utf8))
        roundTrip(Array("\n\n\n".utf8))
    }

    /// A whole encoding family was undetected: UTF-16 files read as Latin-1
    /// mojibake, or — worse, with no BOM and ASCII content — as *valid UTF-8*
    /// with a NUL after every character. Saving either would have rewritten the
    /// file to one byte per character, unreadable by anything expecting UTF-16.
    func testUTF16RoundTrips() {
        let text = "# Title\n\ncafé — 日本語\n"

        for (mark, encoding, name) in [
            (TextFormat.utf16LEBOM, String.Encoding.utf16LittleEndian, "LE with BOM"),
            (TextFormat.utf16BEBOM, String.Encoding.utf16BigEndian, "BE with BOM"),
        ] {
            let bytes = Data(mark) + text.data(using: encoding)!
            guard let decoded = TextFormat.decode(bytes) else {
                XCTFail("\(name): did not decode"); continue
            }
            XCTAssertEqual(decoded.text, text, "\(name): wrong text")
            XCTAssertEqual(decoded.format.encoding, encoding, "\(name): wrong encoding")
            XCTAssertEqual(decoded.format.encode(decoded.text), bytes,
                           "\(name): save changed the file")
        }
    }

    /// The nastiest case: BOM-less UTF-16 of pure ASCII is also valid UTF-8.
    /// It has to be recognised by the NUL bytes, since no Markdown document
    /// contains one.
    func testBOMlessUTF16IsNotMistakenForUTF8() {
        let text = "# Title\n"
        let bytes = text.data(using: .utf16LittleEndian)!

        guard let decoded = TextFormat.decode(bytes) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(decoded.text, text)
        XCTAssertFalse(decoded.text.utf8.contains(0),
                       "a NUL after every character means UTF-16 was read as UTF-8")
        XCTAssertEqual(decoded.format.encode(decoded.text), bytes,
                       "save must not collapse it to one byte per character")
    }

    /// Ordinary UTF-8 must not be dragged into the UTF-16 path by the new
    /// heuristic.
    func testPlainUTF8IsStillReadAsUTF8() {
        for sample in ["# Title\n", "a\n", "", "日本語\n", "x"] {
            let bytes = Data(sample.utf8)
            guard let decoded = TextFormat.decode(bytes) else {
                XCTFail("\(sample.debugDescription) did not decode"); continue
            }
            XCTAssertEqual(decoded.format.encoding, .utf8, sample.debugDescription)
            XCTAssertEqual(decoded.format.encode(decoded.text), bytes)
        }
    }

    func testEmptyFileRoundTrips() {
        roundTrip([])
    }

    func testUnicodeRoundTrips() {
        roundTrip(Array("日本語 — café 🎯 ↩\n".utf8))
    }

    /// Typing an emoji into a Latin-1 file cannot be saved as Latin-1. That has
    /// to be a refusal the reader sees: silently dropping the characters would
    /// destroy exactly what was just typed.
    func testUnrepresentableTextIsRefusedRatherThanMangled() {
        let latin1 = TextFormat(encoding: .isoLatin1)
        XCTAssertNil(latin1.encode("emoji 🎯 here"),
                     "lossy encoding must refuse, not substitute")
        XCTAssertNotNil(latin1.encode("café"), "and still accept what does fit")
    }

    func testFormatIsNamedForTheMessageShownOnRefusal() {
        XCTAssertEqual(TextFormat(encoding: .isoLatin1).displayName, "ISO Latin-1")
        XCTAssertEqual(TextFormat.utf8.displayName, "UTF-8")
        XCTAssertEqual(
            TextFormat(encoding: .utf8, byteOrderMark: TextFormat.utf8BOM).displayName,
            "UTF-8 with BOM")
        XCTAssertEqual(
            TextFormat(encoding: .utf16LittleEndian,
                       byteOrderMark: TextFormat.utf16LEBOM).displayName,
            "UTF-16 LE with BOM")
    }

    /// The snapshot has to carry the format, or the save cannot use it.
    func testSnapshotRemembersTheFormatItRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentia-fmt-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0xEF, 0xBB, 0xBF] + Array("# BOM\n".utf8)).write(to: url)
        let snapshot = try DocumentRenderer.read(contentsOf: url)

        XCTAssertTrue(snapshot.format.hasByteOrderMark)
        XCTAssertEqual(snapshot.source, "# BOM\n")
        XCTAssertEqual(snapshot.format.encode(snapshot.source),
                       try Data(contentsOf: url),
                       "an unedited save must reproduce the file exactly")
    }
}
