import Foundation
import WebKit
import AgentiaCore

/// Messages the page sends back to the app.
enum PageMessage {
    case ready(outline: [OutlineItem], blockCount: Int)
    case scroll(fraction: Double)
    case copy(text: String)
    case openExternal(url: URL)
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
///     inside WebKit before a request is issued,
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

        userContent.add(MessageProxy(target: self), name: Self.messageHandlerName)

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

    func load(page html: String, assetRoot: URL) {
        // A previous document may have been granted network access, which
        // detached the rule list. Re-arm before loading the next one, or the
        // grant would silently persist across documents.
        if networkAllowedForCurrentDocument {
            networkAllowedForCurrentDocument = false
            installContentRuleList()
        }
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
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // The only navigation ever permitted is the initial load of the
        // document itself. Anything else — a meta refresh, a form post, script
        // setting location — is refused, so an artifact cannot replace itself
        // with something else.
        if url.scheme == ArtifactSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            pageDelegate?.webView(self, didReceive: .openExternal(url: url))
        } else {
            noteBlockedRequest()
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        contentRuleListWithIdentifier identifier: String,
        performedAction action: WKContentRuleListAction,
        forURL url: URL
    ) {
        if action.blockedLoad { noteBlockedRequest() }
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
