import XCTest
@testable import AgentiaCore

final class ThemeStoreTests: XCTestCase {

    func testBundledThemesLoadInOrder() throws {
        let themes = try ThemeStore.bundled().loadAll()

        XCTAssertGreaterThanOrEqual(themes.count, 6, "six themes ship with the app")

        let orders = themes.map(\.manifest.order)
        XCTAssertEqual(orders, orders.sorted(), "themes come back in manifest order")

        let ids = Set(themes.map(\.id))
        for expected in ["manuscript", "report", "technical",
                         "editorial", "compact", "terminal"] {
            XCTAssertTrue(ids.contains(expected), "missing theme: \(expected)")
        }
    }

    func testEveryThemeHasUsableStylesheetsAndManifest() throws {
        for theme in try ThemeStore.bundled().loadAll() {
            XCTAssertFalse(theme.name.isEmpty, "\(theme.id) has a name")
            XCTAssertFalse(theme.manifest.description.isEmpty, "\(theme.id) has a description")
            XCTAssertFalse(theme.css.isEmpty, "\(theme.id) has CSS")

            XCTAssertTrue(theme.css.contains("--font-body"),
                          "\(theme.id) sets a body font token")
            XCTAssertTrue(theme.css.contains("@page"),
                          "\(theme.id) declares page geometry for print")
            XCTAssertFalse(theme.manifest.page.size.isEmpty)
            XCTAssertFalse(theme.manifest.page.margin.isEmpty)

            // A theme must never pull a remote resource: the page has no
            // network and an @import would silently fail.
            XCTAssertFalse(theme.css.contains("@import"), "\(theme.id) uses @import")
            XCTAssertFalse(theme.css.contains("http://"), "\(theme.id) references http")
            XCTAssertFalse(theme.css.contains("https://"), "\(theme.id) references https")
        }
    }

    func testEveryThemeFontStackEndsInASystemFallback() throws {
        // Optional OFL families may be absent; the last entry must be a generic
        // family so text still renders in something sensible.
        let generics = ["serif", "sans-serif", "monospace", "system-ui"]

        for theme in try ThemeStore.bundled().loadAll() {
            for (role, stack) in [("body", theme.manifest.fonts.body),
                                  ("heading", theme.manifest.fonts.heading),
                                  ("mono", theme.manifest.fonts.mono)] {
                let last = stack.split(separator: ",").last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? ""
                XCTAssertTrue(generics.contains(last),
                              "\(theme.id) \(role) stack ends in '\(last)'")
            }
        }
    }

    func testLoadingUnknownThemeThrows() throws {
        let store = try ThemeStore.bundled()
        XCTAssertThrowsError(try store.load(id: "no-such-theme"))
    }

    func testThemeIdCannotEscapeTheThemeDirectory() throws {
        // Theme ids arrive from persisted preferences, so they are untrusted.
        let store = try ThemeStore.bundled()
        for hostile in ["../../etc", "..", ".", "a/b", "a\\b", ""] {
            XCTAssertThrowsError(try store.load(id: hostile), "should reject '\(hostile)'")
        }
    }
}

final class DocumentKindTests: XCTestCase {

    func testMarkdownExtensions() {
        for ext in ["md", "MD", "markdown", "mdown", "mkd", "qmd", "Rmd"] {
            XCTAssertEqual(DocumentKind.forFileExtension(ext), .markdown, "ext: \(ext)")
        }
    }

    func testHTMLExtensions() {
        for ext in ["html", "HTML", "htm", "xhtml"] {
            XCTAssertEqual(DocumentKind.forFileExtension(ext), .html, "ext: \(ext)")
        }
    }

    func testUnknownExtensionsFallBackToPlainText() {
        // "text" used to be claimed as Markdown, which meant .text files were
        // parsed as GFM rather than shown as source.
        for ext in ["json", "py", "log", "text", "txt", ""] {
            XCTAssertEqual(DocumentKind.forFileExtension(ext), .plainText, "ext: \(ext)")
        }
    }

    func testClassificationFromURL() {
        XCTAssertEqual(DocumentKind.forURL(URL(fileURLWithPath: "/a/report.md")), .markdown)
        XCTAssertEqual(DocumentKind.forURL(URL(fileURLWithPath: "/a/dash.html")), .html)
        XCTAssertEqual(DocumentKind.forURL(URL(fileURLWithPath: "/a/notes.txt")), .plainText)
        // A dotted name must not be mistaken for an extension chain.
        XCTAssertEqual(DocumentKind.forURL(URL(fileURLWithPath: "/a/v1.2.report.md")), .markdown)
    }

    func testRenderProfileMapping() {
        XCTAssertEqual(DocumentKind.markdown.renderProfile, .markdown)
        XCTAssertEqual(DocumentKind.plainText.renderProfile, .markdown)
        // Only HTML artifacts get to run their own code.
        XCTAssertEqual(DocumentKind.html.renderProfile, .htmlArtifact)
    }
}

final class DocumentRendererTests: XCTestCase {

    private func makeRenderer() throws -> DocumentRenderer {
        DocumentRenderer(shell: try RenderShell.bundled())
    }

    private func makeTheme() throws -> Theme {
        try ThemeStore.bundled().load(id: "report")
    }

    private func write(_ contents: String, named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentia-\(UUID().uuidString)-\(name)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsMarkdownFile() throws {
        let url = try write("# Hello\n", named: "doc.md")
        let snapshot = try DocumentRenderer.read(contentsOf: url)

        XCTAssertEqual(snapshot.kind, .markdown)
        XCTAssertEqual(snapshot.source, "# Hello\n")
        XCTAssertEqual(snapshot.displayName, url.lastPathComponent)
        XCTAssertEqual(snapshot.assetRoot, url.deletingLastPathComponent())
    }

    func testMissingFileThrows() {
        let url = URL(fileURLWithPath: "/definitely/not/here.md")
        XCTAssertThrowsError(try DocumentRenderer.read(contentsOf: url))
    }

    func testMarkdownDocumentRendersThroughTheMarkdownProfile() throws {
        let url = try write("# Title\n\nBody.\n", named: "doc.md")
        let snapshot = try DocumentRenderer.read(contentsOf: url)
        let page = try makeRenderer().page(for: snapshot, theme: try makeTheme())

        XCTAssertTrue(page.contains("<h1"))
        XCTAssertTrue(page.contains("script-src 'sha256-"),
                      "markdown must render under the pinned-hash profile")
    }

    func testHTMLArtifactIsServedUnchangedUnderItsOwnProfile() throws {
        let body = "<h1>Dashboard</h1><script>chart()</script>"
        let url = try write(body, named: "dash.html")
        let snapshot = try DocumentRenderer.read(contentsOf: url)
        let page = try makeRenderer().page(for: snapshot, theme: try makeTheme())

        XCTAssertTrue(page.contains(body), "artifact markup is passed through verbatim")
        XCTAssertTrue(page.contains("script-src 'unsafe-inline' 'unsafe-eval'"))
        XCTAssertTrue(page.contains("connect-src 'none'"),
                      "an artifact may run code but must not reach the network")
    }

    func testPlainTextIsEscapedIntoAPreBlock() throws {
        let url = try write("<not markup> & \"quoted\"\n", named: "notes.log")
        let snapshot = try DocumentRenderer.read(contentsOf: url)
        let page = try makeRenderer().page(for: snapshot, theme: try makeTheme())

        XCTAssertTrue(page.contains("<pre><code>"))
        XCTAssertTrue(page.contains("&lt;not markup&gt;"))
        XCTAssertFalse(page.contains("<not markup>"),
                       "plain text must never reach the page as markup")
    }

    func testNonUTF8FileStillOpens() throws {
        // A viewer that refuses to show a file is worse than one that shows it
        // imperfectly.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentia-\(UUID().uuidString).md")
        try Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let snapshot = try DocumentRenderer.read(contentsOf: url)
        XCTAssertFalse(snapshot.source.isEmpty)
    }
}
