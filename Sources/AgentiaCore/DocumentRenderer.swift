import Foundation

/// One document as Agentia holds it in memory.
public struct DocumentSnapshot: Sendable, Equatable {
    public let url: URL
    public let kind: DocumentKind
    /// Raw file contents, decoded as text.
    public let source: String
    /// When the bytes were read, for the "changed since" label.
    public let readAt: Date

    /// The exact bytes this document was read from, so a save can tell whether
    /// anything rewrote the file in the meantime. Nil only when it could not be
    /// read, which the save path treats as "assume it changed".
    public let bytesOnDisk: Data?

    /// How the bytes were encoded, so a save reproduces the same file rather
    /// than a differently-encoded one. See TextFormat.
    public let format: TextFormat

    public init(
        url: URL,
        kind: DocumentKind,
        source: String,
        readAt: Date = Date(),
        bytesOnDisk: Data? = nil,
        format: TextFormat = .utf8
    ) {
        self.url = url
        self.kind = kind
        self.source = source
        self.readAt = readAt
        self.bytesOnDisk = bytesOnDisk
        self.format = format
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

        // Decoding and remembering how are the same step: the app can now edit
        // and write back, so what it took to read the file has to survive.
        guard let decoded = TextFormat.decode(data) else {
            throw Error.undecodable(url)
        }
        let text = decoded.text

        // The bytes just read are what a later save compares against, so a
        // rewrite that lands between now and then is always visible.
        return DocumentSnapshot(url: url, kind: .forURL(url), source: text,
                                bytesOnDisk: data,
                                format: decoded.format)
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
    ///
    /// `source` overrides the snapshot's own text, for the case where the
    /// reader has unsaved edits: the snapshot holds what was read from disk,
    /// and the rendered view has to show what is in the editor instead.
    public static func standalonePage(for snapshot: DocumentSnapshot,
                                      source: String? = nil) -> String? {
        switch snapshot.kind {
        case .markdown, .plainText:
            return nil
        case .html:
            // The script hash is irrelevant here: the artifact profile pins no
            // hash, because the document's own script is meant to run.
            return RawArtifact.page(
                html: source ?? snapshot.source,
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
