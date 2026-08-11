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
    /// A UTF-8 byte order mark was present and must be written back. Some
    /// Windows tooling requires it, and its absence changes how those tools
    /// read the file.
    public var hasByteOrderMark: Bool

    public init(encoding: String.Encoding = .utf8, hasByteOrderMark: Bool = false) {
        self.encoding = encoding
        self.hasByteOrderMark = hasByteOrderMark
    }

    public static let utf8 = TextFormat()

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decode `data`, recording what it took to do so.
    ///
    /// Returns nil only if nothing could read it, which Latin-1 makes
    /// impossible in practice — it maps every byte. A viewer that refuses to
    /// open a file is worse than one that opens it imperfectly.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        if data.starts(with: utf8BOM),
           let text = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) {
            return (text, TextFormat(encoding: .utf8, hasByteOrderMark: true))
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, TextFormat(encoding: .utf8, hasByteOrderMark: false))
        }
        // Latin-1 maps every possible byte, so this branch always succeeds and
        // the document opens with mojibake rather than not at all. Recording
        // the encoding is what stops a later save from turning that guess into
        // a permanent rewrite of the file.
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, TextFormat(encoding: .isoLatin1, hasByteOrderMark: false))
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
        return hasByteOrderMark ? Data(Self.utf8BOM) + body : body
    }

    /// A human-readable name, for the message shown when `encode` refuses.
    public var displayName: String {
        switch encoding {
        case .isoLatin1: return "ISO Latin-1"
        case .utf8: return hasByteOrderMark ? "UTF-8 with BOM" : "UTF-8"
        default: return "\(encoding)"
        }
    }
}
