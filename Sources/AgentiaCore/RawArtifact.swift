import Foundation

/// Serves an HTML artifact as its author wrote it.
///
/// An agent-written dashboard is a complete document with its own layout,
/// typography and colour scheme. Splicing it into the reading shell's
/// `<main class="doc">` clamped it to a 68ch measure, overrode its `<pre>`
/// colours with `.doc pre`, and injected a light-themed Copy button into a dark
/// page — so the one thing an artifact viewer most needs to do, it did worst.
///
/// The raw path therefore adds exactly one thing to the document: a
/// Content-Security-Policy `<meta>`. No stylesheet, no script, no DOM
/// rewriting.
///
/// ## Why no injected guard script
///
/// The shelled path relies on `shell.js`'s `interceptLinks` to stop a
/// `javascript:` link, and that function binds to `#agentia-doc`, which does not
/// exist here. Nothing replaces it, deliberately:
///
///  * A `javascript:` URL is not an escalation in this profile. The artifact
///    profile already permits `'unsafe-inline'` — the document's own `<script>`
///    runs by design, because a self-contained dashboard is useless otherwise —
///    so a link that runs script grants nothing the page did not already have.
///  * Navigation is contained host-side instead, by `HardenedWebView`'s
///    navigation delegate, which permits only `artifact://doc` and routes
///    `linkActivated` to the browser. That is *stronger* than a page-level
///    handler, because the page cannot remove it.
///  * As a side effect, external links in artifacts now work. Under the shelled
///    path they were dead: `interceptLinks` cancelled the click and posted to a
///    bridge that is deliberately absent for artifacts, so nothing happened.
///
/// Exfiltration containment is unchanged and does not depend on any of this:
/// `connect-src 'none'`, the compiled content rule list, and the absent
/// page-to-host bridge.
public enum RawArtifact {

    /// The artifact's own markup with a CSP `<meta>` inserted where it governs
    /// the whole document.
    public static func page(html: String, csp: String) -> String {
        var meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(csp))\">"
        meta += Self.printFidelityStyle
        if needsReadabilityFallback(html) {
            meta += Self.readabilityFallback
        }

        let bytes = Array(html.utf8)
        let offset = injectionOffset(in: bytes)

        var out = [UInt8]()
        out.reserveCapacity(bytes.count + meta.utf8.count + 1)
        out.append(contentsOf: bytes[..<offset])
        out.append(contentsOf: Array(meta.utf8))
        out.append(contentsOf: bytes[offset...])

        return String(decoding: out, as: UTF8.self)
    }

    /// The one piece of styling the raw path will add, and only to documents
    /// that carry none of their own.
    ///
    /// Under a dark system appearance an engine paints a dark canvas for
    /// undeclared HTML but leaves the text black, so a fragment as ordinary as
    /// `<div><h1>Build summary</h1>…</div>` renders black on black. The shell
    /// used to mask this by imposing paper and ink on everything; serving
    /// artifacts raw exposed it.
    ///
    /// `color-scheme` alone does not fix it — that was measured, in both the
    /// `<meta name="color-scheme">` form (which does not apply at all) and the
    /// CSS form (which applies, and still leaves the canvas dark). Only real
    /// colours do. It is declared first in the document and at the lowest
    /// possible specificity, so a single rule anywhere in the artifact beats
    /// it.
    static let readabilityFallback =
        "<style>:root{color-scheme:only light;background-color:#fff;color:#111}</style>"

    /// Makes an artifact print the way it looks.
    ///
    /// Artifacts get none of the shell's print CSS, and a browser drops
    /// backgrounds in print by default — so a dark dashboard would print its
    /// light text onto white paper and vanish. `print-color-adjust: exact`
    /// keeps its own background and colours, which is the "served as authored"
    /// answer for paper too. It is a print-only rule, so it changes nothing on
    /// screen.
    static let printFidelityStyle =
        "<style>@media print{html{-webkit-print-color-adjust:exact;print-color-adjust:exact}}</style>"

    /// Does this artifact style nothing at all, and so need a readable ground?
    ///
    /// Deliberately conservative: the fallback applies only to a document that
    /// mentions no colour scheme, no background and no colour anywhere. The
    /// asymmetry is the point. Applying it to a document that styles itself
    /// risks fighting the author — white behind a page whose light text is set
    /// somewhere this test cannot see. Declining to apply it costs only the
    /// unreadable case we started with, and only for documents that do style
    /// something, which are the ones least likely to need it.
    ///
    /// `prefers-color-scheme` contains `color-scheme`, so a media query counts
    /// as expressing intent and is caught by the same test.
    static func needsReadabilityFallback(_ html: String) -> Bool {
        for marker in ["color-scheme", "colorScheme", "background", "color:"]
        where html.range(of: marker, options: .caseInsensitive) != nil {
            return false
        }
        return true
    }

    /// A CSP is machine-generated here, but it lands in an attribute inside a
    /// document we do not control, so it is escaped like any other attribute
    /// rather than trusted for being ours.
    static func escapeAttribute(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&":  out += "&amp;"
            case "\"": out += "&quot;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            default:   out.append(character)
            }
        }
        return out
    }

    /// Byte offset at which the `<meta>` must be inserted.
    ///
    /// A CSP delivered by `<meta>` governs only what follows it in document
    /// order, so this has to land ahead of anything the document might execute.
    /// In preference order: just inside `<head>`, else just inside `<html>`,
    /// else after the doctype, else the very start.
    ///
    /// Placing it after the doctype rather than before matters: content ahead of
    /// the doctype puts the parser into quirks mode, which would silently change
    /// the artifact's layout — the exact harm this whole path exists to avoid.
    ///
    /// This does **not** search the document for `<head>`. It only accepts one
    /// that appears where a real `<head>` has to appear: at the very front,
    /// preceded by nothing but the doctype, `<html>`, comments and whitespace.
    /// The moment any other tag or text turns up, scanning stops and the offset
    /// falls back to just inside `<html>`, then after the doctype, then zero.
    ///
    /// The first version did search, skipping comments and `<script>` bodies as
    /// special cases. That is the wrong shape, and adversarial review took it
    /// apart: a literal `<head` is inert inside `<style>`, `<textarea>`,
    /// `<noscript>`, `<template>` (parsed into a detached fragment), `<svg>`
    /// (foreign content), and inside any quoted attribute such as
    /// `<iframe srcdoc="…">`. Each one put the meta somewhere the parser never
    /// treats as markup, so the artifact ran with **no policy at all** — while
    /// rendering perfectly, title and layout intact. A CSS comment reading
    /// `/* <head> */` was enough, and nothing about that looks like an attack.
    ///
    /// Enumerating the contexts where `<head` does not count is a list that is
    /// never finished — HTML keeps adding them. Requiring `<head>` to be first
    /// inverts it into a closed rule: everything unusual routes to a fallback
    /// that is always safe, because a `<meta>` in "before head" insertion mode
    /// is hoisted into the head the parser creates for it.
    static func injectionOffset(in bytes: [UInt8]) -> Int {
        var afterHTML: Int?
        var afterDoctype: Int?

        var i = 0
        while i < bytes.count {
            // Whitespace between the front-matter tags is ordinary formatting.
            if isASCIIWhitespace(bytes[i]) {
                i += 1
                continue
            }

            // Any text content means the parser has already left the head.
            guard bytes[i] == UInt8(ascii: "<") else { break }

            if matches(bytes, "<!--", at: i) {
                i = endOfComment(bytes, from: i)
                continue
            }

            if matches(bytes, "<head", at: i), isTagBoundary(bytes, at: i + 5) {
                return endOfTag(bytes, from: i)
            }

            if afterHTML == nil, matches(bytes, "<html", at: i),
               isTagBoundary(bytes, at: i + 5) {
                afterHTML = endOfTag(bytes, from: i)
                i = afterHTML!
                continue
            }

            if afterDoctype == nil, matches(bytes, "<!doctype", at: i) {
                afterDoctype = endOfTag(bytes, from: i)
                i = afterDoctype!
                continue
            }

            // Some other element opened before any <head> could. Stop.
            break
        }

        return afterHTML ?? afterDoctype ?? 0
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
            || byte == 0x0C
    }

    // MARK: - Scanning

    private static func asciiLower(_ c: UInt8) -> UInt8 {
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) ? c + 32 : c
    }

    private static func matches(_ bytes: [UInt8], _ needle: String, at index: Int) -> Bool {
        let pattern = Array(needle.utf8) // callers pass lowercase
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for k in 0..<pattern.count where asciiLower(bytes[index + k]) != pattern[k] {
            return false
        }
        return true
    }

    /// A tag name must end at a delimiter, so `<header>` is not `<head>`.
    ///
    /// Uses the same HTML5 boundary set as the structural pass, form feed
    /// included. The consequence here is milder — misreading `<head\u{0C}>` as
    /// "not a head" only sends the meta to the after-doctype fallback, which is
    /// safe, and the browser merges the document's own head into the one it
    /// synthesised. But the two scanners answering the same question
    /// differently is how a safe fallback quietly becomes an unsafe one.
    private static func isTagBoundary(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return true } // truncated: treat as end
        return StructuralTags.isTagNameBoundary(bytes[index])
    }

    /// Offset just past the `>` that closes the tag starting at `start`.
    ///
    /// Quotes are honoured so `<html data-x="a>b">` does not end early. An
    /// unterminated tag yields end-of-document, which puts the meta last — inert
    /// but harmless, and such a document has no executable content after it
    /// anyway.
    private static func endOfTag(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        var quote: UInt8?

        while i < bytes.count {
            let byte = bytes[i]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return i + 1
            }
            i += 1
        }
        return bytes.count
    }

    private static func endOfComment(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start + 4
        while i + 2 <= bytes.count {
            if bytes[i] == UInt8(ascii: "-"), i + 3 <= bytes.count,
               bytes[i + 1] == UInt8(ascii: "-"), bytes[i + 2] == UInt8(ascii: ">") {
                return i + 3
            }
            i += 1
        }
        return bytes.count
    }

}
