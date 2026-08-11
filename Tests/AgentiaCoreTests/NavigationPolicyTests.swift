import XCTest
@testable import AgentiaCore

/// The host-side navigation guard.
///
/// This exists because the browser suite cannot reach it: the decision is taken
/// in the host process, not the page, so a Chromium harness has nothing to
/// drive. It became load-bearing when HTML artifacts stopped running the shell
/// script — `shell.js`'s link interception used to be the first line, and this
/// was the backstop; now it is the only one.
final class NavigationPolicyTests: XCTestCase {

    private let scheme = "artifact"
    private let host = "doc"

    private func decide(
        _ string: String?,
        link: Bool = false,
        canScript: Bool = false
    ) -> NavigationPolicy.Decision {
        NavigationPolicy.decide(
            url: string.flatMap(URL.init(string:)),
            isLinkActivation: link,
            documentCanScript: canScript,
            documentScheme: scheme,
            documentHost: host
        )
    }

    // MARK: - The one permitted navigation

    func testTheDocumentsOwnLoadIsAllowed() {
        XCTAssertEqual(decide("artifact://doc"), .allow)
        XCTAssertEqual(decide("artifact://doc/"), .allow)
    }

    /// Script may navigate to `artifact://asset/...` to replace the view with a
    /// raw local file, which buys it a page under no CSP at all. There is no
    /// legitimate navigation to an asset.
    func testAssetHostIsNotNavigable() {
        XCTAssertEqual(decide("artifact://asset/secrets.txt"), .block)
        XCTAssertEqual(decide("artifact://asset/x.png", link: true), .block)
    }

    func testSchemeAndHostAreMatchedCaseInsensitively() {
        XCTAssertEqual(decide("ARTIFACT://DOC"), .allow)
    }

    // MARK: - What a document must never talk the host into

    func testDocumentInitiatedNavigationIsBlocked() {
        // A meta refresh, a form post, script setting location: not link
        // activations, so nothing leaves the app and nothing is opened.
        for url in ["https://evil.test/x", "http://evil.test", "file:///etc/passwd",
                    "javascript:alert(1)", "data:text/html,<h1>x", "about:blank"] {
            XCTAssertEqual(decide(url), .block, "\(url) must not be actionable")
        }
    }

    /// An allowlist, not a blocklist. The point is that a scheme nobody
    /// anticipated is refused by default rather than handed to the system.
    func testOnlyBrowserSchemesEverLeaveTheApp() {
        for url in ["javascript:alert(1)", "data:text/html,<h1>x", "file:///etc/passwd",
                    "vnc://host", "smb://share", "x-apple-helper://do", "ftp://host"] {
            XCTAssertEqual(decide(url, link: true), .block,
                           "\(url) must not be handed to the system")
        }
    }

    func testBrowserSchemesOpenFromANonScriptingDocument() {
        // Markdown cannot run its own script, so a link activation really was
        // the reader clicking.
        for url in ["https://example.com/a", "http://example.com", "mailto:x@example.com"] {
            XCTAssertEqual(decide(url, link: true), .openExternally)
        }
    }

    /// The synthetic-click hole. WebKit classifies `anchor.click()` from a
    /// document's own script as a link activation, indistinguishable from a
    /// real one — so an artifact could put document text in a query string and
    /// have the host open it in the browser, an exfiltration channel that never
    /// touches the web view and so is invisible to `connect-src 'none'` and to
    /// the content rule list.
    func testAScriptingDocumentCannotOpenALinkSilently() {
        XCTAssertEqual(
            decide("https://evil.test/?d=stolen", link: true, canScript: true),
            .confirmBeforeOpening,
            "an artifact must not be able to reach the browser without the reader")
    }

    func testScriptingDocumentStillCannotUseAnUnexpectedScheme() {
        XCTAssertEqual(decide("file:///etc/passwd", link: true, canScript: true), .block)
        XCTAssertEqual(decide("javascript:alert(1)", link: true, canScript: true), .block)
    }

    func testMissingURLIsBlocked() {
        XCTAssertEqual(decide(nil), .block)
        XCTAssertEqual(decide(nil, link: true, canScript: true), .block)
    }

    /// A URL that merely mentions the document host elsewhere must not pass.
    func testLookalikeHostsAreNotTheDocument() {
        XCTAssertEqual(decide("https://doc.evil.test"), .block)
        XCTAssertEqual(decide("artifact://doc.evil.test"), .block)
        XCTAssertEqual(decide("https://evil.test/artifact://doc", link: true),
                       .openExternally, "a normal https link, not the document")
    }
}
