import XCTest
@testable import AgentiaCore

/// The raw artifact path adds exactly one thing to a document it does not
/// control: a CSP `<meta>`. Every test here is really about the same question —
/// does that meta end up somewhere it actually governs the page? A meta that
/// lands inside a comment, inside a script, or after the document's own
/// `<script>` is not a weaker policy, it is no policy at all, and nothing about
/// the rendered page would look wrong.
final class RawArtifactTests: XCTestCase {

    private let csp = RenderShell.contentSecurityPolicy(
        profile: .htmlArtifact, scriptHash: ""
    )

    private func page(_ html: String) -> String {
        RawArtifact.page(html: html, csp: csp)
    }

    /// Index of the injected meta, or nil.
    private func metaOffset(_ page: String) -> Int? {
        page.range(of: "<meta http-equiv=\"Content-Security-Policy\"")
            .map { page.distance(from: page.startIndex, to: $0.lowerBound) }
    }

    private func offset(of needle: String, in page: String) -> Int? {
        page.range(of: needle).map { page.distance(from: page.startIndex, to: $0.lowerBound) }
    }

    // MARK: - Placement

    func testMetaGoesInsideHead() {
        let html = "<!doctype html><html><head><title>T</title></head><body>x</body></html>"
        let out = page(html)

        let meta = try! XCTUnwrap(metaOffset(out))
        let head = try! XCTUnwrap(offset(of: "<head>", in: out))
        let title = try! XCTUnwrap(offset(of: "<title>", in: out))

        XCTAssertGreaterThan(meta, head, "meta belongs inside head, not before it")
        XCTAssertLessThan(meta, title, "meta must precede the head's own content")
    }

    func testMetaFollowsTheDoctypeRatherThanPrecedingIt() {
        let out = page("<!doctype html><html><head></head><body>x</body></html>")
        let doctype = try! XCTUnwrap(offset(of: "<!doctype html>", in: out))
        let meta = try! XCTUnwrap(metaOffset(out))
        // Content before the doctype triggers quirks mode, which would silently
        // change the artifact's layout.
        XCTAssertGreaterThan(meta, doctype)
        XCTAssertTrue(out.hasPrefix("<!doctype html>"))
    }

    func testDocumentWithoutHeadUsesHTMLTag() {
        let out = page("<html><body><script>window.x=1</script></body></html>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let script = try! XCTUnwrap(offset(of: "<script>", in: out))
        XCTAssertLessThan(meta, script, "the CSP must precede any script")
    }

    func testBareFragmentGetsTheMetaFirst() {
        let out = page("<div>hello</div>")
        XCTAssertEqual(metaOffset(out), 0)
    }

    func testFragmentStartingWithScriptStillGetsCoveredFirst() {
        let out = page("<script>window.x=1</script><div>hi</div>")
        XCTAssertEqual(metaOffset(out), 0, "a leading script must not outrun the policy")
    }

    // MARK: - Documents that try to misdirect the scan

    /// `<!-- <head> -->` is the cheap way to defeat a substring search. A meta
    /// injected into a comment is not markup, so the page would run with no CSP
    /// while looking completely normal.
    func testCommentedHeadIsIgnored() {
        let html = "<!doctype html><!-- <head> --><html><head><title>T</title></head><body>x</body></html>"
        let out = page(html)

        let meta = try! XCTUnwrap(metaOffset(out))
        let commentEnd = try! XCTUnwrap(offset(of: "-->", in: out))
        XCTAssertGreaterThan(meta, commentEnd, "meta must not land inside the comment")

        let title = try! XCTUnwrap(offset(of: "<title>", in: out))
        XCTAssertLessThan(meta, title, "and must still be inside the real head")
    }

    /// A `<head` written by a script — `document.write("<head>")` — is not a
    /// tag. Injecting there is a syntax error that takes the artifact's own
    /// code down with it.
    func testHeadInsideScriptBodyIsIgnored() {
        let html = "<html><script>document.write(\"<head>\")</script><body>x</body></html>"
        let out = page(html)

        let meta = try! XCTUnwrap(metaOffset(out))
        let script = try! XCTUnwrap(offset(of: "<script>", in: out))
        XCTAssertLessThan(meta, script, "meta goes after <html>, before the script")
    }

    /// The elements whose content is text, not markup.
    ///
    /// Found by adversarial review after the first version shipped handling
    /// only comments and `<script>`. `<title>The <head> tag</title>` put the
    /// meta inside RCDATA, where it is displayed as text and enforces nothing —
    /// and unlike the comment case, this one happens by accident, in a document
    /// nobody wrote to be hostile.
    func testHeadInsideRawTextElementsIsIgnored() {
        let cases = [
            ("title", "<html><title>The <head> tag</title><body>x</body></html>"),
            ("textarea", "<html><body><textarea><head></textarea>x</body></html>"),
            ("style", "<html><body><style>/* <head> */</style>x</body></html>"),
            ("noscript", "<html><body><noscript><head></noscript>x</body></html>"),
            ("xmp", "<html><body><xmp><head></xmp>x</body></html>"),
        ]

        for (name, html) in cases {
            let out = page(html)
            let meta = try! XCTUnwrap(metaOffset(out), "\(name): no meta emitted")
            let open = try! XCTUnwrap(offset(of: "<\(name)", in: out))
            XCTAssertLessThan(meta, open,
                              "\(name): meta must precede the raw-text element, "
                              + "not land inside it where it enforces nothing")
        }
    }

    /// An unclosed raw-text element swallows the rest of the document as text,
    /// which is exactly what a browser does — so the meta must already be out
    /// in front of it.
    func testUnclosedRawTextElementDoesNotSwallowTheMeta() {
        let out = page("<html><title>never closed <head> and on it goes")
        let meta = try! XCTUnwrap(metaOffset(out))
        let title = try! XCTUnwrap(offset(of: "<title>", in: out))
        XCTAssertLessThan(meta, title)
    }

    /// The skip must key on the whole tag name: `<styled>` is not `<style>`.
    func testRawTextSkipRequiresATagBoundary() {
        let out = page("<html><head></head><body><styles-note>x</styles-note></body></html>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let head = try! XCTUnwrap(offset(of: "<head>", in: out))
        XCTAssertGreaterThan(meta, head, "a real <head> still wins")
    }

    func testHeaderTagIsNotMistakenForHead() {
        let out = page("<html><body><header>nav</header></body></html>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let header = try! XCTUnwrap(offset(of: "<header>", in: out))
        XCTAssertLessThan(meta, header)
    }

    func testAttributeContainingAngleBracketDoesNotEndTheTagEarly() {
        let out = page("<html data-expr=\"a>b\"><head></head><body>x</body></html>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let head = try! XCTUnwrap(offset(of: "<head>", in: out))
        XCTAssertGreaterThan(meta, head, "the quoted > must not be read as the tag end")
    }

    func testUppercaseTagsAreRecognised() {
        let out = page("<!DOCTYPE HTML><HTML><HEAD></HEAD><BODY>x</BODY></HTML>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let head = try! XCTUnwrap(offset(of: "<HEAD>", in: out))
        XCTAssertGreaterThan(meta, head)
    }

    func testHeadWithAttributesIsRecognised() {
        let out = page("<html><head lang=\"en\"><title>T</title></head></html>")
        let meta = try! XCTUnwrap(metaOffset(out))
        let title = try! XCTUnwrap(offset(of: "<title>", in: out))
        XCTAssertLessThan(meta, title)
    }

    // MARK: - Readability fallback

    /// Found by dogfooding: an unstyled fragment rendered black-on-black under
    /// a dark system appearance, because the engine paints a dark canvas for
    /// undeclared HTML but leaves the text black. The shell used to hide this
    /// by imposing its own paper and ink; serving artifacts raw exposed it.
    func testUnstyledFragmentGetsAReadableGround() {
        let out = page("<div><h1>Build summary</h1><p>3 tests failed.</p></div>")
        XCTAssertTrue(out.contains("background-color:#fff"),
                      "a document that styles nothing must still be readable")
        XCTAssertTrue(out.contains("color-scheme:only light"))
    }

    /// The fallback must never fight an artifact that dresses itself.
    func testStyledArtifactsAreLeftAlone() {
        let styled = [
            "sets a background": "<html><head><style>body{background:#0b0f14}</style></head>"
                + "<body>x</body></html>",
            "sets a colour": "<html><head><style>body{color:#eee}</style></head>"
                + "<body>x</body></html>",
            "supports dark mode": "<html><head><style>"
                + "@media (prefers-color-scheme: dark){body{background:#000}}"
                + "</style></head><body>x</body></html>",
            "declares a scheme": "<html><head><meta name=\"color-scheme\" content=\"dark\">"
                + "</head><body>x</body></html>",
            "inline style": "<div style=\"background:#111\">x</div>",
        ]

        for (why, html) in styled {
            XCTAssertFalse(page(html).contains("background-color:#fff"),
                           "\(why): the artifact decides its own colours")
        }
    }

    func testFallbackLosesToTheArtifactsOwnRules() {
        // Declared first and at :root, so anything the document says wins.
        let out = page("<div><h1>x</h1></div>")
        let fallback = try! XCTUnwrap(offset(of: "color-scheme:only light", in: out))
        let content = try! XCTUnwrap(offset(of: "<div>", in: out))
        XCTAssertLessThan(fallback, content)
    }

    // MARK: - What it must not do

    func testDocumentContentIsOtherwiseUntouched() {
        let html = """
        <!doctype html><html><head><style>body{background:#111}</style></head>\
        <body><pre>kept &amp; verbatim</pre></body></html>
        """
        let out = page(html)

        // Removing exactly the injected meta must give back the original bytes.
        let meta = try! XCTUnwrap(
            out.range(of: "<meta http-equiv=\"Content-Security-Policy\"[^>]*>",
                      options: .regularExpression))
        XCTAssertEqual(out.replacingCharacters(in: meta, with: ""), html)
    }

    func testNoShellMarkupIsAdded() {
        let out = page("<!doctype html><html><head></head><body><pre>x</pre></body></html>")
        XCTAssertFalse(out.contains("agentia-doc"), "no shell container")
        XCTAssertFalse(out.contains("class=\"doc\""), "no .doc typography wrapper")
        XCTAssertFalse(out.contains("agentia-copy"), "no injected copy buttons")
        XCTAssertFalse(out.contains("agentia-bootstrap"), "no bootstrap block")
    }

    func testPolicyIsTheArtifactProfileAndForbidsNetwork() {
        let out = page("<html><head></head><body>x</body></html>")
        XCTAssertTrue(out.contains("connect-src &#39;none&#39;")
                      || out.contains("connect-src 'none'"),
                      "an artifact must not be able to phone home")
        XCTAssertTrue(out.contains("default-src") && out.contains("'none'"))
    }

    /// The CSP is ours, but it is written into a document that is not, so it is
    /// escaped like any other attribute value rather than trusted.
    func testCSPIsAttributeEscaped() {
        let out = RawArtifact.page(html: "<html><head></head></html>",
                                   csp: "script-src 'self'; x=\"><script>alert(1)</script>")
        XCTAssertFalse(out.contains("\"><script>alert(1)"),
                       "a quote in the policy must not break out of the attribute")
        XCTAssertTrue(out.contains("&quot;"))
    }

    func testEmptyDocumentDoesNotCrash() {
        XCTAssertFalse(page("").isEmpty, "still emits the policy")
    }

    func testUnterminatedTagDoesNotHang() {
        // Truncated mid-tag: must terminate, and must not lose the document.
        let out = page("<!doctype html><html><head lang=\"en\"")
        XCTAssertTrue(out.contains("<!doctype html>"))
    }

    func testUnicodeIsPreserved() {
        let out = page("<html><head></head><body><p>café — 日本語 ↩</p></body></html>")
        XCTAssertTrue(out.contains("café — 日本語 ↩"))
    }

    // MARK: - Through the renderer

    func testRendererServesHTMLDocumentsRaw() throws {
        let shell = try RenderShell.bundled()
        let renderer = DocumentRenderer(shell: shell)
        let theme = try ThemeStore.bundled().loadAll().first!

        let source = "<!doctype html><html><head><title>Dash</title></head>"
            + "<body><h1>Dashboard</h1></body></html>"
        let snapshot = DocumentSnapshot(
            url: URL(fileURLWithPath: "/tmp/dash.html"), kind: .html, source: source)

        let out = try renderer.page(for: snapshot, theme: theme)

        XCTAssertTrue(out.contains("<h1>Dashboard</h1>"))
        XCTAssertFalse(out.contains("agentia-doc"), "artifacts skip the shell")
        XCTAssertNotNil(out.range(of: "Content-Security-Policy"))
    }

    /// The raw-versus-shell decision must have exactly one home.
    ///
    /// Regression guard for a real miss: the app's window controller assembled
    /// its own page and never called `page(for:)`, so moving artifacts to the
    /// raw path changed this type, the CLI and the browser suite while the app
    /// went on splicing artifacts into the shell — with every test green. Both
    /// callers now ask `standalonePage(for:)`, and this pins its answers.
    func testStandalonePageDecidesForEveryKind() {
        func snapshot(_ kind: DocumentKind, _ source: String) -> DocumentSnapshot {
            DocumentSnapshot(url: URL(fileURLWithPath: "/tmp/x"), kind: kind, source: source)
        }

        XCTAssertNotNil(DocumentRenderer.standalonePage(for: snapshot(.html, "<p>x</p>")),
                        "HTML artifacts are served as themselves")
        XCTAssertNil(DocumentRenderer.standalonePage(for: snapshot(.markdown, "# x")),
                     "Markdown is rendered into the shell")
        XCTAssertNil(DocumentRenderer.standalonePage(for: snapshot(.plainText, "x")),
                     "plain text is rendered into the shell")
    }

    func testStandalonePageAgreesWithTheFullRenderer() throws {
        let renderer = DocumentRenderer(shell: try RenderShell.bundled())
        let theme = try ThemeStore.bundled().loadAll().first!
        let snapshot = DocumentSnapshot(
            url: URL(fileURLWithPath: "/tmp/a.html"), kind: .html,
            source: "<!doctype html><html><head></head><body>x</body></html>")

        XCTAssertEqual(try renderer.page(for: snapshot, theme: theme),
                       DocumentRenderer.standalonePage(for: snapshot),
                       "the two entry points must not drift apart")
    }

    func testRendererStillShellsMarkdown() throws {
        let shell = try RenderShell.bundled()
        let renderer = DocumentRenderer(shell: shell)
        let theme = try ThemeStore.bundled().loadAll().first!

        let snapshot = DocumentSnapshot(
            url: URL(fileURLWithPath: "/tmp/n.md"), kind: .markdown, source: "# Hi\n")
        let out = try renderer.page(for: snapshot, theme: theme)

        XCTAssertTrue(out.contains("agentia-doc"), "markdown keeps the reading shell")
    }
}
