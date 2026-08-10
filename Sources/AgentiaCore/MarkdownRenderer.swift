import Foundation
import CAgentiaMarkdown

/// Renders Markdown to an HTML fragment via cmark-gfm.
///
/// The heavy lifting is in the C shim; this type owns the Swift-side contract:
/// UTF-8 conversion, the empty-input case, and turning a NULL return into a
/// thrown error rather than an empty document.
public enum MarkdownRenderer {

    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Emit `data-sourcepos` on block elements. Required by the diff view.
        public static let sourcePositions = Options(rawValue: AGENTIA_MD_SOURCEPOS)
        /// Let raw HTML through. Script execution is stopped by the page CSP.
        public static let rawHTML         = Options(rawValue: AGENTIA_MD_UNSAFE_HTML)
        public static let hardBreaks      = Options(rawValue: AGENTIA_MD_HARDBREAKS)
        public static let footnotes       = Options(rawValue: AGENTIA_MD_FOOTNOTES)
        /// Curly quotes and dashes. Off by default: a review tool should not
        /// silently rewrite the characters the reader is checking.
        public static let smartPunctuation = Options(rawValue: AGENTIA_MD_SMART)
        /// Escape html/head/body/main/meta/base so a document cannot close the
        /// container it is embedded in or navigate the view away.
        public static let neutraliseStructuralTags =
            Options(rawValue: AGENTIA_MD_NEUTRALISE_STRUCTURAL)
        /// Blank YAML/TOML front matter, preserving line numbers so the diff
        /// view stays aligned.
        public static let stripFrontMatter =
            Options(rawValue: AGENTIA_MD_STRIP_FRONT_MATTER)

        public static let `default`: Options = [
            .sourcePositions, .rawHTML, .footnotes,
            .neutraliseStructuralTags, .stripFrontMatter,
        ]
    }

    public enum Error: Swift.Error, Equatable {
        /// Input was larger than the shim's hard ceiling.
        case inputTooLarge(bytes: Int)
        /// cmark returned NULL — allocation failure or a rejected input.
        case renderFailed
    }

    /// Largest input the renderer accepts, mirroring `AGENTIA_MD_MAX_INPUT`.
    public static let maximumInputBytes = Int(AGENTIA_MD_MAX_INPUT)

    /// Deepest block nesting accepted, mirroring `AGENTIA_MD_MAX_DEPTH`.
    /// Beyond this the renderer refuses rather than handing the layout engine
    /// work that grows quadratically with depth.
    public static let maximumNestingDepth = Int(AGENTIA_MD_MAX_DEPTH)

    /// The cmark-gfm version actually linked in, e.g. `"0.29.0.gfm.13"`.
    public static var cmarkVersion: String {
        String(cString: agentia_md_cmark_version())
    }

    /// Render Markdown source to an HTML fragment (no document wrapper).
    public static func renderHTML(
        _ markdown: String,
        options: Options = .default
    ) throws -> String {
        try renderHTML(Data(markdown.utf8), options: options)
    }

    /// Render raw UTF-8 bytes, for the common case of a file just read from
    /// disk that need not round-trip through `String` first.
    public static func renderHTML(
        _ utf8: Data,
        options: Options = .default
    ) throws -> String {
        guard utf8.count <= maximumInputBytes else {
            throw Error.inputTooLarge(bytes: utf8.count)
        }
        // An empty document renders as an empty fragment. Handled here so the
        // pointer dance below never has to reason about a nil base address.
        guard !utf8.isEmpty else { return "" }

        let rendered: String? = utf8.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let chars = base.assumingMemoryBound(to: CChar.self)
            guard let out = agentia_md_to_html(chars, raw.count, options.rawValue) else {
                return nil
            }
            defer { agentia_md_free(out) }
            return String(cString: out)
        }

        guard let html = rendered else { throw Error.renderFailed }
        return html
    }
}
