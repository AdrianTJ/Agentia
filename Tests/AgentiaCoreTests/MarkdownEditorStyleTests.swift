import XCTest
@testable import AgentiaCore

/// The styling the editor applies while Markdown is being typed.
///
/// The rule these are all written against: this decides what the text *looks*
/// like, never what it *is*. The document is not touched, so a wrong span is a
/// cosmetic mistake — but a wrong offset is not, because offsets index
/// `NSTextStorage` and a bad one is an exception in the editor.
final class MarkdownEditorStyleTests: XCTestCase {

    private func spans(_ text: String) -> [MarkdownEditorStyle.Span] {
        MarkdownEditorStyle.spans(in: text)
    }

    private func roles(_ text: String) -> [MarkdownEditorStyle.Role] {
        spans(text).map(\.role)
    }

    /// The text a span covers, which is the readable way to assert on offsets.
    private func text(of span: MarkdownEditorStyle.Span, in source: String) -> String {
        let utf16 = Array(source.utf16)
        let slice = Array(utf16[span.location..<(span.location + span.length)])
        return String(decoding: slice, as: UTF16.self)
    }

    private func first(_ role: MarkdownEditorStyle.Role, in source: String) -> String? {
        spans(source).first { $0.role == role }.map { text(of: $0, in: source) }
    }

    // MARK: - Offsets

    /// Every span has to land inside the string. This is the one class of bug
    /// here that is not cosmetic.
    private func assertWellFormed(_ source: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let count = source.utf16.count
        for span in spans(source) {
            XCTAssertGreaterThanOrEqual(span.location, 0, file: file, line: line)
            XCTAssertGreaterThan(span.length, 0, "empty span", file: file, line: line)
            XCTAssertLessThanOrEqual(span.location + span.length, count,
                                     "span runs past the end of the text",
                                     file: file, line: line)
        }
    }

    func testOffsetsSurviveNonASCIIText() {
        // Emoji are two UTF-16 units and accented letters are one, so a scan
        // that counted Characters would drift after either.
        let source = "# Héllo 👋 wörld\n\nSome **bold** after 🎉 emoji\n"
        assertWellFormed(source)
        XCTAssertEqual(first(.bold, in: source), "bold")
        // The heading role covers the whole line, marker included; the `#` is
        // dimmed by a `.syntax` span applied over the top of it.
        XCTAssertEqual(first(.heading(level: 1), in: source), "# Héllo 👋 wörld")
    }

    func testAssortedDocumentsAreWellFormed() {
        for source in [
            "", "\n", "#", "# ", "*", "**", "***", "`", "```", "- ", "[", "[]", "[](",
            "> ", ">>>", "---", "===", "1.", "1. ", "~~", "![](", "a\n\nb\n",
            "```swift\nlet x = 1\n```\n", "# Heading\n\n- item\n\n> quote\n",
        ] {
            assertWellFormed(source)
        }
    }

    // MARK: - Headings

    func testATXHeadingLevels() {
        for level in 1...6 {
            let source = String(repeating: "#", count: level) + " Title\n"
            XCTAssertEqual(first(.heading(level: level), in: source),
                           String(repeating: "#", count: level) + " Title")
        }
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertFalse(roles("####### Title\n").contains { role in
            if case .heading = role { return true }
            return false
        })
    }

    /// `#tag` is a word people write, not a heading.
    func testHashWithoutASpaceIsNotAHeading() {
        XCTAssertFalse(roles("#hashtag\n").contains { role in
            if case .heading = role { return true }
            return false
        })
    }

    func testHeadingMarkerIsMarkedAsSyntax() {
        XCTAssertEqual(first(.syntax, in: "## Title\n"), "##")
    }

    func testSetextHeadings() {
        XCTAssertEqual(first(.heading(level: 1), in: "Title\n=====\n"), "Title")
        XCTAssertEqual(first(.heading(level: 2), in: "Title\n-----\n"), "Title")
    }

    /// `---` after a blank line is a rule, not an underline for the paragraph
    /// three lines up.
    func testDashesAfterABlankLineAreAThematicBreak() {
        let source = "Paragraph\n\n---\n"
        XCTAssertTrue(roles(source).contains(.thematicBreak))
        XCTAssertFalse(roles(source).contains(.heading(level: 2)))
    }

    // MARK: - Emphasis

    func testBoldAndItalic() {
        XCTAssertEqual(first(.bold, in: "a **strong** b"), "strong")
        XCTAssertEqual(first(.italic, in: "a *soft* b"), "soft")
        XCTAssertEqual(first(.boldItalic, in: "a ***both*** b"), "both")
        XCTAssertEqual(first(.strikethrough, in: "a ~~gone~~ b"), "gone")
        XCTAssertEqual(first(.italic, in: "a _soft_ b"), "soft")
        XCTAssertEqual(first(.bold, in: "a __strong__ b"), "strong")
    }

    /// The one that matters most for these documents: identifiers are full of
    /// underscores, and reading them as emphasis would italicise half of every
    /// technical report.
    func testUnderscoresInsideAWordAreNotEmphasis() {
        for source in ["some_variable_name", "a snake_case_word here",
                       "call foo_bar(x) and baz_qux(y)"] {
            XCTAssertFalse(roles(source).contains(.italic), source)
            XCTAssertFalse(roles(source).contains(.bold), source)
        }
    }

    /// `*` has no such rule in CommonMark, and intraword emphasis with it is
    /// both legal and used.
    func testStarsInsideAWordStillEmphasise() {
        XCTAssertEqual(first(.italic, in: "un*frigging*believable"), "frigging")
    }

    func testAnUnclosedDelimiterIsLeftAlone() {
        XCTAssertFalse(roles("a **never closed").contains(.bold))
        XCTAssertFalse(roles("half *open").contains(.italic))
    }

    /// A delimiter with a space after it is not opening anything — this is what
    /// stops a line of prose containing " * " from turning into emphasis.
    func testADelimiterFollowedByASpaceDoesNotOpen() {
        XCTAssertFalse(roles("2 * 3 * 4").contains(.italic))
    }

    // MARK: - Code

    func testInlineCode() {
        XCTAssertEqual(first(.inlineCode, in: "use `let x = 1` here"), "let x = 1")
    }

    /// Nothing inside a code span is Markdown, which is the entire point of one.
    func testMarkdownInsideInlineCodeIsInert() {
        let source = "`**not bold**`"
        XCTAssertFalse(roles(source).contains(.bold))
        XCTAssertEqual(first(.inlineCode, in: source), "**not bold**")
    }

    func testFencedCodeBlock() {
        let source = "```swift\nlet x = **1**\n```\n"
        XCTAssertTrue(roles(source).contains(.codeBlock))
        XCTAssertFalse(roles(source).contains(.bold),
                       "a fence has to make its contents inert")
    }

    func testTildeFence() {
        let source = "~~~\nplain *text*\n~~~\n"
        XCTAssertTrue(roles(source).contains(.codeBlock))
        XCTAssertFalse(roles(source).contains(.italic))
    }

    /// An unclosed fence — which is what a fence is for most of the time it is
    /// being typed — styles the rest of the document as code rather than giving
    /// up.
    func testAnUnclosedFenceRunsToTheEnd() {
        let source = "```\nstill code\nand this too\n"
        let codeSpans = spans(source).filter { $0.role == .codeBlock }
        XCTAssertEqual(codeSpans.count, 2)
    }

    func testHeadingInsideAFenceIsNotAHeading() {
        let source = "```\n# not a heading\n```\n"
        XCTAssertFalse(roles(source).contains { role in
            if case .heading = role { return true }
            return false
        })
    }

    // MARK: - Blocks

    func testListMarkers() {
        for source in ["- item\n", "* item\n", "+ item\n", "1. item\n", "2) item\n"] {
            XCTAssertTrue(roles(source).contains(.listMarker), source)
        }
    }

    /// A bare dash is a dash. Without the required space, every stray hyphen at
    /// the start of a line would become a bullet.
    func testADashWithoutASpaceIsNotAList() {
        XCTAssertFalse(roles("-notalist\n").contains(.listMarker))
    }

    func testBlockQuote() {
        let source = "> quoted **text**\n"
        XCTAssertTrue(roles(source).contains(.blockQuote))
        XCTAssertTrue(roles(source).contains(.bold),
                      "a quote still contains Markdown")
    }

    func testThematicBreak() {
        for source in ["---\n", "***\n", "___\n", "- - -\n"] {
            XCTAssertTrue(roles(source).contains(.thematicBreak), source)
        }
    }

    // MARK: - Links

    func testLink() {
        let source = "see [the report](./report.md) for more"
        XCTAssertEqual(first(.link, in: source), "the report")
    }

    func testImage() {
        let source = "![a chart](chart.png)"
        XCTAssertEqual(first(.link, in: source), "a chart")
    }

    func testBracketsWithoutATargetAreNotALink() {
        XCTAssertFalse(roles("[just brackets] here").contains(.link))
    }

    // MARK: - Cost

    /// Unstyled above the cap rather than slow: this runs on every keystroke,
    /// and a reader who opens a huge log wants the caret to keep up more than
    /// they want headings.
    func testVeryLargeDocumentsAreLeftUnstyled() {
        let huge = String(repeating: "# Heading\n\nSome text here.\n\n",
                          count: 40_000)
        XCTAssertGreaterThan(huge.utf16.count, MarkdownEditorStyle.maximumStyledUnits)
        XCTAssertTrue(spans(huge).isEmpty)
    }

    func testARealisticDocumentIsScannedQuickly() {
        let document = String(
            repeating: """
            ## Section heading

            Some prose with **bold**, *italic*, `code`, and a [link](./a.md).

            - a list item
            - another with some_snake_case in it

            ```swift
            let x = 1
            ```

            """, count: 200)

        // ~90 KB, which is a large agent report. Budget is generous on purpose:
        // this asserts the scan is not accidentally quadratic, not a benchmark.
        let started = Date()
        _ = spans(document)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "styling a \(document.utf16.count / 1024) KB document")
    }
}
