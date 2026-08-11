import Foundation

/// One document as Agentia holds it in memory.
public struct DocumentSnapshot: Sendable, Equatable {
    public let url: URL
    public let kind: DocumentKind
    /// Raw file contents, decoded as text.
    public let source: String
    /// When the bytes were read, for the "changed since" label.
    public let readAt: Date

    /// What the file looked like when it was read, so a save can tell whether
    /// anything rewrote it in the meantime. Nil when the file could not be
    /// stat'd, which the save path treats as "assume it changed".
    public let modifiedOnDisk: Date?
    public let sizeOnDisk: Int?

    public init(
        url: URL,
        kind: DocumentKind,
        source: String,
        readAt: Date = Date(),
        modifiedOnDisk: Date? = nil,
        sizeOnDisk: Int? = nil
    ) {
        self.url = url
        self.kind = kind
        self.source = source
        self.readAt = readAt
        self.modifiedOnDisk = modifiedOnDisk
        self.sizeOnDisk = sizeOnDisk
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

        // Taken after the read, not before: a file rewritten *during* the read
        // must look changed at save time, not identical.
        let fingerprint = DocumentSaving.fingerprint(of: url)

        return DocumentSnapshot(url: url, kind: .forURL(url), source: text,
                                modifiedOnDisk: fingerprint.modified,
                                sizeOnDisk: fingerprint.size)
    }

    /// The complete page for documents that are served as themselves rather
    /// than rendered into the shell, or nil for the ones that are.
    ///
    /// This exists so the raw-versus-shell decision lives in exactly one place.
    /// It did not, once: the app's window controller assembled its own page and
    /// never called `page(for:)`, so when artifacts moved to the raw path the
    /// change reached this type, the CLI and the browser suite — but not the
    /// app, which went on splicing artifacts into `<main class="doc">` while a
    /// full suite of green tests said otherwise.
    public static func standalonePage(for snapshot: DocumentSnapshot) -> String? {
        switch snapshot.kind {
        case .markdown, .plainText:
            return nil
        case .html:
            // The script hash is irrelevant here: the artifact profile pins no
            // hash, because the document's own script is meant to run.
            return RawArtifact.page(
                html: snapshot.source,
                csp: RenderShell.contentSecurityPolicy(
                    profile: .htmlArtifact, scriptHash: ""
                )
            )
        }
    }

    /// Produce the full page for a snapshot.
    public func page(
        for snapshot: DocumentSnapshot,
        theme: Theme,
        appearance: RenderShell.Appearance = .light,
        bootstrap: RenderShell.Bootstrap = .empty
    ) throws -> String {
        // An HTML artifact is its own document and never reaches the shell —
        // wrapping it in `.doc` re-typeset and re-themed work that arrived
        // complete. See RawArtifact.
        if let standalone = Self.standalonePage(for: snapshot) {
            return standalone
        }

        let fragment: String
        switch snapshot.kind {
        case .markdown:
            fragment = try MarkdownRenderer.renderHTML(snapshot.source)
        case .html:
            // Unreachable: handled by standalonePage above.
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
