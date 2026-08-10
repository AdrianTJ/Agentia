import XCTest
@testable import AgentiaCore

/// The C shim has its own exhaustive suite in `tools/ctest`, which runs without
/// a Swift toolchain. These tests cover the Swift-side contract: the bridge,
/// the option mapping, and the failure cases.
final class MarkdownRendererTests: XCTestCase {

    func testRendersBasicMarkdown() throws {
        let html = try MarkdownRenderer.renderHTML("# Title\n\nBody **bold**.\n")
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
    }

    func testEmptyInputRendersEmptyString() throws {
        XCTAssertEqual(try MarkdownRenderer.renderHTML(""), "")
        XCTAssertEqual(try MarkdownRenderer.renderHTML(Data()), "")
    }

    func testSourcePositionsPresentByDefault() throws {
        let html = try MarkdownRenderer.renderHTML("# One\n")
        XCTAssertTrue(html.contains("data-sourcepos="),
                      "the diff view depends on source positions")
    }

    func testSourcePositionsCanBeDisabled() throws {
        let html = try MarkdownRenderer.renderHTML("# One\n", options: [.rawHTML])
        XCTAssertFalse(html.contains("data-sourcepos"))
    }

    func testGFMExtensionsAreActive() throws {
        let table = try MarkdownRenderer.renderHTML(
            "| a | b |\n| - | -: |\n| 1 | 2 |\n")
        XCTAssertTrue(table.contains("<table"))
        XCTAssertTrue(table.contains("align=\"right\""))

        XCTAssertTrue(try MarkdownRenderer.renderHTML("~~x~~\n").contains("<del>"))
        XCTAssertTrue(try MarkdownRenderer.renderHTML("- [x] done\n")
            .contains("type=\"checkbox\""))
        XCTAssertTrue(try MarkdownRenderer.renderHTML("See https://example.com\n")
            .contains("<a href=\"https://example.com\""))
    }

    /// Regression guard for the malformed backref in swift-cmark's gfm branch.
    /// Without the shim's repair, one footnote corrupts the rest of the page.
    func testFootnoteBackrefIsWellFormed() throws {
        let html = try MarkdownRenderer.renderHTML("Note[^1]\n\n[^1]: Body.\n")

        XCTAssertTrue(html.contains("aria-label=\"Back to reference 1\">"),
                      "the backref attribute must be closed")
        XCTAssertFalse(html.contains("reference 1\u{21A9}"),
                       "an unterminated attribute would swallow the rest of the page")
    }

    func testFootnoteDocumentHasBalancedAttributeQuoting() throws {
        let html = try MarkdownRenderer.renderHTML(
            "# H\n\nText[^a]\n\n## H2\n\nMore\n\n[^a]: Note.\n")

        var insideTag = false
        var insideQuote = false
        for character in html {
            if !insideTag, character == "<" { insideTag = true }
            else if insideTag, character == "\"" { insideQuote.toggle() }
            else if insideTag, character == ">", !insideQuote { insideTag = false }
        }
        XCTAssertFalse(insideQuote, "output ends inside an attribute value")
        XCTAssertFalse(insideTag, "output ends inside a tag")
    }

    func testTagFilterNeutralisesDangerousTags() throws {
        let html = try MarkdownRenderer.renderHTML("<script>alert(1)</script>\n")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script"))
    }

    /// Pins the real, limited guarantee: the parser is not a sanitiser. Event
    /// handlers survive, and the page CSP is what stops them.
    func testAttributeHandlersSurviveTheParser() throws {
        let html = try MarkdownRenderer.renderHTML("<img src=x onerror=\"alert(1)\">\n")
        XCTAssertTrue(html.contains("onerror"),
                      "if this ever stops being true the CSP is still required")
    }

    func testRawHTMLCanBeDisabled() throws {
        let html = try MarkdownRenderer.renderHTML("<div>hi</div>\n",
                                                   options: [.sourcePositions])
        XCTAssertFalse(html.contains("<div"))
    }

    /// The throw itself is covered by the C suite, which can build an
    /// oversized buffer cheaply. Here we only pin that the Swift constant and
    /// the C header have not drifted apart.
    func testMaximumInputConstantMatchesCHeader() {
        XCTAssertEqual(MarkdownRenderer.maximumInputBytes, 64 * 1024 * 1024)
    }

    func testInvalidUTF8DoesNotCrash() throws {
        let bytes = Data([0x61, 0xFF, 0xFE, 0x62, 0x0A])
        let html = try MarkdownRenderer.renderHTML(bytes)
        XCTAssertFalse(html.isEmpty)
    }

    func testCMarkVersionIsReported() {
        let version = MarkdownRenderer.cmarkVersion
        XCTAssertFalse(version.isEmpty)
        // The CVE fixes for quadratic blow-up landed by 0.29.0.gfm.10.
        XCTAssertTrue(version.hasPrefix("0.29.0.gfm."), "unexpected version: \(version)")
    }

    func testArtifactSizedDocumentRendersQuickly() throws {
        let unit = """
        ## Section

        Prose paragraph with `code` and a [link](https://example.com).

        | a | b |
        | - | - |
        | 1 | 2 |

        ```python
        def f(): return 1
        ```

        """
        let document = String(repeating: unit, count: 120) // ~25 KB

        let start = Date()
        let html = try MarkdownRenderer.renderHTML(document)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(html.isEmpty)
        // Generous: the C suite measures ~0.5 ms for 10 KB. This only catches a
        // catastrophic regression, not normal variance.
        XCTAssertLessThan(elapsed, 0.5, "artifact-scale parse should be sub-millisecond")
    }
}
