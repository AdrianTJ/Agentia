import XCTest
@testable import AgentiaCore

final class SyntaxHighlighterTests: XCTestCase {

    /// Strip the spans and undo the escaping: what comes back must be the
    /// original code, byte for byte.
    ///
    /// This is the load-bearing test. Highlighting inserts markup into a
    /// document the CSP is holding at arm's length, so every character has to
    /// pass through exactly one escaping step — one too many surfaces as
    /// `&amp;lt;` on screen, one too few is an injection.
    private func roundTrip(_ code: String, _ language: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let html = SyntaxHighlighter.highlight(code, language: language) else {
            XCTFail("\(language) should be supported", file: file, line: line)
            return
        }
        let stripped = html.replacingOccurrences(
            of: "<span class=\"tok-[a-z]+\">|</span>",
            with: "", options: .regularExpression)
        XCTAssertEqual(CodeHighlighting.unescape(stripped), code,
                       "highlighting must not change the code",
                       file: file, line: line)
    }

    func testHighlightingIsLossless() {
        roundTrip("""
        func f(a: String) -> Int {
            // < > & " ' all of them
            let s = "a <b> & \\"c\\""
            return 1
        }
        """, "swift")

        roundTrip("x = {'a': \"<&>\"}  # comment & more", "python")
        roundTrip("{\"k\": \"a <b> & c\", \"n\": 1}", "json")
        roundTrip("echo \"hello $USER\" # <not a tag>", "bash")
        roundTrip("SELECT * FROM t WHERE a < 3 -- note", "sql")
    }

    func testAmpersandEntitiesInSourceSurviveExactly() {
        // Code that literally contains "&lt;" must come back as "&lt;", not as
        // "<". This is what makes the unescape direction-safe.
        roundTrip("var s = \"&lt;div&gt;\" + \"&amp;\"", "javascript")
    }

    func testUnknownLanguageIsLeftAlone() {
        XCTAssertNil(SyntaxHighlighter.highlight("+[->+<]", language: "brainfuck"))
        XCTAssertNil(SyntaxHighlighter.highlight("x", language: ""))
        XCTAssertFalse(SyntaxHighlighter.supports("cobol"))
    }

    func testTokensAreClassified() {
        let html = SyntaxHighlighter.highlight(
            "let n = 42 // note\nlet s = \"hi\"", language: "swift") ?? ""
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">let</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-number\">42</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-comment\">// note</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-string\">&quot;hi&quot;</span>"))
    }

    func testCallSitesAreMarkedAsFunctions() {
        let html = SyntaxHighlighter.highlight("total(x)", language: "python") ?? ""
        XCTAssertTrue(html.contains("<span class=\"tok-function\">total</span>"))
    }

    /// An unterminated literal must not paint the rest of the block. A stray
    /// apostrophe in a shell comment is extremely common.
    func testUnterminatedStringStopsAtTheLineEnd() {
        let code = "echo don't\nexport PATH=/usr/bin\n"
        let html = SyntaxHighlighter.highlight(code, language: "bash") ?? ""
        XCTAssertTrue(html.contains("export"), "the next line must survive")
        XCTAssertFalse(html.contains("<span class=\"tok-string\">'t\nexport"))
        roundTrip(code, "bash")
    }

    func testKeywordInsideAStringIsNotAKeyword() {
        let html = SyntaxHighlighter.highlight("s = \"return let func\"",
                                               language: "swift") ?? ""
        XCTAssertFalse(html.contains("tok-keyword\">return"))
    }

    func testEmptyAndWhitespaceInputAreSafe() {
        XCTAssertEqual(SyntaxHighlighter.highlight("", language: "swift"), "")
        roundTrip("\n\n   \n", "swift")
    }

    func testUnicodeSurvives() {
        roundTrip("let 名前 = \"café — ok ↩\" // 日本語", "swift")
    }

    // MARK: - Applying it to cmark's output

    func testSourcePositionsSurviveHighlighting() throws {
        let html = try MarkdownRenderer.renderHTML("```swift\nlet x = 1\n```\n")
        XCTAssertTrue(html.contains("data-sourcepos="),
                      "the diff view depends on positions staying on the <pre>")
        XCTAssertTrue(html.contains("tok-keyword"))
    }

    func testFenceWithoutALanguageIsUntouched() throws {
        let html = try MarkdownRenderer.renderHTML("```\njust text\n```\n")
        XCTAssertFalse(html.contains("tok-"))
        XCTAssertTrue(html.contains("just text"))
    }

    func testHighlightingCanBeDisabled() throws {
        let html = try MarkdownRenderer.renderHTML(
            "```swift\nlet x = 1\n```\n",
            options: [.sourcePositions, .rawHTML])
        XCTAssertFalse(html.contains("tok-"))
    }

    func testInlineCodeIsNotHighlighted() throws {
        let html = try MarkdownRenderer.renderHTML("Some `let x = 1` inline.\n")
        XCTAssertFalse(html.contains("tok-"), "only fenced blocks are highlighted")
    }

    /// Prose that merely looks like a code fence opener must not send the
    /// scanner hunting for a `</code>` that is not there.
    func testMalformedCodeMarkupDoesNotEatTheDocument() {
        let html = "<p>before</p><pre><code class=\"language-swift\">let x = 1"
        let out = CodeHighlighting.apply(to: html)
        XCTAssertTrue(out.contains("<p>before</p>"))
        XCTAssertTrue(out.contains("let x = 1"))
    }

    func testDocumentWithNoCodeBlocksIsReturnedUnchanged() {
        let html = "<p>nothing here</p>"
        XCTAssertEqual(CodeHighlighting.apply(to: html), html)
    }

    func testTwoBlocksInDifferentLanguages() throws {
        let html = try MarkdownRenderer.renderHTML(
            "```swift\nlet a = 1\n```\n\n```python\nb = 2\n```\n")
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">let</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-number\">2</span>"))
    }
}
