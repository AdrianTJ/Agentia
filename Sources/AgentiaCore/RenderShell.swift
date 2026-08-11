import Foundation
import CryptoKit

/// Locates the shell and theme resources inside the module bundle.
public enum ResourceBundle {

    /// Overridable so tests and command-line tools can point at the repository
    /// copy instead of a built module bundle.
    public static var override: URL?

    private static var base: Bundle { Bundle.module }

    public static var shellDirectory: URL? {
        if let root = override { return root.appendingPathComponent("shell", isDirectory: true) }
        return base.url(forResource: "shell", withExtension: nil)
    }

    public static var themesDirectory: URL? {
        if let root = override { return root.appendingPathComponent("themes", isDirectory: true) }
        return base.url(forResource: "themes", withExtension: nil)
    }
}

/// Assembles a complete, self-contained HTML page from a rendered fragment.
///
/// Everything is inlined — no stylesheet or script is fetched — so first paint
/// costs exactly one load and the page works with the network switched off.
///
/// This must stay behaviourally identical to `tools/webtest/build-page.mjs`,
/// which is what the browser test suite exercises. `RenderShellParityTests`
/// compares the two against shared golden values.
public struct RenderShell: Sendable {

    public enum Error: Swift.Error, Equatable {
        case resourcesMissing
        case templateUnreadable(String)
        /// A placeholder survived substitution, meaning the template and this
        /// code have drifted apart.
        case unsubstitutedPlaceholder(String)
    }

    /// Data handed to the page as JSON. Never interpolated into JavaScript.
    public struct Bootstrap: Codable, Sendable, Equatable {
        public var diffRanges: [DiffRange]?
        public var scrollFraction: Double?
        /// When the baseline was taken, already formatted for display — the
        /// page must not be handed a locale or a date to reason about.
        public var diffSince: String?

        public init(
            diffRanges: [DiffRange]? = nil,
            scrollFraction: Double? = nil,
            diffSince: String? = nil
        ) {
            self.diffRanges = diffRanges
            self.scrollFraction = scrollFraction
            self.diffSince = diffSince
        }

        public static let empty = Bootstrap()
    }

    public enum Appearance: String, Sendable {
        case light, dark
    }

    /// The reader's display preferences, applied over the theme.
    ///
    /// Deliberately a multiplier rather than an absolute size: each theme picks
    /// a body size that suits its measure and typeface, and pinning everything
    /// to "16px" would flatten those choices into one. Scaling preserves the
    /// relationship the theme designed.
    public struct Display: Sendable, Equatable {
        public var fontScale: Double

        public init(fontScale: Double = 1.0) {
            self.fontScale = fontScale
        }

        public static let `default` = Display()

        /// Bounds the scale to something a document can survive.
        ///
        /// Below ~0.7 the measure collapses to a few words a line; above ~2 a
        /// wide table cannot fit the page at any width. Clamped here rather
        /// than at the UI, so no caller can render an unusable page.
        public static let range: ClosedRange<Double> = 0.7...2.0

        /// The CSS this becomes. Empty when nothing is customised, so an
        /// unmodified render carries no extra bytes.
        public var css: String {
            let scale = min(max(fontScale, Self.range.lowerBound), Self.range.upperBound)
            guard scale != 1.0 else { return "" }
            // Four decimal places: enough for every step the UI offers, and it
            // cannot emit an exponent, which CSS would not parse.
            return String(format: ":root{--agentia-scale:%.4f}", scale)
        }
    }

    private let shellDirectory: URL

    public init(shellDirectory: URL) {
        self.shellDirectory = shellDirectory
    }

    public static func bundled() throws -> RenderShell {
        guard let dir = ResourceBundle.shellDirectory else { throw Error.resourcesMissing }
        return RenderShell(shellDirectory: dir)
    }

    // MARK: - Pieces

    public func shellScript() throws -> String {
        try read("shell.js")
    }

    /// `sha256-…` over the shell script, in the form CSP expects.
    ///
    /// Computed from the file rather than hard-coded, so editing shell.js can
    /// never leave a stale hash silently blocking the script.
    public func shellScriptHash() throws -> String {
        Self.sha256Base64(try shellScript())
    }

    static func sha256Base64(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return "sha256-" + Data(digest).base64EncodedString()
    }

    /// The page's Content-Security-Policy.
    ///
    /// Both profiles forbid network access outright. Only scripting differs.
    public static func contentSecurityPolicy(
        profile: RenderProfile,
        scriptHash: String
    ) -> String {
        let scriptSource: String
        switch profile {
        case .markdown:
            scriptSource = "'\(scriptHash)'"
        case .htmlArtifact:
            // A self-contained artifact is worthless if its own chart code
            // cannot run. Containment comes from connect-src and the host's
            // content rule list, not from blocking script.
            scriptSource = "'unsafe-inline' 'unsafe-eval'"
        }

        return [
            "default-src 'none'",
            "img-src artifact: data: blob:",
            "media-src artifact: data:",
            "font-src artifact: data:",
            // Inline styles cannot execute, and agent Markdown uses them
            // constantly, so they are permitted in both profiles.
            "style-src 'unsafe-inline' artifact:",
            "script-src \(scriptSource)",
            "connect-src 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// JSON for the `<script type="application/json">` block.
    ///
    /// `</script` must not survive into the block or it closes early and the
    /// rest of the page is parsed as markup. Escaping the slash keeps the JSON
    /// valid and the payload inert.
    public static func bootstrapJSON(_ bootstrap: Bootstrap) -> String {
        let encoder = JSONEncoder()
        // Stable key order, so the output is reproducible and diffable.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(bootstrap),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return neutraliseClosingScriptTags(json)
    }

    /// Make JSON safe to embed in a `<script>` block by escaping every `<`
    /// as `\u003c`.
    ///
    /// The parsed value is unchanged — `\u003c` is `<` — but no `</script`
    /// can appear in the source text, so the block cannot be closed early.
    ///
    /// An earlier version inserted a backslash before the `/`, which works for
    /// `</script` because `\/` is a legal JSON escape. Extending that trick to
    /// `<!--<script` (which pushes HTML's tokenizer into the double-escaped
    /// state, where the block's own `</script>` stops closing it) produced
    /// `<\!--`, and `\!` is *not* a legal escape — the payload became
    /// unparseable JSON. Escaping the `<` handles every such sequence at once
    /// and stays valid.
    static func neutraliseClosingScriptTags(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func escapeForHTMLText(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(character)
            }
        }
        return out
    }

    // MARK: - Assembly

    public func page(
        content: String,
        theme: Theme,
        title: String,
        appearance: Appearance = .light,
        profile: RenderProfile = .markdown,
        bootstrap: Bootstrap = .empty,
        display: Display = .default
    ) throws -> String {
        let template = try read("shell.html")
        let baseCSS = try read("base.css")
        let js = try shellScript()
        let csp = Self.contentSecurityPolicy(
            profile: profile,
            scriptHash: Self.sha256Base64(js)
        )

        let values: [String: String] = [
            "APPEARANCE": appearance.rawValue,
            "CSP": csp,
            "TITLE": Self.escapeForHTMLText(title),
            "BASE_CSS": baseCSS,
            "THEME_CSS": theme.css,
            "USER_CSS": display.css,
            "BOOTSTRAP_JSON": Self.bootstrapJSON(bootstrap),
            "CONTENT": content,
            "SHELL_JS": js,
        ]

        return Self.substitute(template, values)
    }

    /// Fill placeholders in a single pass.
    ///
    /// Sequential `replacingOccurrences` calls were wrong in both directions: a
    /// token substituted early could be re-substituted by a later pass if the
    /// document happened to contain one, and a token the document mentioned but
    /// this code did not know about aborted the whole render. Documents about
    /// Handlebars, Jinja, Vue or Go templates are an entirely ordinary thing for
    /// an agent to write.
    ///
    /// Scanning once makes substitution non-reentrant by construction: a
    /// placeholder that arrives inside a value is never revisited, and an
    /// unknown one is emitted as literal text rather than failing.
    static func substitute(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(template.count + 8192)

        var index = template.startIndex
        while index < template.endIndex {
            guard template[index] == "{",
                  let afterBraces = template.index(index, offsetBy: 2,
                                                   limitedBy: template.endIndex),
                  template[index..<afterBraces] == "{{",
                  let name = Self.readToken(template, from: afterBraces)
            else {
                out.append(template[index])
                index = template.index(after: index)
                continue
            }

            out += values[name.text] ?? "{{\(name.text)}}"
            index = name.end
        }
        return out
    }

    /// Reads `IDENT}}` starting at `start`, where IDENT is uppercase and
    /// underscores. Bounded so an unmatched `{{` cannot scan to end of file.
    private static func readToken(
        _ text: String,
        from start: String.Index
    ) -> (text: String, end: String.Index)? {
        let maximumNameLength = 32
        var cursor = start
        var length = 0

        while cursor < text.endIndex, length <= maximumNameLength {
            let character = text[cursor]
            if character == "}" {
                guard let close = text.index(cursor, offsetBy: 2,
                                             limitedBy: text.endIndex),
                      text[cursor..<close] == "}}",
                      length > 0
                else { return nil }
                return (String(text[start..<cursor]), close)
            }
            guard character.isUppercase || character == "_" else { return nil }
            cursor = text.index(after: cursor)
            length += 1
        }
        return nil
    }

    static let templateTokens = [
        "{{APPEARANCE}}", "{{CSP}}", "{{TITLE}}", "{{BASE_CSS}}",
        "{{THEME_CSS}}", "{{USER_CSS}}", "{{BOOTSTRAP_JSON}}", "{{CONTENT}}",
        "{{SHELL_JS}}",
    ]

    private func read(_ name: String) throws -> String {
        let url = shellDirectory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Error.templateUnreadable(name)
        }
        return text
    }
}
