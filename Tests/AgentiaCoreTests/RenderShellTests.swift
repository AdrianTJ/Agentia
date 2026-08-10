import XCTest
@testable import AgentiaCore

/// The page assembler must stay byte-compatible with
/// `tools/webtest/build-page.mjs`, which is what the Chromium suite verifies.
/// Golden values are produced by `node tools/gen-golden.mjs`.
final class RenderShellTests: XCTestCase {

    private struct Golden: Decodable {
        struct Pair: Decodable { let input: String; let expected: String }
        struct CSP: Decodable { let markdown: String; let htmlArtifact: String }

        let shellScriptSHA256: String
        let shellScriptByteLength: Int
        let contentSecurityPolicy: CSP
        let htmlTextEscaping: [Pair]
        let closingScriptNeutralisation: [Pair]
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

    func testBootstrapCannotCloseItsOwnScriptBlock() {
        // A document whose diff payload contained "</script>" would otherwise
        // end the JSON block and have the remainder parsed as markup.
        let json = RenderShell.neutraliseClosingScriptTags(#"{"x":"</script><b>"}"#)
        XCTAssertFalse(json.contains("</script"))
        XCTAssertTrue(json.contains(#"<\/script"#))
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

    func testDocumentContentCannotIntroduceAPlaceholder() throws {
        // Content is substituted before the script, so a placeholder inside the
        // document must survive as literal text rather than being filled in.
        let shell = try makeShell()
        let page = try shell.page(content: "<p>{{SHELL_JS}}</p>",
                                  theme: try makeTheme(),
                                  title: "T")

        XCTAssertTrue(page.contains("<p>{{SHELL_JS}}</p>"),
                      "a placeholder in document text must not be substituted")
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
