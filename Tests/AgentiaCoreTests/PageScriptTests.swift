import XCTest
@testable import AgentiaCore

/// Host-initiated JavaScript runs with the host's authority and outside the
/// page's CSP, so a document-supplied value reaching one of these strings
/// unescaped is arbitrary code execution at the host's privilege — not merely
/// script inside a sandboxed page. The heading id comes straight from the
/// document's own outline.
final class PageScriptTests: XCTestCase {

    private func script(_ id: String) -> String {
        PageScript.scrollToElement(id: id) ?? ""
    }

    func testOrdinaryIDIsEmbedded() {
        XCTAssertTrue(script("section-one").contains("\"section-one\""))
        XCTAssertTrue(script("section-one").contains("getElementById"))
    }

    /// Decode the emitted literal back to the value it stands for.
    ///
    /// This is the property that matters, and asserting on the *text* of the
    /// script is not: a payload like `window.evil = 1;` legitimately appears
    /// inside a correctly escaped literal, where it is inert. What must hold is
    /// that the literal is one complete string that decodes to exactly the id —
    /// if it does, nothing in it escaped into code.
    private func roundTrip(_ id: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let literal = PageScript.jsonStringLiteral(id) else {
            XCTFail("no literal produced for \(id)", file: file, line: line)
            return
        }
        guard let data = "[\(literal)]".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            XCTFail("literal is not a valid string: \(literal)", file: file, line: line)
            return
        }
        XCTAssertEqual(decoded.first, id,
                       "the literal must stand for exactly the id",
                       file: file, line: line)
    }

    /// The break-out attempt: close the call, then append statements.
    func testQuotesCannotCloseTheCall() {
        roundTrip("\"); window.evil = 1; (")
        XCTAssertTrue(script("\"); window.evil = 1; (").contains("\\\""),
                      "the quote is escaped")
    }

    func testBackslashesAreEscaped() {
        roundTrip(#"a\"); evil()"#)
        roundTrip(#"\\\\"#)
        roundTrip(#"\"#)
    }

    /// A newline inside a JavaScript string literal is a syntax error, which
    /// would break the script rather than run it — but a `//` comment on the
    /// same line could then swallow the guard that follows.
    func testNewlinesCannotTerminateTheLiteral() {
        for id in ["a\nb", "a\r\nb", "x\n// swallowed"] {
            let out = script(id)
            XCTAssertFalse(out.contains("\n// swallowed"))
            XCTAssertTrue(out.contains("\\n") || out.contains("\\r"),
                          "line breaks must be escaped, got:\n\(out)")
        }
    }

    /// U+2028 and U+2029 are legal inside a JSON string but terminate a line in
    /// JavaScript, so a JSON encoder can return something that is valid JSON
    /// and a syntax error as source.
    func testLineSeparatorsAreEscaped() {
        for separator in ["\u{2028}", "\u{2029}"] {
            let out = script("a\(separator)b")
            XCTAssertFalse(out.contains(separator),
                           "raw U+2028/9 must not survive into the source")
            XCTAssertTrue(out.contains("\\u202"), out)
        }
    }

    func testUnicodeAndEmptyIDsAreSafe() {
        XCTAssertTrue(script("日本語-見出し").contains("getElementById"))
        XCTAssertTrue(script("").contains("\"\""))
        roundTrip("日本語-見出し")
        roundTrip("")
        roundTrip("emoji-🎯-heading")
    }

    /// Whatever an id contains, the emitted script must still be one call with
    /// balanced delimiters.
    func testScriptShapeSurvivesHostileInput() {
        let hostile = ["\");alert(1);(\"", "'\n;evil()", "</script>", "\\", "\"\"\""]
        for id in hostile {
            let out = script(id)
            let opens = out.components(separatedBy: "(").count
            let closes = out.components(separatedBy: ")").count
            XCTAssertEqual(opens, closes, "unbalanced parens for \(id):\n\(out)")
            XCTAssertEqual(out.components(separatedBy: "getElementById").count - 1, 1,
                           "exactly one lookup")
        }
    }
}
