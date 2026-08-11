import XCTest
@testable import AgentiaCore

/// Exercises the parsing core against real cmark-gfm.
///
/// Ported from `tools/ctest/test_markdown.c`, which tested the same behaviour
/// through the C shim before it moved to Swift. The port was verified by
/// running both implementations over the same corpus and byte-comparing the
/// output, so these assertions describe behaviour that was preserved, not
/// behaviour that was re-derived.
final class MarkdownParsingTests: XCTestCase {

    private func render(
        _ markdown: String,
        _ options: MarkdownRenderer.Options = .default
    ) throws -> String {
        try MarkdownRenderer.renderHTML(markdown, options: options)
    }

    /// The C suite's `AGENTIA_MD_UNSAFE_HTML`-only flag set, used wherever it
    /// checked that a default-on behaviour switches off.
    private let rawHTMLOnly: MarkdownRenderer.Options = [.rawHTML]

    // MARK: - Basics

    func testHeadingsEmphasisAndStrong() throws {
        let html = try render("# Title\n\nSome *emphasis* and **strong**.\n")
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("Title</h1>"))
        XCTAssertTrue(html.contains("<em>emphasis</em>"))
        XCTAssertTrue(html.contains("<strong>strong</strong>"))
    }

    func testInlineCode() throws {
        XCTAssertTrue(try render("Text with `inline code` here.\n")
            .contains("<code>inline code</code>"))
    }

    func testFencedCodeBlock() throws {
        let html = try render("```swift\nlet x = 1\n```\n")
        XCTAssertTrue(html.contains("<pre"), "fenced block produces pre")
        XCTAssertTrue(html.contains("language-swift"), "info string becomes a class")
        XCTAssertTrue(html.contains("let x = 1"), "code content preserved")
    }

    func testLists() throws {
        let html = try render("- one\n- two\n\n1. first\n2. second\n")
        XCTAssertTrue(html.contains("<ul"))
        XCTAssertTrue(html.contains("<ol"))
    }

    func testBlockquoteAndLink() throws {
        XCTAssertTrue(try render("> quoted\n").contains("<blockquote"))
        XCTAssertTrue(try render("[link](https://example.com)\n")
            .contains("href=\"https://example.com\""))
    }

    // MARK: - GFM extensions

    func testTableExtension() throws {
        let html = try render("| Metric | Value |\n| ------ | ----: |\n| Recall | 0.849 |\n")
        XCTAssertTrue(html.contains("<table"), "table extension active")
        XCTAssertTrue(html.contains("<th"), "table header cell")
        XCTAssertTrue(html.contains("0.849"), "table body content")
        XCTAssertTrue(html.contains("align=\"right\""), "column alignment honoured")
    }

    func testStrikethroughAndAutolink() throws {
        XCTAssertTrue(try render("~~struck~~\n").contains("<del>struck</del>"))
        XCTAssertTrue(try render("Visit https://example.com today.\n")
            .contains("<a href=\"https://example.com\""))
    }

    func testTasklistExtension() throws {
        let html = try render("- [ ] todo\n- [x] done\n")
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("disabled"), "task checkboxes are disabled")
        XCTAssertTrue(html.contains("checked"), "completed task is checked")
    }

    func testFootnotesEnabled() throws {
        let html = try render("A note[^1]\n\n[^1]: The footnote text.\n")
        XCTAssertTrue(html.contains("footnote"))
        XCTAssertTrue(html.contains("The footnote text"))
    }

    // MARK: - Footnote backref repair

    /// swift-cmark's gfm branch emits an unterminated `aria-label` on the
    /// footnote backref, which swallows the rest of the document. These pin
    /// both the repair and the paths it must not touch.
    func testSingleFootnoteBackrefIsRepaired() throws {
        let html = try render("A note[^1]\n\n[^1]: Body text.\n")
        XCTAssertFalse(html.contains("reference 1\u{21A9}"),
                       "unterminated aria-label must be repaired")
        XCTAssertTrue(html.contains("aria-label=\"Back to reference 1\">\u{21A9}"),
                      "backref closes its attribute and tag")
        XCTAssertTrue(html.contains("Body text"))
    }

    func testNamedFootnoteTakesTheSamePath() throws {
        let html = try render("See[^method]\n\n[^method]: How it works.\n")
        XCTAssertTrue(html.contains("aria-label=\"Back to reference 1\">"))
        XCTAssertFalse(html.contains("reference 1\u{21A9}"))
    }

    func testTwoFootnotesGetTwoRepairs() throws {
        let html = try render("A[^a] and B[^b]\n\n[^a]: First.\n\n[^b]: Second.\n")
        XCTAssertTrue(html.contains("aria-label=\"Back to reference 1\">"))
        XCTAssertTrue(html.contains("aria-label=\"Back to reference 2\">"))
        XCTAssertFalse(html.contains("reference 1\u{21A9}"))
        XCTAssertFalse(html.contains("reference 2\u{21A9}"))
    }

    /// A footnote referenced twice takes the multi-backref path, which upstream
    /// already writes correctly. The repair must leave it alone.
    func testCorrectMultiBackrefIsNotDoublePatched() throws {
        let html = try render("A[^x] then again[^x]\n\n[^x]: Shared.\n")
        XCTAssertFalse(html.contains("\">\">"))
    }

    func testLiteralArrowInProseIsPreserved() throws {
        let html = try render("Press the return arrow \u{21A9} to continue.\n")
        XCTAssertTrue(html.contains("\u{21A9}"))
        XCTAssertFalse(html.contains("\">\u{21A9}"), "no spurious quote inserted")
    }

    func testProseResemblingThePatternIsUntouched() throws {
        XCTAssertTrue(try render("Back to reference 1 is a phrase, not markup.\n")
            .contains("Back to reference 1 is a phrase"))
    }

    /// The repair used to match on the aria-label alone and would inject `">`
    /// mid-attribute, closing the tag early and spilling the rest of the
    /// document into the page as text.
    func testAuthorRawHTMLIsNotRewritten() throws {
        let html = try render(
            "<span aria-label=\"Back to reference 1\u{21A9} and more\">visible</span>\n")
        XCTAssertTrue(html.contains("and more"), "author markup is not truncated")
        XCTAssertFalse(html.contains("1\">\u{21A9} and more"),
                       "no quote injected into author markup")
    }

    func testDocumentWithoutFootnotesTakesTheZeroCopyPath() throws {
        XCTAssertTrue(try render("# Plain\n\nNothing to repair.\n")
            .contains("Nothing to repair"))
    }

    /// The real failure mode was structural: malformed markup ended the
    /// document early. Assert well-formedness directly rather than only
    /// pattern-matching.
    func testFootnoteOutputIsWellFormed() throws {
        let documents = [
            "A note[^1]\n\n[^1]: Body.\n",
            "# H\n\nText[^a]\n\n## H2\n\nMore\n\n[^a]: Note.\n",
            "| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter[^n]\n\n[^n]: End.\n",
        ]

        for document in documents {
            let html = try render(document)

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
    }

    // MARK: - Structural tag neutralisation

    func testClosingMainIsNeutralised() throws {
        let html = try render("# Hi\n\n</main>\n\n<div>overlay</div>\n")
        XCTAssertFalse(html.contains("</main>"))
        XCTAssertTrue(html.contains("&lt;/main"), "becomes visible text")
        XCTAssertTrue(html.contains("<div>"), "ordinary raw HTML still passes through")
    }

    func testOpeningMainIsNeutralised() throws {
        XCTAssertFalse(try render("<main id=\"agentia-doc\">fake</main>\n")
            .contains("<main"))
    }

    /// CSP does not govern top-level navigation, so a meta refresh would
    /// genuinely navigate the view away from the document.
    func testMetaAndBaseAreNeutralised() throws {
        let meta = try render("<meta http-equiv=\"refresh\" content=\"0; url=http://evil\">\n")
        XCTAssertFalse(meta.contains("<meta"))
        XCTAssertTrue(meta.contains("&lt;meta"))

        XCTAssertFalse(try render("<base href=\"http://evil/\">\n").contains("<base"))
    }

    func testDocumentStructureTagsAreNeutralised() throws {
        let html = try render("<html><head></head><body>x</body></html>\n")
        XCTAssertFalse(html.contains("<html"))
        XCTAssertFalse(html.contains("<body"))
    }

    /// A tag name must be followed by a delimiter, so ordinary words survive.
    func testLongerTagNameIsNotMistakenForMain() throws {
        XCTAssertTrue(try render("The <mainstay> of the argument.\n")
            .contains("<mainstay>"))
    }

    func testProseContainingTheWordsIsUntouched() throws {
        XCTAssertTrue(try render("Discussing metadata and the main point.\n")
            .contains("metadata and the main point"))
    }

    func testNeutralisationIsCaseInsensitive() throws {
        let html = try render("<MeTa charset=\"utf-8\">\n<FRAME>\n")
        XCTAssertFalse(html.contains("<MeTa"))
        XCTAssertFalse(html.contains("<FRAME"))
    }

    /// Opt-out must work, for callers embedding into a full document.
    func testNeutralisationCanBeDisabled() throws {
        XCTAssertTrue(try render("</main>\n", rawHTMLOnly).contains("</main>"))
    }

    // MARK: - Front matter

    func testYAMLFrontMatterIsStripped() throws {
        let html = try render("""
        ---
        title: Incident Review
        date: 2026-08-07
        tags: [incident, postmortem]
        ---

        # Incident Review

        Body.

        """)

        XCTAssertFalse(html.contains("<hr"), "no stray thematic break")
        XCTAssertFalse(html.contains("title: Incident Review"),
                       "metadata is not rendered as content")
        XCTAssertFalse(html.contains("postmortem"), "metadata values are not rendered")
        XCTAssertTrue(html.contains("<h1"), "the real title still renders")
        XCTAssertTrue(html.contains("Body."))

        // Line numbering must be preserved or every diff highlight shifts. The
        // heading is on line 7 of the original file.
        XCTAssertTrue(html.contains("data-sourcepos=\"7:1-7:17\""),
                      "source positions still match the original file")
    }

    func testTOMLFrontMatterIsStripped() throws {
        let html = try render("+++\ntitle = \"x\"\n+++\n\n# Real\n")
        XCTAssertFalse(html.contains("title ="))
        XCTAssertTrue(html.contains("<h1"))
    }

    func testYAMLBlockClosedWithEllipsisIsStripped() throws {
        XCTAssertFalse(try render("---\na: 1\n...\n\n# Real\n").contains("a: 1"))
    }

    func testOrdinaryThematicBreakSurvives() throws {
        XCTAssertTrue(try render("# Title\n\n---\n\nAfter.\n").contains("<hr"))
    }

    func testUnclosedBlockIsOrdinaryContent() throws {
        XCTAssertTrue(try render("---\ntitle: x\n\n# Real\n").contains("title: x"))
    }

    func testLeadingRuleWithNoBlockIsARule() throws {
        XCTAssertTrue(try render("---\n\n# Real\n").contains("<hr"))
    }

    func testFrontMatterStrippingCanBeDisabled() throws {
        XCTAssertTrue(try render("---\ntitle: x\n---\n\n# Real\n", rawHTMLOnly)
            .contains("title: x"))
    }

    /// Front matter is blanked rather than removed precisely so that byte and
    /// line counts survive. A CRLF file must keep the same guarantee.
    func testCRLFFrontMatterPreservesLineNumbering() throws {
        let html = try render("---\r\ntitle: x\r\n---\r\n\r\n# Real\r\n")
        XCTAssertFalse(html.contains("title: x"))
        XCTAssertTrue(html.contains("data-sourcepos=\"5:1"),
                      "the heading is still reported on line 5")
    }

    // MARK: - Nesting depth cap

    func testShallowNestingStillRenders() throws {
        let document = String(repeating: ">", count: 40) + " quoted\n"
        XCTAssertNoThrow(try render(document))
    }

    /// Guards the layout engine rather than the parser. cmark handles absurd
    /// nesting quickly; laying it out is quadratic and never finishes.
    func testDeepNestingBombIsRejectedAndQuickly() throws {
        let bomb = String(repeating: ">", count: 200_000) + "\n"

        let start = Date()
        XCTAssertThrowsError(try render(bomb)) { error in
            XCTAssertEqual(error as? MarkdownRenderer.Error, .renderFailed)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "rejection must be fast, not a hang")
    }

    /// The depth counter used to increment per text node and never come back
    /// down, which reported any large document as pathologically deep.
    func testLargeButShallowDocumentIsNotMistakenForDeep() throws {
        let unit = "## Head\n\nSome prose with `code`.\n\n"
        let document = String(repeating: unit, count: (512 * 1024) / unit.count)
        XCTAssertNoThrow(try render(document))
    }

    // MARK: - Source positions

    func testSourcePositionsMapToOriginalLines() throws {
        let html = try render("# One\n\nParagraph two.\n\n## Three\n")
        XCTAssertTrue(html.contains("data-sourcepos=\"1:1-1:5\""), "heading on line 1")
        XCTAssertTrue(html.contains("data-sourcepos=\"3:1-3:14\""), "paragraph on line 3")
        XCTAssertTrue(html.contains("data-sourcepos=\"5:1-5:8\""), "heading on line 5")
    }

    func testSourcePositionsSuppressedWhenFlagIsOff() throws {
        XCTAssertFalse(try render("# One\n", rawHTMLOnly).contains("data-sourcepos"))
    }

    // MARK: - Raw HTML and tagfilter

    func testBenignRawHTMLPassesThrough() throws {
        let html = try render("<details><summary>More</summary>\n\nBody\n\n</details>\n")
        XCTAssertTrue(html.contains("<details"))
        XCTAssertTrue(html.contains("<summary>"))
    }

    func testTagFilterNeutralisesTheGFMBlocklist() throws {
        let script = try render("<script>alert(1)</script>\n")
        XCTAssertFalse(script.contains("<script>"))
        XCTAssertTrue(script.contains("&lt;script"))

        XCTAssertFalse(try render("<iframe src=\"https://evil.test\"></iframe>\n")
            .contains("<iframe"))
    }

    /// tagfilter does NOT cover attribute-based handlers — this is exactly why
    /// the render shell also ships a CSP. Assert the real behaviour so nobody
    /// later assumes the parser alone is a sanitiser.
    func testEventHandlerAttributesSurviveTheParser() throws {
        XCTAssertTrue(try render("<img src=x onerror=\"alert(1)\">\n")
            .contains("onerror"))
    }

    func testRawHTMLRemovedWhenDisabled() throws {
        XCTAssertFalse(try render("<div>hi</div>\n", [.sourcePositions])
            .contains("<div"))
    }

    // MARK: - Edge cases

    func testEmptyInputRendersEmptyString() throws {
        XCTAssertEqual(try MarkdownRenderer.renderHTML(""), "")
        XCTAssertEqual(try MarkdownRenderer.renderHTML(Data()), "")
    }

    /// The C entry point was length-governed rather than NUL-terminated. The
    /// Swift one takes `Data`, so the equivalent guarantee is that a slice
    /// renders as itself and nothing beyond it leaks in.
    func testRenderIsBoundedByTheDataItIsGiven() throws {
        let full = Data("# Visible\n# Hidden\n".utf8)
        let html = try MarkdownRenderer.renderHTML(full.prefix(10))
        XCTAssertTrue(html.contains("Visible"))
        XCTAssertFalse(html.contains("Hidden"))
    }

    func testInvalidUTF8DoesNotCrash() throws {
        let html = try MarkdownRenderer.renderHTML(Data([0x61, 0xFF, 0xFE, 0x62, 0x0A]))
        XCTAssertFalse(html.isEmpty)
        XCTAssertFalse(html.utf8.contains(0xFF), "invalid byte replaced, not passed through")
    }

    func testInputWithoutTrailingNewline() throws {
        XCTAssertTrue(try render("no trailing newline").contains("no trailing newline"))
    }

    func testOversizedInputIsRejectedBeforeParsing() throws {
        let oversized = Data(repeating: UInt8(ascii: "x"),
                             count: MarkdownRenderer.maximumInputBytes + 1)
        XCTAssertThrowsError(try MarkdownRenderer.renderHTML(oversized)) { error in
            XCTAssertEqual(error as? MarkdownRenderer.Error,
                           .inputTooLarge(bytes: oversized.count))
        }
    }

    // MARK: - Throughput and pathological input

    func testThroughputIsWithinASaneEnvelope() throws {
        let unit = """
        ## Section heading

        This run swapped the reranker and widened the candidate pool from 20 to
        50 documents. Recall improved materially; latency did not degrade as
        much as the pilot suggested. See `harness.py` for the exact sweep.

        | Metric | Run 40 | Run 41 |
        | --- | ---: | ---: |
        | Recall@10 | 0.712 | 0.849 |
        | p99 | 602 ms | 871 ms |

        ```python
        def score(q, docs):
            return rerank(q, docs)[:10]
        ```

        - Table fragmentation accounts for most remaining misses.
        - Acronym collisions need a domain glossary.


        """
        let megabyte = 1024 * 1024
        let document = String(repeating: unit, count: megabyte / unit.utf8.count + 1)
        let sizeInMB = Double(document.utf8.count) / Double(megabyte)

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = Date()
            _ = try render(document)
            best = min(best, Date().timeIntervalSince(start))
        }

        // The envelope depends on the build, and by a lot: a debug build
        // compiles cmark-gfm at -O0 along with everything else, which costs
        // roughly 16x. Measured against the same 1 MB corpus, the C shim at
        // -O2 ran 64 ms and the Swift renderer in a release build 68 ms; the
        // same Swift code under `swift test` takes about a second.
        //
        // So the release bound is the real regression guard, and the debug one
        // exists only to catch a slide into quadratic behaviour, which would
        // show up as orders of magnitude rather than a factor of two.
        #if DEBUG
        let (budget, configuration) = (3000.0, "debug")
        #else
        let (budget, configuration) = (250.0, "release")
        #endif

        let perMB = best / sizeInMB * 1000
        XCTAssertLessThan(perMB, budget,
                          "throughput regressed: \(Int(perMB)) ms/MB (\(configuration))")

        // Reported rather than asserted, as the C suite did: the artifact-scale
        // sizes are what the app actually opens, and a slide into quadratic
        // behaviour shows up here long before it trips the ceiling above.
        var report = String(format: "  throughput (%@): %.1f ms/MB",
                            configuration, perMB)
        for kilobytes in [10, 50, 200] {
            let slice = String(document.prefix(kilobytes * 1024))
            let start = Date()
            _ = try render(slice)
            report += String(format: "  |  %d KB: %.2f ms",
                             kilobytes, Date().timeIntervalSince(start) * 1000)
        }

        // What sourcepos costs. Agentia needs it for the diff view, so the
        // answer decides whether it can stay always-on.
        var bare = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = Date()
            _ = try render(document, [.rawHTML])
            bare = min(bare, Date().timeIntervalSince(start))
        }
        report += String(format: "  |  sourcepos costs %+.1f%%",
                         (best - bare) / bare * 100)

        print(report)
    }

    /// No hard timing assertion beyond a hang guard — hardware varies. This
    /// exists so a regression into quadratic behaviour fails rather than
    /// wedging the suite.
    func testPathologicalInputDoesNotBlowUp() throws {
        let cases: [(name: String, fill: Character, count: Int)] = [
            ("deeply nested emphasis", "*", 20_000),
            ("unclosed brackets", "[", 50_000),
            ("unclosed backticks", "`", 50_000),
            ("angle brackets", "<", 50_000),
        ]

        for (name, fill, count) in cases {
            let document = String(repeating: String(fill), count: count) + "\n"
            let start = Date()
            _ = try? render(document)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5.0, "\(name) took \(elapsed)s")
        }
    }

    // MARK: - Version

    func testCMarkVersionIsReported() {
        let version = MarkdownRenderer.cmarkVersion
        XCTAssertFalse(version.isEmpty)
        // The CVE fixes for quadratic blow-up landed by 0.29.0.gfm.10.
        XCTAssertTrue(version.hasPrefix("0.29.0.gfm."), "unexpected version: \(version)")
    }
}
