#include "agentia_markdown.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "cmark-gfm.h"
#include "cmark-gfm-core-extensions.h"
#include "cmark-gfm-extension_api.h"

/* The GFM extensions Agentia attaches to every parse.
 *
 * tagfilter is deliberately included even though AGENTIA_MD_UNSAFE_HTML lets
 * raw HTML through: it neutralises the GFM blocklist (script, iframe, style,
 * and friends) so a hostile artifact has to defeat both the tag filter and the
 * page's CSP, not just one of them. */
static const char *const kExtensions[] = {
    "table",
    "strikethrough",
    "autolink",
    "tagfilter",
    "tasklist",
};
static const size_t kExtensionCount =
    sizeof(kExtensions) / sizeof(kExtensions[0]);

static pthread_once_t g_register_once = PTHREAD_ONCE_INIT;

static void register_extensions_once(void) {
  cmark_gfm_core_extensions_ensure_registered();
}

/* ---------------------------------------------------------------------
 * Workaround: malformed footnote backref in swift-cmark's gfm branch.
 *
 * src/html.c:S_put_footnote_backref writes
 *
 *     ... aria-label="Back to reference 1↩</a>
 *
 * and never closes the attribute. Upstream github/cmark-gfm emits
 * "\">↩</a>" correctly; Apple's fork dropped the "\">" on the single-backref
 * path only (the multi-backref path 20 lines below is right). An unterminated
 * attribute value swallows everything up to the next quote character, so a
 * single footnote corrupts the remainder of the document — in Agentia's case
 * it consumed the closing tags and the shell <script> along with them.
 *
 * The repair is a targeted byte fixup: find the exact prefix, skip the index
 * (digits and hyphens), and if what follows is the U+21A9 arrow rather than
 * the quote that should be there, insert the missing "\">".
 *
 * This is a no-op once the dependency is fixed, because the pattern stops
 * matching — so it is safe to leave in place.
 * ------------------------------------------------------------------- */

/* Anchored on the attribute cmark emits immediately before the broken one, so
   the repair cannot fire on raw HTML the author happened to write. A document
   containing
       <span aria-label="Back to reference 1↩ and more">
   used to have "> injected into it, closing the tag early. */
static const char kBackrefAnchor[] = "data-footnote-backref-idx=\"";
#define BACKREF_ANCHOR_LEN (sizeof(kBackrefAnchor) - 1)

static const char kBackrefPrefix[] = "\" aria-label=\"Back to reference ";
#define BACKREF_PREFIX_LEN (sizeof(kBackrefPrefix) - 1)

/* UTF-8 for U+21A9 LEFTWARDS ARROW WITH HOOK. */
static const char kReturnArrow[] = "\xe2\x86\xa9";
#define RETURN_ARROW_LEN (sizeof(kReturnArrow) - 1)

/* Counts how many repairs the input needs, so we can skip allocation in the
   overwhelmingly common case of a document with no footnotes. */
/* Returns the offset just past a broken backref's index digits, or 0 if the
   run starting at `at` is not one. */
static size_t match_broken_backref(const char *html, size_t len, size_t at) {
  if (at + BACKREF_ANCHOR_LEN > len) return 0;
  if (memcmp(html + at, kBackrefAnchor, BACKREF_ANCHOR_LEN) != 0) return 0;

  size_t j = at + BACKREF_ANCHOR_LEN;
  while (j < len && ((html[j] >= '0' && html[j] <= '9') || html[j] == '-')) j++;

  if (j + BACKREF_PREFIX_LEN > len) return 0;
  if (memcmp(html + j, kBackrefPrefix, BACKREF_PREFIX_LEN) != 0) return 0;

  j += BACKREF_PREFIX_LEN;
  while (j < len && ((html[j] >= '0' && html[j] <= '9') || html[j] == '-')) j++;

  if (j + RETURN_ARROW_LEN > len) return 0;
  if (memcmp(html + j, kReturnArrow, RETURN_ARROW_LEN) != 0) return 0;

  return j;
}

static size_t count_broken_backrefs(const char *html, size_t len) {
  size_t found = 0;
  size_t i = 0;

  while (i < len) {
    const char *hit = memchr(html + i, 'd', len - i);
    if (hit == NULL) break;
    size_t at = (size_t)(hit - html);

    size_t end = match_broken_backref(html, len, at);
    if (end != 0) {
      found++;
      i = end;
      continue;
    }
    i = at + 1;
  }
  return found;
}

static char *repair_footnote_backrefs(char *html) {
  if (html == NULL) return NULL;

  const size_t len = strlen(html);
  const size_t broken = count_broken_backrefs(html, len);
  if (broken == 0) {
    return html;
  }

  /* Each repair inserts exactly two bytes: '"' and '>'. */
  const size_t out_len = len + broken * 2;
  char *out = (char *)malloc(out_len + 1);
  if (out == NULL) {
    /* Better to return the original than to lose the document entirely; the
       page will be damaged but the caller still gets something. */
    return html;
  }

  size_t r = 0; /* read cursor  */
  size_t w = 0; /* write cursor */

  while (r < len) {
    size_t end = (html[r] == 'd') ? match_broken_backref(html, len, r) : 0;
    if (end != 0) {
      memcpy(out + w, html + r, end - r);
      w += end - r;
      r = end;
      out[w++] = '"';
      out[w++] = '>';
      continue;
    }
    out[w++] = html[r++];
  }

  out[w] = '\0';
  free(html);
  return out;
}

/* ---------------------------------------------------------------------
 * Structural tag neutralisation.
 *
 * These tags are meaningless inside a fragment and dangerous when the fragment
 * is embedded in a host page. Escaping the leading '<' turns them into visible
 * text, which is also the honest thing to show a reviewer: the document really
 * did contain a "</main>".
 * ------------------------------------------------------------------- */

static const char *const kStructuralTags[] = {
    "main", "/main", "meta", "base", "html", "/html",
    "head", "/head", "body", "/body", "frameset", "frame",
};
static const size_t kStructuralTagCount =
    sizeof(kStructuralTags) / sizeof(kStructuralTags[0]);

static int ascii_lower(int c) {
  return (c >= 'A' && c <= 'Z') ? c + 32 : c;
}

/* Does a structural tag start at html[at] (which must be '<')? Returns its
   name length, or 0. A tag name must be followed by a delimiter, so "<mainly"
   is left alone. */
static size_t structural_tag_at(const char *html, size_t len, size_t at) {
  for (size_t t = 0; t < kStructuralTagCount; t++) {
    const char *name = kStructuralTags[t];
    size_t name_len = strlen(name);
    if (at + 1 + name_len > len) continue;

    size_t k = 0;
    for (; k < name_len; k++) {
      if (ascii_lower((unsigned char)html[at + 1 + k]) != name[k]) break;
    }
    if (k != name_len) continue;

    size_t after = at + 1 + name_len;
    if (after >= len) return name_len;
    char next = html[after];
    if (next == '>' || next == '/' || next == ' ' || next == '\t' ||
        next == '\n' || next == '\r') {
      return name_len;
    }
  }
  return 0;
}

static char *neutralise_structural_tags(char *html) {
  if (html == NULL) return html;

  const size_t len = strlen(html);
  size_t hits = 0;
  for (size_t i = 0; i < len; i++) {
    if (html[i] == '<' && structural_tag_at(html, len, i) != 0) hits++;
  }
  if (hits == 0) return html;

  /* "<" becomes "&lt;": three extra bytes each. */
  char *out = (char *)malloc(len + hits * 3 + 1);
  if (out == NULL) return html;

  size_t w = 0;
  for (size_t i = 0; i < len; i++) {
    if (html[i] == '<' && structural_tag_at(html, len, i) != 0) {
      memcpy(out + w, "&lt;", 4);
      w += 4;
      continue;
    }
    out[w++] = html[i];
  }
  out[w] = '\0';
  free(html);
  return out;
}

/* Deepest block nesting in the document.
 *
 * Guards the layout engine, not the parser: cmark parses 200k nested
 * blockquotes in about a third of a second, but laying them out is quadratic
 * in depth and never finishes. */
static int max_block_depth(cmark_node *root) {
  cmark_iter *iter = cmark_iter_new(root);
  if (iter == NULL) return 0;

  int deepest = 0;
  cmark_event_type event;

  while ((event = cmark_iter_next(iter)) != CMARK_EVENT_DONE) {
    if (event != CMARK_EVENT_ENTER) continue;

    /* Depth comes from the parent chain rather than from counting ENTER and
       EXIT events: cmark emits EXIT only for container nodes, so a running
       counter increments on every text node and never comes back down —
       which reports any large document as pathologically deep.

       Cost is bounded because the walk stops one step past the limit, and the
       loop breaks as soon as the answer is decided. */
    int depth = 0;
    for (cmark_node *node = cmark_iter_get_node(iter);
         node != NULL && depth <= AGENTIA_MD_MAX_DEPTH + 1;
         node = cmark_node_parent(node)) {
      depth++;
    }

    if (depth > deepest) deepest = depth;
    if (deepest > AGENTIA_MD_MAX_DEPTH) break;
  }

  cmark_iter_free(iter);
  return deepest;
}

/* Length of the front-matter block at the start of `text`, or 0.
 
   Recognises "---" (YAML) and "+++" (TOML) fences. The opening fence must be
   the very first line; the closing fence is "---", "..." or "+++" alone on a
   line. An unterminated block is not front matter. */
static size_t front_matter_length(const char *text, size_t len) {
  if (len < 4) return 0;

  char fence;
  if (text[0] == '-' && text[1] == '-' && text[2] == '-') {
    fence = '-';
  } else if (text[0] == '+' && text[1] == '+' && text[2] == '+') {
    fence = '+';
  } else {
    return 0;
  }

  size_t i = 3;
  if (i < len && text[i] == '\r') i++;
  if (i >= len || text[i] != '\n') return 0;
  i++;

  while (i < len) {
    size_t line_start = i;
    while (i < len && text[i] != '\n') i++;

    size_t line_end = i;
    if (line_end > line_start && text[line_end - 1] == '\r') line_end--;

    size_t width = line_end - line_start;
    if (width == 3) {
      char c = text[line_start];
      int closes = (c == fence && text[line_start + 1] == c &&
                    text[line_start + 2] == c) ||
                   (fence == '-' && c == '.' && text[line_start + 1] == '.' &&
                    text[line_start + 2] == '.');
      if (closes) {
        return (i < len) ? i + 1 : len; /* include the trailing newline */
      }
    }
    if (i < len) i++; /* step past the newline */
  }

  return 0; /* never closed: treat as ordinary content */
}

/* Overwrite the front-matter region with spaces, preserving byte count and
   line count so source positions stay aligned with the original file. */
static void blank_front_matter(char *text, size_t len) {
  size_t block = front_matter_length(text, len);
  for (size_t i = 0; i < block; i++) {
    if (text[i] != '\n' && text[i] != '\r') text[i] = ' ';
  }
}

static int cmark_options_from_flags(uint32_t flags) {
  /* CMARK_OPT_VALIDATE_UTF8 is unconditional: the input is a file that some
     other process wrote, so invalid sequences are a realistic case and cmark
     replaces them rather than emitting broken UTF-8 into the web view. */
  int options = CMARK_OPT_VALIDATE_UTF8;

  if (flags & AGENTIA_MD_SOURCEPOS) {
    options |= CMARK_OPT_SOURCEPOS;
  }
  if (flags & AGENTIA_MD_UNSAFE_HTML) {
    options |= CMARK_OPT_UNSAFE;
  }
  if (flags & AGENTIA_MD_HARDBREAKS) {
    options |= CMARK_OPT_HARDBREAKS;
  }
  if (flags & AGENTIA_MD_FOOTNOTES) {
    options |= CMARK_OPT_FOOTNOTES;
  }
  if (flags & AGENTIA_MD_SMART) {
    options |= CMARK_OPT_SMART;
  }
  return options;
}

char *agentia_md_to_html(const char *markdown, size_t length, uint32_t flags) {
  if (length > AGENTIA_MD_MAX_INPUT) {
    return NULL;
  }
  if (markdown == NULL && length > 0) {
    return NULL;
  }

  if (length == 0) {
    char *empty = (char *)malloc(1);
    if (empty != NULL) {
      empty[0] = '\0';
    }
    return empty;
  }

  pthread_once(&g_register_once, register_extensions_once);

  /* Front matter is blanked on a private copy: the caller's buffer is const
     and may be a memory-mapped file. */
  char *owned = NULL;
  if (flags & AGENTIA_MD_STRIP_FRONT_MATTER) {
    if (front_matter_length(markdown, length) > 0) {
      owned = (char *)malloc(length);
      if (owned == NULL) return NULL;
      memcpy(owned, markdown, length);
      blank_front_matter(owned, length);
      markdown = owned;
    }
  }

  const int options = cmark_options_from_flags(flags);

  cmark_parser *parser = cmark_parser_new(options);
  if (parser == NULL) {
    free(owned);
    return NULL;
  }

  for (size_t i = 0; i < kExtensionCount; i++) {
    cmark_syntax_extension *ext = cmark_find_syntax_extension(kExtensions[i]);
    /* A missing extension is not fatal — the document still renders, just
       without that feature. Failing the whole parse would be worse. */
    if (ext != NULL) {
      cmark_parser_attach_syntax_extension(parser, ext);
    }
  }

  cmark_parser_feed(parser, markdown, length);

  cmark_node *doc = cmark_parser_finish(parser);
  free(owned);
  owned = NULL;

  if (doc == NULL) {
    cmark_parser_free(parser);
    return NULL;
  }

  if (max_block_depth(doc) > AGENTIA_MD_MAX_DEPTH) {
    cmark_node_free(doc);
    cmark_parser_free(parser);
    return NULL;
  }

  /* The extension list belongs to the parser, so the render has to happen
     before the parser is freed. */
  char *html = cmark_render_html(doc, options,
                                 cmark_parser_get_syntax_extensions(parser));

  cmark_node_free(doc);
  cmark_parser_free(parser);

  if (html == NULL) return NULL;

  if (strlen(html) > AGENTIA_MD_MAX_OUTPUT) {
    free(html);
    return NULL;
  }

  html = repair_footnote_backrefs(html);

  if (flags & AGENTIA_MD_NEUTRALISE_STRUCTURAL) {
    html = neutralise_structural_tags(html);
  }
  return html;
}

void agentia_md_free(char *html) {
  /* cmark's default allocator is malloc/free, and Agentia never installs a
     custom cmark_mem, so plain free is correct here. */
  free(html);
}

const char *agentia_md_cmark_version(void) {
  const char *version = cmark_version_string();
  return version != NULL ? version : "unknown";
}
