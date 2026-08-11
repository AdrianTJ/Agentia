import Foundation

/// How a file was encoded on disk, so writing it back does not quietly change
/// it into a different file.
///
/// A viewer can be relaxed about this: decode the bytes any way that produces
/// readable text and move on. An editor cannot. Every property the read guesses
/// at has to be remembered and reproduced, or saving an untouched document
/// rewrites it — and the reader is told nothing, because the text on screen is
/// identical either way.
///
/// Measured failures this exists to prevent, all from saving a file opened and
/// not edited:
///
///  * a Latin-1 file came back as UTF-8 (`e9` became `c3 a9`),
///  * a UTF-8 BOM was dropped, shrinking the file by three bytes.
///
/// CRLF needs no handling here: line endings live inside the `String`, and both
/// the decode and the encode leave them alone — verified rather than assumed.
public struct TextFormat: Equatable, Sendable {

    public var encoding: String.Encoding
    /// The exact byte order mark to write back, empty when there was none.
    ///
    /// Stored as bytes rather than a flag because the mark differs per encoding
    /// and the file has to be reproduced byte for byte. Some Windows tooling
    /// requires it, and its absence changes how those tools read the file.
    public var byteOrderMark: [UInt8]

    public init(encoding: String.Encoding = .utf8, byteOrderMark: [UInt8] = []) {
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
    }

    public var hasByteOrderMark: Bool { !byteOrderMark.isEmpty }

    public static let utf8 = TextFormat()

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]

    /// Decode `data`, recording what it took to do so.
    ///
    /// Returns nil only if nothing could read it, which Latin-1 makes
    /// impossible in practice — it maps every byte. A viewer that refuses to
    /// open a file is worse than one that opens it imperfectly.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        // A byte order mark is a definite statement about the encoding, so it
        // is trusted ahead of any guessing.
        let marks: [([UInt8], String.Encoding)] = [
            (utf8BOM, .utf8),
            // UTF-16LE is checked before UTF-16BE because they are not
            // ambiguous, but order is stated explicitly so it stays deliberate.
            (utf16LEBOM, .utf16LittleEndian),
            (utf16BEBOM, .utf16BigEndian),
        ]
        for (mark, encoding) in marks where data.starts(with: mark) {
            if let text = String(data: data.dropFirst(mark.count), encoding: encoding) {
                return (text, TextFormat(encoding: encoding, byteOrderMark: mark))
            }
        }

        // Without a mark, UTF-8 is the overwhelmingly likely answer — but a
        // UTF-16 file of ASCII decodes as *valid UTF-8* too, as every other
        // byte is a NUL. That produced text like "a\0b\0c\0", visibly correct
        // in a list of characters and wrong in every other way, and saving it
        // would have rewritten a UTF-16 file as one byte per character.
        //
        // A NUL is the tell: no Markdown or HTML document contains one, and
        // cmark replaces any it does see. So UTF-8 is accepted only when the
        // result has none, and otherwise the UTF-16 readings are tried.
        let utf8Text = String(data: data, encoding: .utf8)
        if let utf8Text, !utf8Text.utf8.contains(0) {
            return (utf8Text, TextFormat(encoding: .utf8))
        }

        // Only when the bytes actually look like UTF-16. Requiring a NUL and an
        // even length keeps this branch off everything else: a Latin-1 file
        // fails UTF-8 too, and without this guard `café` in Latin-1 came back
        // as a single Chinese character, because five arbitrary bytes will
        // happily decode as *some* UTF-16.
        if data.contains(0), data.count % 2 == 0 {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let text = String(data: data, encoding: encoding),
                   !text.utf8.contains(0), !text.isEmpty {
                    return (text, TextFormat(encoding: encoding))
                }
            }
        }

        // Nothing else fit. UTF-8 with embedded NULs still beats mojibake.
        if let utf8Text { return (utf8Text, TextFormat(encoding: .utf8)) }

        // Latin-1 maps every possible byte, so this branch always succeeds and
        // the document opens with mojibake rather than not at all. Recording
        // the encoding is what stops a later save from turning that guess into
        // a permanent rewrite of the file.
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, TextFormat(encoding: .isoLatin1))
        }
        return nil
    }

    /// Re-encode text in this format, BOM included if there was one.
    ///
    /// Returns nil when the text cannot be represented — typing an emoji into a
    /// Latin-1 file, say. That has to be a refusal the reader sees, not a
    /// substitution: silently dropping the characters that do not fit would
    /// destroy exactly what was just typed.
    public func encode(_ text: String) -> Data? {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            return nil
        }
        return byteOrderMark.isEmpty ? body : Data(byteOrderMark) + body
    }

    /// A human-readable name, for the message shown when `encode` refuses.
    public var displayName: String {
        let suffix = hasByteOrderMark ? " with BOM" : ""
        switch encoding {
        case .isoLatin1: return "ISO Latin-1"
        case .utf8: return "UTF-8" + suffix
        case .utf16LittleEndian: return "UTF-16 LE" + suffix
        case .utf16BigEndian: return "UTF-16 BE" + suffix
        default: return "\(encoding)"
        }
    }
}
