import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Renders Markdown to an HTML fragment via cmark-gfm.
///
/// This type owns the whole pipeline: option mapping, extension registration,
/// the parser lifecycle and cmark's ownership rules, the resource ceilings, and
/// the byte-level repairs in `MarkdownPostProcessing`. cmark-gfm itself is the
/// only C left on this path.
///
/// Thread safety: `renderHTML` is safe to call from any thread. Extension
/// registration happens once, behind a lazily-initialised global.
public enum MarkdownRenderer {

    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Emit `data-sourcepos` on block elements. Required by the diff view.
        public static let sourcePositions = Options(rawValue: 1 << 0)
        /// Let raw HTML through. Script execution is stopped by the page CSP.
        public static let rawHTML         = Options(rawValue: 1 << 1)
        public static let hardBreaks      = Options(rawValue: 1 << 2)
        public static let footnotes       = Options(rawValue: 1 << 3)
        /// Curly quotes and dashes. Off by default: a review tool should not
        /// silently rewrite the characters the reader is checking.
        public static let smartPunctuation = Options(rawValue: 1 << 4)
        /// Escape html/head/body/main/meta/base so a document cannot close the
        /// container it is embedded in or navigate the view away.
        public static let neutraliseStructuralTags = Options(rawValue: 1 << 5)
        /// Blank YAML/TOML front matter, preserving line numbers so the diff
        /// view stays aligned.
        public static let stripFrontMatter = Options(rawValue: 1 << 6)

        public static let `default`: Options = [
            .sourcePositions, .rawHTML, .footnotes,
            .neutraliseStructuralTags, .stripFrontMatter,
        ]
    }

    public enum Error: Swift.Error, Equatable {
        /// Input was larger than the hard ceiling.
        case inputTooLarge(bytes: Int)
        /// cmark returned nothing usable — allocation failure, a rejected
        /// input, or output past one of the ceilings below.
        case renderFailed
    }

    /// Largest input accepted, in bytes.
    ///
    /// cmark-gfm has a history of quadratic blow-up on crafted input; a hard
    /// ceiling plus the caller's own watchdog keeps a hostile artifact from
    /// wedging the app.
    public static let maximumInputBytes = 16 * 1024 * 1024

    /// Ceiling on generated HTML, in bytes.
    ///
    /// Markdown expands: a document of nothing but `>` becomes deeply nested
    /// blockquotes and, with source positions on every one, grows about 63x.
    /// An input limit alone therefore does not bound the work handed to the
    /// layout engine.
    public static let maximumOutputBytes = 32 * 1024 * 1024

    /// Deepest block nesting accepted.
    ///
    /// The hazard is not parse time — cmark handles 200k nested blockquotes in
    /// about a third of a second — but layout, which is quadratic in depth:
    /// 100k levels took ~29 s in a browser engine and 200k never finished. No
    /// genuine document nests past a few dozen levels.
    public static let maximumNestingDepth = 96

    /// The cmark-gfm version actually linked in, e.g. `"0.29.0.gfm.13"`.
    public static var cmarkVersion: String {
        guard let version = cmark_version_string() else { return "unknown" }
        return String(cString: version)
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
            let source = raw.bindMemory(to: UInt8.self)

            // Front matter is blanked on a private copy: the caller's buffer
            // may be a memory-mapped file. Documents without it — most of
            // them — skip the copy entirely.
            if options.contains(.stripFrontMatter), FrontMatter.length(of: source) > 0 {
                var owned = Array(source)
                FrontMatter.blank(&owned)
                return owned.withUnsafeBufferPointer { render($0, options: options) }
            }
            return render(source, options: options)
        }

        guard let html = rendered else { throw Error.renderFailed }
        return html
    }

    // MARK: - cmark

    /// The GFM extensions attached to every parse.
    ///
    /// `tagfilter` is deliberately included even though `.rawHTML` lets raw
    /// HTML through: it neutralises the GFM blocklist (script, iframe, style,
    /// and friends) so a hostile artifact has to defeat both the tag filter and
    /// the page's CSP, not just one of them.
    private static let extensionNames = [
        "table", "strikethrough", "autolink", "tagfilter", "tasklist",
    ]

    /// Swift runs a global's initialiser exactly once, thread-safely, which is
    /// what `cmark_gfm_core_extensions_ensure_registered` needs.
    private static let extensionsRegistered: Bool = {
        cmark_gfm_core_extensions_ensure_registered()
        return true
    }()

    private static func cmarkOptions(from options: Options) -> Int32 {
        // CMARK_OPT_VALIDATE_UTF8 is unconditional: the input is a file that
        // some other process wrote, so invalid sequences are a realistic case,
        // and cmark replaces them rather than emitting broken UTF-8 into the
        // web view.
        var out = CMARK_OPT_VALIDATE_UTF8

        if options.contains(.sourcePositions)  { out |= CMARK_OPT_SOURCEPOS }
        if options.contains(.rawHTML)          { out |= CMARK_OPT_UNSAFE }
        if options.contains(.hardBreaks)       { out |= CMARK_OPT_HARDBREAKS }
        if options.contains(.footnotes)        { out |= CMARK_OPT_FOOTNOTES }
        if options.contains(.smartPunctuation) { out |= CMARK_OPT_SMART }

        return Int32(out)
    }

    private static func render(
        _ source: UnsafeBufferPointer<UInt8>,
        options: Options
    ) -> String? {
        _ = extensionsRegistered

        let cmarkOpts = cmarkOptions(from: options)

        guard let parser = cmark_parser_new(cmarkOpts) else { return nil }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            // A missing extension is not fatal — the document still renders,
            // just without that feature. Failing the whole parse would be
            // worse.
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }

        source.withMemoryRebound(to: CChar.self) { chars in
            cmark_parser_feed(parser, chars.baseAddress, chars.count)
        }

        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }

        guard maximumBlockDepth(of: document) <= maximumNestingDepth else {
            return nil
        }

        // The extension list belongs to the parser, so the render has to happen
        // before the parser is freed — which the defer ordering guarantees.
        guard let raw = cmark_render_html(
            document, cmarkOpts, cmark_parser_get_syntax_extensions(parser)
        ) else {
            return nil
        }
        defer { free(raw) }

        let length = strlen(raw)
        guard length <= maximumOutputBytes else { return nil }

        // One copy out of cmark's buffer, because both passes below may need to
        // grow it. Against a parse that costs ~36 ms/MB, the memcpy does not
        // register.
        var html = raw.withMemoryRebound(to: UInt8.self, capacity: length) {
            Array(UnsafeBufferPointer(start: $0, count: length))
        }

        FootnoteBackref.repair(&html)
        if options.contains(.neutraliseStructuralTags) {
            StructuralTags.neutralise(&html)
        }

        return String(decoding: html, as: UTF8.self)
    }

    /// Deepest block nesting in the document.
    ///
    /// Guards the layout engine, not the parser — see `maximumNestingDepth`.
    private static func maximumBlockDepth(
        of root: UnsafeMutablePointer<cmark_node>
    ) -> Int {
        guard let iter = cmark_iter_new(root) else { return 0 }
        defer { cmark_iter_free(iter) }

        var deepest = 0
        while true {
            let event = cmark_iter_next(iter)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER else { continue }

            // Depth comes from the parent chain rather than from counting ENTER
            // and EXIT events: cmark emits EXIT only for container nodes, so a
            // running counter increments on every text node and never comes
            // back down — which reports any large document as pathologically
            // deep.
            //
            // Cost is bounded because the walk stops one step past the limit,
            // and the loop breaks as soon as the answer is decided.
            var depth = 0
            var node = cmark_iter_get_node(iter)
            while node != nil, depth <= maximumNestingDepth + 1 {
                depth += 1
                node = cmark_node_parent(node)
            }

            if depth > deepest { deepest = depth }
            if deepest > maximumNestingDepth { break }
        }

        return deepest
    }
}
