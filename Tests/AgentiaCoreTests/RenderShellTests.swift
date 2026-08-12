import XCTest
@testable import AgentiaCore

/// The page assembler must stay byte-compatible with
/// `tools/webtest/build-page.mjs`, which is what the Chromium suite verifies.
/// Golden values are produced by `node tools/gen-golden.mjs`.
final class RenderShellTests: XCTestCase {

    private struct Golden: Decodable {
        struct Pair: Decodable { let input: String; let expected: String }
        struct CSP: Decodable { let markdown: String; let htmlArtifact: String }

        struct ScalePair: Decodable { let input: Double; let expected: String }
        struct Substitution: Decodable {
            let template: String
            let values: [String: String]
            let expected: String
        }

        let shellScriptSHA256: String
        let shellScriptByteLength: Int
        let contentSecurityPolicy: CSP
        let htmlTextEscaping: [Pair]
        let closingScriptNeutralisation: [Pair]
        let displayCSS: [ScalePair]
        let substitution: [Substitution]
    }

    private func loadGolden() throws -> Golden {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "golden",
                              withExtension: "json",
                              subdirectory: "Fixtures"),
            "golden.json is missing — run `node tools/gen-golden.mjs`"
        )
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    /// The reader's font scale, pinned against the JS implementation.
    ///
    /// Both clamp to the same range and format to four decimals, and both carry
    /// the print reset inside the same declaration. Until now this pairing was
    /// verified only by reading the two side by side — which is exactly the
    /// drift the golden harness exists to prevent.
    func testDisplayCSSMatchesGolden() throws {
        for pair in try loadGolden().displayCSS {
            XCTAssertEqual(RenderShell.Display(fontScale: pair.input).css,
                           pair.expected,
                           "font scale \(pair.input) drifted from build-page.mjs")
        }
    }

    /// Placeholder substitution, likewise. The interesting cases are the ones
    /// that must NOT happen: a value containing a token is not re-substituted,
    /// and an unknown token survives as literal text rather than aborting the
    /// render — a document about Handlebars or Jinja is ordinary agent output.
    func testSubstitutionMatchesGolden() throws {
        for case_ in try loadGolden().substitution {
            XCTAssertEqual(RenderShell.substitute(case_.template, case_.values),
                           case_.expected,
                           "substitution drifted for \(case_.template)")
        }
    }

    private func makeShell() throws -> RenderShell {
        try RenderShell.bundled()
    }

    private func makeTheme() throws -> Theme {
        try ThemeStore.bundled().load(id: "manuscript")
    }

    // MARK: - Parity with the JavaScript implementation

    func testShellScriptHashMatchesGolden() throws {
        let golden = try loadGolden()
        let shell = try makeShell()

        XCTAssertEqual(try shell.shellScriptHash(), golden.shellScriptSHA256,
                       """
                       shell.js hash drifted. If shell.js was edited on purpose, \
                       re-run `node tools/gen-golden.mjs`.
                       """)
        XCTAssertEqual(try shell.shellScript().utf8.count, golden.shellScriptByteLength)
    }

    func testContentSecurityPolicyMatchesGolden() throws {
        let golden = try loadGolden()
        let hash = golden.shellScriptSHA256

        XCTAssertEqual(
            RenderShell.contentSecurityPolicy(profile: .markdown, scriptHash: hash),
            golden.contentSecurityPolicy.markdown
        )
        XCTAssertEqual(
            RenderShell.contentSecurityPolicy(profile: .htmlArtifact, scriptHash: hash),
            golden.contentSecurityPolicy.htmlArtifact
        )
    }

    func testHTMLTextEscapingMatchesGolden() throws {
        for pair in try loadGolden().htmlTextEscaping {
            XCTAssertEqual(RenderShell.escapeForHTMLText(pair.input), pair.expected,
                           "input: \(pair.input)")
        }
    }

    func testClosingScriptNeutralisationMatchesGolden() throws {
        for pair in try loadGolden().closingScriptNeutralisation {
            XCTAssertEqual(RenderShell.neutraliseClosingScriptTags(pair.input),
                           pair.expected,
                           "input: \(pair.input)")
        }
    }

    // MARK: - Security invariants

    func testMarkdownProfilePinsScriptToTheActualScriptHash() throws {
        let shell = try makeShell()
        let page = try shell.page(content: "<p>hi</p>",
                                  theme: try makeTheme(),
                                  title: "T",
                                  profile: .markdown)

        let hash = try shell.shellScriptHash()
        XCTAssertTrue(page.contains("script-src '\(hash)'"),
                      "the CSP must pin the hash of the script actually embedded")
        XCTAssertFalse(page.contains("script-src 'unsafe-inline'"))
    }

    func testBothProfilesForbidNetworkAccess() throws {
        let shell = try makeShell()
        let theme = try makeTheme()

        for profile in [RenderProfile.markdown, .htmlArtifact] {
            let page = try shell.page(content: "<p>hi</p>", theme: theme,
                                      title: "T", profile: profile)
            XCTAssertTrue(page.contains("connect-src 'none'"), "profile: \(profile)")
            XCTAssertTrue(page.contains("default-src 'none'"), "profile: \(profile)")

            // Assert against the policy itself rather than the whole page: a
            // stylesheet comment mentioning a URL should not fail this.
            let policy = RenderShell.contentSecurityPolicy(
                profile: profile,
                scriptHash: try shell.shellScriptHash()
            )
            XCTAssertFalse(policy.contains("http"),
                           "no remote origin may appear in the CSP for \(profile)")
            XCTAssertFalse(policy.contains("*"),
                           "no wildcard source may appear in the CSP for \(profile)")
        }
    }

    func testBootstrapCannotCloseItsOwnScriptBlock() throws {
        // A payload containing "</script>" would otherwise end the JSON block
        // and have the remainder parsed as markup. "<!--<script" is just as
        // dangerous: it pushes the tokenizer into the double-escaped state,
        // where the block's own </script> stops closing it.
        for hostile in ["</script><b>", "<!--<script>", "</SCRIPT >"] {
            let source = #"{"x":"\#(hostile)"}"#
            let escaped = RenderShell.neutraliseClosingScriptTags(source)

            XCTAssertFalse(escaped.lowercased().contains("</script"),
                           "for: \(hostile)")
            XCTAssertFalse(escaped.lowercased().contains("<!--<script"),
                           "for: \(hostile)")

            // Escaping must not corrupt the payload: it has to remain valid
            // JSON that decodes to exactly the original value.
            let decoded = try JSONSerialization.jsonObject(
                with: Data(escaped.utf8)) as? [String: String]
            XCTAssertEqual(decoded?["x"], hostile,
                           "escaped JSON must round-trip unchanged")
        }
    }

    func testTitleIsEscaped() throws {
        let shell = try makeShell()
        let page = try shell.page(content: "<p>x</p>",
                                  theme: try makeTheme(),
                                  title: "<script>alert(1)</script> & co")

        XCTAssertTrue(page.contains("&lt;script&gt;"))
        XCTAssertTrue(page.contains("&amp; co"))
        XCTAssertFalse(page.contains("<title><script>"))
    }

    // MARK: - Assembly

    func testNoPlaceholderSurvives() throws {
        let shell = try makeShell()
        let page = try shell.page(content: "<p>content</p>",
                                  theme: try makeTheme(),
                                  title: "Title")

        for token in RenderShell.templateTokens {
            XCTAssertFalse(page.contains(token), "unsubstituted token: \(token)")
        }
    }

    /// Substitution is a single pass, so a placeholder that arrives inside a
    /// value is never revisited.
    func testDocumentContentCannotIntroduceAPlaceholder() throws {
        let shell = try makeShell()
        let page = try shell.page(content: "<p>{{SHELL_JS}}</p>",
                                  theme: try makeTheme(),
                                  title: "T")

        XCTAssertTrue(page.contains("<p>{{SHELL_JS}}</p>"),
                      "a placeholder in document text must not be substituted")
    }

    /// A document about templating languages must still open. Sequential
    /// replacement used to abort the whole render on an unknown token, which
    /// surfaced as the window simply not updating.
    func testUnknownPlaceholdersInContentArePassedThrough() throws {
        let shell = try makeShell()
        let content = "<p>Use {{USER_NAME}} and {{ NOT_A_TOKEN }} and {{lowercase}}.</p>"
        let page = try shell.page(content: content, theme: try makeTheme(), title: "T")

        XCTAssertTrue(page.contains("{{USER_NAME}}"))
        XCTAssertTrue(page.contains("{{ NOT_A_TOKEN }}"))
        XCTAssertTrue(page.contains("{{lowercase}}"))
    }

    func testKnownPlaceholderInTheTitleIsNotExpanded() throws {
        // The filename reaches the template as a value, not as template text.
        let shell = try makeShell()
        let page = try shell.page(content: "<p>x</p>", theme: try makeTheme(),
                                  title: "{{BASE_CSS}}.md")

        XCTAssertTrue(page.contains("<title>{{BASE_CSS}}.md</title>"),
                      "a token in the filename must not dump a stylesheet into the title")
    }

    func testSubstituteHandlesUnterminatedBraces() {
        // An unmatched "{{" must not scan to end of file.
        XCTAssertEqual(RenderShell.substitute("a {{ b", [:]), "a {{ b")
        XCTAssertEqual(RenderShell.substitute("{{}}", [:]), "{{}}")
        XCTAssertEqual(RenderShell.substitute("{{X}}", ["X": "1"]), "1")
        XCTAssertEqual(RenderShell.substitute("{{X}}{{X}}", ["X": "1"]), "11")
        // A value containing a placeholder is not revisited.
        XCTAssertEqual(RenderShell.substitute("{{X}}", ["X": "{{X}}"]), "{{X}}")
    }

    func testPageEmbedsThemeAndBaseStylesAndScript() throws {
        let shell = try makeShell()
        let theme = try makeTheme()
        let page = try shell.page(content: "<p>x</p>", theme: theme, title: "T")

        XCTAssertTrue(page.contains("--measure"), "base stylesheet is inlined")
        let themeMarker = String(theme.css
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(40))
        XCTAssertTrue(page.contains(themeMarker), "theme stylesheet is inlined")
        XCTAssertTrue(page.contains("agentia-bootstrap"))
        XCTAssertTrue(page.contains("id=\"agentia-doc\""))
        // No external resource may be referenced.
        XCTAssertFalse(page.contains("<link "))
        XCTAssertFalse(page.contains("src=\"http"))
    }

    func testAppearanceIsApplied() throws {
        let shell = try makeShell()
        let theme = try makeTheme()

        let light = try shell.page(content: "", theme: theme, title: "T", appearance: .light)
        let dark = try shell.page(content: "", theme: theme, title: "T", appearance: .dark)

        XCTAssertTrue(light.contains(#"data-appearance="light""#))
        XCTAssertTrue(dark.contains(#"data-appearance="dark""#))
    }

    func testBootstrapCarriesDiffRanges() throws {
        let shell = try makeShell()
        let bootstrap = RenderShell.Bootstrap(
            diffRanges: [DiffRange(start: 3, end: 5, kind: .added)],
            scrollFraction: 0.25
        )
        let page = try shell.page(content: "", theme: try makeTheme(),
                                  title: "T", bootstrap: bootstrap)

        XCTAssertTrue(page.contains("\"start\":3"))
        XCTAssertTrue(page.contains("\"end\":5"))
        XCTAssertTrue(page.contains("\"added\""))
    }

    func testEmptyBootstrapSerialisesToEmptyObject() {
        XCTAssertEqual(RenderShell.bootstrapJSON(.empty), "{}")
    }
}
