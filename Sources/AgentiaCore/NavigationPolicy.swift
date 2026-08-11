import Foundation

/// What the host does with a navigation a document asks for.
///
/// This is the third of the three containment mechanisms, and the only one that
/// a page cannot interfere with: the CSP is a `<meta>` inside the document, the
/// content rule list is attached to the web view, but this decision is taken in
/// the host process for every navigation regardless of what the page does.
///
/// It lives in AgentiaCore rather than in `HardenedWebView` so it can be tested.
/// It previously sat inline in the navigation delegate, which the test target
/// cannot reach — meaning the guarantee "an artifact cannot navigate the view
/// away, and a `javascript:` link does not run" rested on reading the code.
/// That mattered more once HTML artifacts stopped running the shell script,
/// because this became the only guard rather than the second one.
public enum NavigationPolicy {

    public enum Decision: Equatable, Sendable {
        /// The document's own load. The only navigation ever permitted.
        case allow
        /// A link the reader clicked: hand it to the browser.
        case openExternally
        /// A link activation from a document that can run script, so it may not
        /// have been the reader who clicked. Ask before leaving the app.
        case confirmBeforeOpening
        /// Refused, and counted for the toolbar.
        case block
    }

    /// Schemes worth handing to the system.
    ///
    /// An allowlist, not a blocklist: `javascript:`, `data:` and `file:` are the
    /// obvious hazards, but so is anything else a URL can name — `x-apple-*`,
    /// `smb:`, a registered helper for some other app. Naming what is safe is
    /// the only version of this that stays correct as the world adds schemes.
    public static let externallyOpenableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Decide what to do with a navigation.
    ///
    /// - Parameters:
    ///   - url: the target, or nil if the request had none.
    ///   - isLinkActivation: whether the reader clicked a link, as opposed to
    ///     script or markup initiating it. A document must not be able to
    ///     navigate itself just because it can construct a URL.
    ///   - documentCanScript: whether this document's own JavaScript runs, i.e.
    ///     the artifact profile.
    ///
    ///     This is why link activation alone is not enough to leave the app.
    ///     WebKit classifies a navigation as `.linkActivated` from the DOM
    ///     event, not from whether a human caused it, so script inside an
    ///     artifact can call `anchor.click()` and get the same classification a
    ///     real click produces. Opening that URL would hand an arbitrary string
    ///     — document text, for instance — to the user's browser, walking
    ///     straight past `connect-src 'none'` and the content rule list, which
    ///     only ever see requests made *inside* the web view.
    ///
    ///     Markdown cannot script at all, so there a link activation really was
    ///     the reader.
    ///   - documentScheme: the custom scheme documents are served under.
    ///   - documentHost: the single host within that scheme that is the
    ///     document itself.
    public static func decide(
        url: URL?,
        isLinkActivation: Bool,
        documentCanScript: Bool,
        documentScheme: String,
        documentHost: String
    ) -> Decision {
        guard let url else { return .block }

        // The document's own load, and nothing else. The host is checked as
        // well as the scheme: script may navigate to artifact://asset/... to
        // replace the view with a raw local file, which buys it a page with no
        // CSP at all. There is no legitimate navigation to an asset.
        if url.scheme?.lowercased() == documentScheme.lowercased(),
           url.host?.lowercased() == documentHost.lowercased() {
            return .allow
        }

        guard isLinkActivation,
              let scheme = url.scheme?.lowercased(),
              externallyOpenableSchemes.contains(scheme)
        else {
            return .block
        }

        return documentCanScript ? .confirmBeforeOpening : .openExternally
    }
}
