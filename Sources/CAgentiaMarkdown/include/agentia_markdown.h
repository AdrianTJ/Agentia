/*
 * agentia_markdown.h — thin C shim over cmark-gfm.
 *
 * Everything Agentia needs from the parser lives behind three functions, so the
 * Swift side never touches cmark's ownership rules directly. The shim owns the
 * parser lifecycle, extension registration, and the allocator contract.
 *
 * Threading: agentia_md_to_html is safe to call from any thread. Extension
 * registration happens once, behind pthread_once.
 */

#ifndef AGENTIA_MARKDOWN_H
#define AGENTIA_MARKDOWN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Emit data-sourcepos="startline:startcol-endline:endcol" on block elements.
   Agentia uses the start line to map rendered blocks back to source lines for
   the diff view, so this is on for every render. */
#define AGENTIA_MD_SOURCEPOS (1u << 0)

/* Let raw HTML in the Markdown reach the output instead of being replaced by a
   comment. Agent-written Markdown routinely contains <details>, <img> and
   inline tables, so the viewer wants this on — script execution is stopped by
   the Content-Security-Policy in the render shell, not by the parser, and the
   tagfilter extension still neutralises the GFM blocklist. */
#define AGENTIA_MD_UNSAFE_HTML (1u << 1)

/* Treat a newline inside a paragraph as a hard line break. */
#define AGENTIA_MD_HARDBREAKS (1u << 2)

/* GFM footnotes: [^1] references and definitions. */
#define AGENTIA_MD_FOOTNOTES (1u << 3)

/* Curly quotes, em dashes, ellipses. Off by default: it rewrites characters
   inside the document, which is wrong for a review tool where the reader may be
   checking exact output. */
#define AGENTIA_MD_SMART (1u << 4)

/* Escape structural tags that a *fragment* must never contain: html, head,
   body, main, meta and base.
 
   Raw HTML is allowed through (see AGENTIA_MD_UNSAFE_HTML) and tagfilter only
   covers the GFM blocklist, so without this a document containing a bare
   "</main>" closes the container it was embedded in and everything after it
   becomes a sibling of <body> — enough to paint a full-window overlay with no
   script at all. A "<meta http-equiv=refresh>" is worse: CSP does not govern
   top-level navigation, so it navigates the view to an arbitrary URL. */
#define AGENTIA_MD_NEUTRALISE_STRUCTURAL (1u << 5)

/* Blank out YAML or TOML front matter before parsing.
 
   Agent-written Markdown very often opens with a "---" metadata block.
   CommonMark reads that as a thematic break followed by a setext heading, so
   the reader gets a horizontal rule and then the raw metadata set as a large
   bold heading above the real title — and it lands in the outline as the first
   entry.
 
   The region is overwritten with spaces rather than removed, which keeps both
   the byte offsets and the line numbering intact. That matters: source
   positions drive the diff view, and shifting them would misalign every
   highlighted block in the document. */
#define AGENTIA_MD_STRIP_FRONT_MATTER (1u << 6)

/* What Agentia renders with. */
#define AGENTIA_MD_DEFAULT_FLAGS                                     \
  (AGENTIA_MD_SOURCEPOS | AGENTIA_MD_UNSAFE_HTML | AGENTIA_MD_FOOTNOTES | \
   AGENTIA_MD_NEUTRALISE_STRUCTURAL | AGENTIA_MD_STRIP_FRONT_MATTER)

/*
 * Render CommonMark + GFM to an HTML fragment.
 *
 * markdown  UTF-8 bytes. Need not be NUL-terminated; `length` governs.
 *           May be NULL only when length is 0.
 * length    byte count.
 * flags     bitwise OR of AGENTIA_MD_*.
 *
 * Returns a malloc'd NUL-terminated HTML fragment (no <html> wrapper), or NULL
 * if allocation failed or the input exceeded AGENTIA_MD_MAX_INPUT. Free the
 * result with agentia_md_free.
 *
 * An empty input yields an empty string, not NULL.
 */
char *agentia_md_to_html(const char *markdown, size_t length, uint32_t flags);

/* Release a buffer returned by agentia_md_to_html. NULL is a no-op. */
void agentia_md_free(char *html);

/* Upper bound on input size, in bytes (16 MiB). cmark-gfm has a history of
   quadratic blow-up on crafted input; a hard ceiling plus the caller's own
   watchdog keeps a hostile artifact from wedging the app. */
#define AGENTIA_MD_MAX_INPUT ((size_t)16 * 1024 * 1024)

/* Ceiling on generated HTML (32 MiB).
   Markdown expands: a document of nothing but ">" becomes deeply nested
   blockquotes and, with source positions on every one, grows about 63x. An
   input limit alone therefore does not bound the work handed to the layout
   engine. */
#define AGENTIA_MD_MAX_OUTPUT ((size_t)32 * 1024 * 1024)

/* Ceiling on block nesting depth.
   The real hazard is not parse time — cmark handles 200k nested blockquotes in
   about a third of a second — but layout, which is quadratic in depth: 100k
   levels took ~29 s in a browser engine and 200k never finished. No genuine
   document nests past a few dozen levels. */
#define AGENTIA_MD_MAX_DEPTH 96

/* cmark-gfm version string, e.g. "0.29.0.gfm.13". Never NULL. */
const char *agentia_md_cmark_version(void);

#ifdef __cplusplus
}
#endif

#endif /* AGENTIA_MARKDOWN_H */
