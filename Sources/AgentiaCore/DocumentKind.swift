import Foundation

/// What Agentia thinks a file is, which decides both how it renders and how
/// much of its own code is allowed to run.
public enum DocumentKind: String, Sendable, CaseIterable {
    case markdown
    case html
    /// Anything else: shown as monospaced source rather than refused.
    case plainText

    /// Extensions claimed as Markdown. Deliberately broad — agents emit all of
    /// these — but matched case-insensitively against the last path component.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "qmd", "rmd",
    ]

    public static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// Classify by file extension.
    public static func forFileExtension(_ ext: String) -> DocumentKind {
        let normalised = ext.lowercased()
        if markdownExtensions.contains(normalised) { return .markdown }
        if htmlExtensions.contains(normalised) { return .html }
        return .plainText
    }

    public static func forURL(_ url: URL) -> DocumentKind {
        forFileExtension(url.pathExtension)
    }

    /// The trust profile a document of this kind renders under.
    public var renderProfile: RenderProfile {
        switch self {
        case .markdown, .plainText: return .markdown
        case .html: return .htmlArtifact
        }
    }
}

/// How much of a document's own code may execute.
///
/// Neither profile can reach the network: both set `connect-src 'none'` and
/// name no remote origin, and the host additionally installs a content rule
/// list. The profiles differ only in scripting.
public enum RenderProfile: String, Sendable {
    /// Markdown we rendered ourselves. Only the pinned shell script runs, so
    /// nothing embedded in the document can execute.
    case markdown
    /// An HTML artifact. Its own scripts run — a self-contained dashboard is
    /// useless otherwise — but it still cannot phone home.
    case htmlArtifact
}
