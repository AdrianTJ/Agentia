import XCTest
@testable import AgentiaCore

/// The Swift-side contract: the option surface, the error cases, and the
/// performance envelope at the sizes this app actually opens.
///
/// Parsing behaviour itself lives in `MarkdownParsingTests`.
final class MarkdownRendererTests: XCTestCase {

    /// The diff view depends on source positions, so they must be on unless a
    /// caller deliberately turns them off.
    func testDefaultOptionsIncludeSourcePositions() throws {
        let html = try MarkdownRenderer.renderHTML("# One\n")
        XCTAssertTrue(html.contains("data-sourcepos="))
    }

    /// Smart punctuation is deliberately absent from the defaults: a review
    /// tool must not rewrite the characters the reader is checking.
    func testSmartPunctuationIsOffByDefault() throws {
        let quoted = "He said \"hello\" -- and left.\n"
        XCTAssertFalse(try MarkdownRenderer.renderHTML(quoted).contains("\u{201C}"),
                       "straight quotes must survive by default")
        XCTAssertTrue(try MarkdownRenderer.renderHTML(
            quoted, options: [.rawHTML, .smartPunctuation]).contains("\u{201C}"),
                      "and must be available when asked for")
    }

    func testHardBreaksAreOptIn() throws {
        let source = "one\ntwo\n"
        XCTAssertFalse(try MarkdownRenderer.renderHTML(source).contains("<br"))
        XCTAssertTrue(try MarkdownRenderer.renderHTML(
            source, options: [.rawHTML, .hardBreaks]).contains("<br"))
    }

    func testOptionsRoundTripThroughRawValue() {
        let options: MarkdownRenderer.Options = [.sourcePositions, .footnotes]
        XCTAssertEqual(MarkdownRenderer.Options(rawValue: options.rawValue), options)
        XCTAssertTrue(MarkdownRenderer.Options.default.contains(.sourcePositions))
        XCTAssertTrue(MarkdownRenderer.Options.default.contains(.stripFrontMatter))
        XCTAssertFalse(MarkdownRenderer.Options.default.contains(.smartPunctuation))
    }

    func testStringAndDataEntryPointsAgree() throws {
        let source = "# Title\n\nBody **bold**.\n"
        XCTAssertEqual(try MarkdownRenderer.renderHTML(source),
                       try MarkdownRenderer.renderHTML(Data(source.utf8)))
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
        // Generous: measured ~0.5 ms for 10 KB. This only catches a
        // catastrophic regression, not normal variance.
        XCTAssertLessThan(elapsed, 0.5, "artifact-scale parse should be sub-millisecond")
    }
}
