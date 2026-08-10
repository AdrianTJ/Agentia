import Foundation

/// One document as Agentia holds it in memory.
public struct DocumentSnapshot: Sendable, Equatable {
    public let url: URL
    public let kind: DocumentKind
    /// Raw file contents, decoded as text.
    public let source: String
    /// When the bytes were read, for the "changed since" label.
    public let readAt: Date

    public init(url: URL, kind: DocumentKind, source: String, readAt: Date = Date()) {
        self.url = url
        self.kind = kind
        self.source = source
        self.readAt = readAt
    }

    public var displayName: String { url.lastPathComponent }

    /// The folder a document may load assets from.
    public var assetRoot: URL { url.deletingLastPathComponent() }
}

/// Turns a file on disk into a page ready for the web view.
public struct DocumentRenderer: Sendable {

    public enum Error: Swift.Error, Equatable {
        case unreadable(URL)
        /// The file decoded as neither UTF-8 nor the platform fallback.
        case undecodable(URL)
    }

    private let shell: RenderShell

    public init(shell: RenderShell) {
        self.shell = shell
    }

    /// Read a file, guessing its text encoding conservatively.
    ///
    /// Agent output is essentially always UTF-8, but a file that is not must
    /// still open rather than failing — a viewer that refuses to show you the
    /// document is worse than one that shows it imperfectly.
    public static func read(contentsOf url: URL) throws -> DocumentSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            throw Error.unreadable(url)
        }

        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            // Latin-1 maps every possible byte, so this branch always succeeds.
            // The document opens with mojibake rather than not at all, which is
            // the right trade for a viewer.
            text = latin1
        } else {
            throw Error.undecodable(url)
        }

        return DocumentSnapshot(url: url, kind: .forURL(url), source: text)
    }

    /// Produce the full page for a snapshot.
    public func page(
        for snapshot: DocumentSnapshot,
        theme: Theme,
        appearance: RenderShell.Appearance = .light,
        bootstrap: RenderShell.Bootstrap = .empty
    ) throws -> String {
        let fragment: String
        switch snapshot.kind {
        case .markdown:
            fragment = try MarkdownRenderer.renderHTML(snapshot.source)
        case .html:
            // An HTML artifact is its own document; it is served unchanged and
            // contained by the CSP and the host's content rule list.
            fragment = snapshot.source
        case .plainText:
            fragment = "<pre><code>"
                + RenderShell.escapeForHTMLText(snapshot.source)
                + "</code></pre>"
        }

        return try shell.page(
            content: fragment,
            theme: theme,
            title: snapshot.displayName,
            appearance: appearance,
            profile: snapshot.kind.renderProfile,
            bootstrap: bootstrap
        )
    }
}
