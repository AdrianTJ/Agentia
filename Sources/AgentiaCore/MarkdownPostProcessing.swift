import Foundation

/// Byte-level passes over the Markdown source and cmark's HTML output.
///
/// These work on `[UInt8]` rather than `String` deliberately. Every one of them
/// is a scan for an exact ASCII byte sequence, and `String` would charge for
/// grapheme breaking on input that is often a megabyte of agent output. The
/// front-matter pass additionally *must* be byte-indexed: it preserves offsets,
/// and a `String.Index` walk would not make that guarantee legible.

// MARK: - Front matter

/// Recognises and blanks the YAML/TOML metadata block that agent-written
/// Markdown almost always opens with.
enum FrontMatter {

    /// Length of the front-matter block at the start of `text`, or 0.
    ///
    /// Recognises `---` (YAML) and `+++` (TOML) fences. The opening fence must
    /// be the very first line; the closing fence is `---`, `...` or `+++`
    /// alone on a line. An unterminated block is not front matter — it is a
    /// document that happens to start with a thematic break.
    static func length(of text: UnsafeBufferPointer<UInt8>) -> Int {
        let len = text.count
        guard len >= 4 else { return 0 }

        let fence: UInt8
        if text[0] == UInt8(ascii: "-"), text[1] == UInt8(ascii: "-"),
           text[2] == UInt8(ascii: "-") {
            fence = UInt8(ascii: "-")
        } else if text[0] == UInt8(ascii: "+"), text[1] == UInt8(ascii: "+"),
                  text[2] == UInt8(ascii: "+") {
            fence = UInt8(ascii: "+")
        } else {
            return 0
        }

        var i = 3
        if i < len, text[i] == UInt8(ascii: "\r") { i += 1 }
        guard i < len, text[i] == UInt8(ascii: "\n") else { return 0 }
        i += 1

        while i < len {
            let lineStart = i
            while i < len, text[i] != UInt8(ascii: "\n") { i += 1 }

            var lineEnd = i
            if lineEnd > lineStart, text[lineEnd - 1] == UInt8(ascii: "\r") {
                lineEnd -= 1
            }

            if lineEnd - lineStart == 3 {
                let c = text[lineStart]
                let closesWithFence = c == fence
                    && text[lineStart + 1] == c
                    && text[lineStart + 2] == c
                let closesWithEllipsis = fence == UInt8(ascii: "-")
                    && c == UInt8(ascii: ".")
                    && text[lineStart + 1] == UInt8(ascii: ".")
                    && text[lineStart + 2] == UInt8(ascii: ".")
                if closesWithFence || closesWithEllipsis {
                    // Include the trailing newline.
                    return i < len ? i + 1 : len
                }
            }

            if i < len { i += 1 } // step past the newline
        }

        return 0 // never closed: treat as ordinary content
    }

    /// Overwrite the front-matter region with spaces.
    ///
    /// Spaces rather than removal because byte count and line count must be
    /// preserved: `data-sourcepos` drives the diff view, and shifting the
    /// numbering would misalign every highlighted block in the document.
    static func blank(_ text: inout [UInt8]) {
        let block = text.withUnsafeBufferPointer { length(of: $0) }
        for i in 0..<block where text[i] != UInt8(ascii: "\n")
            && text[i] != UInt8(ascii: "\r") {
            text[i] = UInt8(ascii: " ")
        }
    }
}

// MARK: - Footnote backref repair

/// Repairs a malformed footnote backref emitted by `swiftlang/swift-cmark`.
///
/// `src/html.c:S_put_footnote_backref` writes
///
///     ... aria-label="Back to reference 1↩</a>
///
/// and never closes the attribute. Upstream `github/cmark-gfm` emits `">↩</a>`
/// correctly; Apple's fork dropped the `">` on the single-backref path only
/// (the multi-backref path 20 lines below is right). An unterminated attribute
/// value swallows everything up to the next quote character, so a single
/// footnote corrupts the remainder of the document — in Agentia's case it
/// consumed the closing tags and the shell `<script>` along with them.
///
/// The repair is a targeted byte fixup: find the exact prefix, skip the index,
/// and if what follows is the U+21A9 arrow rather than the quote that should be
/// there, insert the missing `">`.
///
/// This becomes a no-op once the dependency is fixed, because the pattern stops
/// matching — so it is safe to leave in place.
enum FootnoteBackref {

    /// Anchored on the attribute cmark emits immediately before the broken one,
    /// so the repair cannot fire on raw HTML the author happened to write. A
    /// document containing
    ///
    ///     <span aria-label="Back to reference 1↩ and more">
    ///
    /// used to have `">` injected into it, closing the tag early.
    private static let anchor = Array(#"data-footnote-backref-idx=""#.utf8)
    private static let prefix = Array(#"" aria-label="Back to reference "#.utf8)
    /// UTF-8 for U+21A9 LEFTWARDS ARROW WITH HOOK.
    private static let returnArrow: [UInt8] = [0xE2, 0x86, 0xA9]

    /// Returns the offset just past a broken backref's index, or nil if the run
    /// starting at `at` is not one.
    private static func match(_ html: [UInt8], at: Int) -> Int? {
        guard matches(html, anchor, at: at) else { return nil }

        var j = at + anchor.count
        while j < html.count, isIndexByte(html[j]) { j += 1 }

        guard matches(html, prefix, at: j) else { return nil }

        j += prefix.count
        while j < html.count, isIndexByte(html[j]) { j += 1 }

        guard matches(html, returnArrow, at: j) else { return nil }
        return j
    }

    private static func matches(_ html: [UInt8], _ needle: [UInt8], at: Int) -> Bool {
        guard at >= 0, at + needle.count <= html.count else { return false }
        for k in 0..<needle.count where html[at + k] != needle[k] { return false }
        return true
    }

    /// Footnote indices are digits, or digits and hyphens for named footnotes.
    private static func isIndexByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-")
    }

    /// Repair every broken backref in place. Documents without footnotes — the
    /// overwhelming majority — take a scan and no allocation.
    static func repair(_ html: inout [UInt8]) {
        let firstByte = anchor[0]

        // Offsets at which the missing `">` belongs, found in one pass so the
        // rewrite below does not have to re-match.
        var insertAt: [Int] = []
        var i = 0
        while i < html.count {
            guard let hit = html[i...].firstIndex(of: firstByte) else { break }
            if let end = match(html, at: hit) {
                insertAt.append(end)
                i = end
            } else {
                i = hit + 1
            }
        }
        guard !insertAt.isEmpty else { return }

        // Each repair inserts exactly two bytes.
        var out = [UInt8]()
        out.reserveCapacity(html.count + insertAt.count * 2)

        var read = 0
        for end in insertAt {
            out.append(contentsOf: html[read..<end])
            out.append(UInt8(ascii: "\""))
            out.append(UInt8(ascii: ">"))
            read = end
        }
        out.append(contentsOf: html[read...])

        html = out
    }
}

// MARK: - Code highlighting

/// Colours the inside of `<pre><code class="language-…">` blocks.
///
/// Done on cmark's output rather than on its AST so that `data-sourcepos`
/// survives: it lives on the `<pre>`, the diff view depends on it, and
/// rewriting the node would drop it.
///
/// Only the text between `<code …>` and `</code>` is touched, and it is
/// unescaped, highlighted, and re-escaped as one step — so every character
/// still passes through exactly one escaping. Double-escaping would surface as
/// `&amp;lt;` on screen; skipping one would be an injection into a document the
/// CSP is holding at arm's length.
enum CodeHighlighting {

    private static let opener = "<code class=\"language-"

    static func apply(to html: String, maxOutputBytes: Int = .max) -> String {
        guard html.contains(opener) else { return html }

        var out = ""
        out.reserveCapacity(html.count + 512)

        // Everything before `cursor` is already in `out`. `searchFrom` advances
        // independently so a rejected candidate can be skipped without emitting
        // or dropping anything — the skipped bytes stay in the verbatim
        // passthrough.
        var cursor = html.startIndex
        var searchFrom = html.startIndex
        // Bytes committed to `out` so far, so a document that would highlight
        // past the ceiling stops expanding and copies the rest verbatim rather
        // than building a page the size of a phone book in memory first.
        var emitted = 0

        while let start = html.range(of: opener, range: searchFrom..<html.endIndex) {
            guard let quote = html[start.upperBound...].firstIndex(of: "\""),
                  let tagEnd = html[quote...].firstIndex(of: ">")
            else { break } // not a well-formed opener; leave the rest verbatim

            let bodyStart = html.index(after: tagEnd)

            // A genuine cmark code block escapes every `<` in its body to
            // `&lt;`, so the next raw `<` after the opener must begin the
            // block's own `</code>`. If it does not — a raw-HTML `<code>` the
            // author wrote, a nested `<code>`, an unterminated opener — this is
            // not a block this pass owns. Skipping it rather than grabbing a
            // distant `</code>` is what keeps the output well-formed: a flat
            // search used to weld an opener here to the closing tag of an
            // unrelated code block later in the document.
            guard let nextLt = html[bodyStart...].firstIndex(of: "<"),
                  html[nextLt...].hasPrefix("</code>")
            else {
                searchFrom = bodyStart
                continue
            }

            let language = String(html[start.upperBound..<quote])
            let body = String(html[bodyStart..<nextLt])

            let prefix = html[cursor..<bodyStart]
            out += prefix
            emitted += prefix.utf8.count

            // Give the highlighter only the budget left, so the whole page —
            // not just one block — is bounded. A block that would overrun is
            // served as plain (still-escaped) text.
            let remaining = maxOutputBytes == .max ? .max : max(0, maxOutputBytes - emitted)
            let rendered = SyntaxHighlighter.highlight(
                unescape(body), language: language, maxOutputBytes: remaining) ?? body
            out += rendered
            emitted += rendered.utf8.count + "</code>".utf8.count
            out += "</code>"

            cursor = html.index(nextLt, offsetBy: "</code>".count)
            searchFrom = cursor
        }

        out += html[cursor...]
        return out
    }

    /// Reverses exactly what cmark escapes in a code block, left to right so
    /// `&amp;lt;` comes back as the literal `&lt;` rather than as `<`.
    static func unescape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)

        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "&" else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let entities = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                            ("&quot;", "\""), ("&#39;", "'")]
            if let match = entities.first(where: { text[i...].hasPrefix($0.0) }) {
                out += match.1
                i = text.index(i, offsetBy: match.0.count)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }
}

// MARK: - Structural tag neutralisation

/// Escapes tags that are meaningless inside a fragment and dangerous when the
/// fragment is embedded in a host page.
///
/// Raw HTML is allowed through and `tagfilter` covers only the GFM blocklist,
/// so without this a document containing a bare `</main>` closes the container
/// it was embedded in and everything after it becomes a sibling of `<body>` —
/// enough to paint a full-window overlay with no script at all. A
/// `<meta http-equiv=refresh>` is worse: CSP does not govern top-level
/// navigation, so it navigates the view to an arbitrary URL.
///
/// Escaping the leading `<` turns them into visible text, which is also the
/// honest thing to show a reviewer: the document really did contain a
/// `</main>`.
enum StructuralTags {

    private static let names: [[UInt8]] = ([
        // Structural: a fragment must not be able to close the container it is
        // embedded in, or navigate the view.
        "main", "meta", "base", "html", "head", "body", "frameset", "frame",
        // GFM's own blocklist, repeated here as a backstop. cmark's tagfilter
        // is supposed to own these, but it ends a tag name on the same
        // incomplete set of characters this pass used to, so `<style\u{0C}>`
        // and `<script\u{0C}>` went through it untouched. tagfilter is upstream
        // and cannot be fixed here; covering the same names locally means one
        // parser bug is no longer enough. Escaping a tag twice is harmless —
        // the second pass finds nothing left to escape.
        "title", "textarea", "style", "xmp", "iframe",
        "noembed", "noframes", "script", "plaintext",
    ].flatMap { [$0, "/" + $0] }).map { Array($0.utf8) }

    private static func asciiLower(_ c: UInt8) -> UInt8 {
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) ? c + 32 : c
    }

    /// The characters HTML5 ends a tag name on: `>`, `/`, and the five
    /// whitespace characters — space, tab, LF, **FF**, CR.
    static func isTagNameBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: ">"), UInt8(ascii: "/"), UInt8(ascii: " "),
             0x09, 0x0A, 0x0C, 0x0D:
            return true
        default:
            return false
        }
    }

    /// Does a structural tag start at `html[at]` (which must be `<`)?
    ///
    /// A tag name must be followed by a delimiter, so `<mainly` is left alone.
    private static func tagStarts(in html: [UInt8], at: Int) -> Bool {
        for name in names {
            guard at + 1 + name.count <= html.count else { continue }

            var matched = true
            for k in 0..<name.count where asciiLower(html[at + 1 + k]) != name[k] {
                matched = false
                break
            }
            guard matched else { continue }

            let after = at + 1 + name.count
            guard after < html.count else { return true }

            // Every character HTML5 ends a tag name on. The form feed is the
            // one that is easy to forget and the one that mattered: a document
            // containing `</main\u{0C}>` was passed through raw by cmark's
            // tagfilter *and* by this check, and cmark normalised the form feed
            // away on output — so a real `</main>` reached the page, closed the
            // shell's container, and everything after it became a sibling of
            // <body>. That is the full-window-overlay breakout this pass exists
            // to prevent, and no CSP governs it.
            if isTagNameBoundary(html[after]) { return true }
            continue
        }
        return false
    }

    static func neutralise(_ html: inout [UInt8]) {
        let openAngle = UInt8(ascii: "<")

        var hits: [Int] = []
        for i in 0..<html.count where html[i] == openAngle && tagStarts(in: html, at: i) {
            hits.append(i)
        }
        guard !hits.isEmpty else { return }

        // "<" becomes "&lt;": three extra bytes each.
        var out = [UInt8]()
        out.reserveCapacity(html.count + hits.count * 3)

        let escaped = Array("&lt;".utf8)
        var read = 0
        for hit in hits {
            out.append(contentsOf: html[read..<hit])
            out.append(contentsOf: escaped)
            read = hit + 1
        }
        out.append(contentsOf: html[read...])

        html = out
    }
}
