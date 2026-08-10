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

        public init(diffRanges: [DiffRange]? = nil, scrollFraction: Double? = nil) {
            self.diffRanges = diffRanges
            self.scrollFraction = scrollFraction
        }

        public static let empty = Bootstrap()
    }

    public enum Appearance: String, Sendable {
        case light, dark
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

    static func neutraliseClosingScriptTags(_ json: String) -> String {
        // Matches "</script" case-insensitively and inserts a backslash after
        // the "<". The matched text is reused verbatim so case is preserved:
        // the sequence sits inside a JSON string value, and rewriting
        // "</SCRIPT" as "<\/script" would alter the data as well as
        // neutralising the tag.
        let needleLength = 8 // "</script"
        var out = ""
        out.reserveCapacity(json.count)
        var index = json.startIndex

        while index < json.endIndex {
            if json[index] == "<",
               let end = json.index(index, offsetBy: needleLength, limitedBy: json.endIndex),
               json[index..<end].lowercased() == "</script" {
                out.append("<")
                out.append("\\")
                out += json[json.index(after: index)..<end]
                index = end
            } else {
                out.append(json[index])
                index = json.index(after: index)
            }
        }
        return out
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
        bootstrap: Bootstrap = .empty
    ) throws -> String {
        let template = try read("shell.html")
        let baseCSS = try read("base.css")
        let js = try shellScript()
        let csp = Self.contentSecurityPolicy(
            profile: profile,
            scriptHash: Self.sha256Base64(js)
        )

        // Order matters only in that content is substituted before the script:
        // document text can therefore never introduce a placeholder that a
        // later substitution would fill in.
        let substitutions: [(String, String)] = [
            ("{{APPEARANCE}}", appearance.rawValue),
            ("{{CSP}}", csp),
            ("{{TITLE}}", Self.escapeForHTMLText(title)),
            ("{{BASE_CSS}}", baseCSS),
            ("{{THEME_CSS}}", theme.css),
            ("{{BOOTSTRAP_JSON}}", Self.bootstrapJSON(bootstrap)),
            ("{{CONTENT}}", content),
            ("{{SHELL_JS}}", js),
        ]

        var out = template
        for (token, value) in substitutions {
            out = out.replacingOccurrences(of: token, with: value)
        }

        // A surviving placeholder means the template gained a token this code
        // does not know about. Failing loudly beats shipping "{{FOO}}" to the
        // reader.
        for token in Self.templateTokens where out.contains(token) {
            throw Error.unsubstitutedPlaceholder(token)
        }

        return out
    }

    static let templateTokens = [
        "{{APPEARANCE}}", "{{CSP}}", "{{TITLE}}", "{{BASE_CSS}}",
        "{{THEME_CSS}}", "{{BOOTSTRAP_JSON}}", "{{CONTENT}}", "{{SHELL_JS}}",
    ]

    private func read(_ name: String) throws -> String {
        let url = shellDirectory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Error.templateUnreadable(name)
        }
        return text
    }
}
