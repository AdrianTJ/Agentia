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

static const char kBackrefPrefix[] = "aria-label=\"Back to reference ";
#define BACKREF_PREFIX_LEN (sizeof(kBackrefPrefix) - 1)

/* UTF-8 for U+21A9 LEFTWARDS ARROW WITH HOOK. */
static const char kReturnArrow[] = "\xe2\x86\xa9";
#define RETURN_ARROW_LEN (sizeof(kReturnArrow) - 1)

/* Counts how many repairs the input needs, so we can skip allocation in the
   overwhelmingly common case of a document with no footnotes. */
static size_t count_broken_backrefs(const char *html, size_t len) {
  size_t found = 0;
  size_t i = 0;

  while (i + BACKREF_PREFIX_LEN < len) {
    const char *hit = memchr(html + i, 'a', len - i);
    if (hit == NULL) break;
    size_t at = (size_t)(hit - html);

    if (at + BACKREF_PREFIX_LEN <= len &&
        memcmp(html + at, kBackrefPrefix, BACKREF_PREFIX_LEN) == 0) {
      size_t j = at + BACKREF_PREFIX_LEN;
      while (j < len && ((html[j] >= '0' && html[j] <= '9') || html[j] == '-')) {
        j++;
      }
      if (j + RETURN_ARROW_LEN <= len &&
          memcmp(html + j, kReturnArrow, RETURN_ARROW_LEN) == 0) {
        found++;
      }
      i = j;
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
    if (html[r] == 'a' && r + BACKREF_PREFIX_LEN <= len &&
        memcmp(html + r, kBackrefPrefix, BACKREF_PREFIX_LEN) == 0) {
      memcpy(out + w, html + r, BACKREF_PREFIX_LEN);
      w += BACKREF_PREFIX_LEN;
      r += BACKREF_PREFIX_LEN;

      while (r < len && ((html[r] >= '0' && html[r] <= '9') || html[r] == '-')) {
        out[w++] = html[r++];
      }

      if (r + RETURN_ARROW_LEN <= len &&
          memcmp(html + r, kReturnArrow, RETURN_ARROW_LEN) == 0) {
        out[w++] = '"';
        out[w++] = '>';
      }
      continue;
    }
    out[w++] = html[r++];
  }

  out[w] = '\0';
  free(html);
  return out;
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

  const int options = cmark_options_from_flags(flags);

  cmark_parser *parser = cmark_parser_new(options);
  if (parser == NULL) {
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
  if (doc == NULL) {
    cmark_parser_free(parser);
    return NULL;
  }

  /* The extension list belongs to the parser, so the render has to happen
     before the parser is freed. */
  char *html = cmark_render_html(doc, options,
                                 cmark_parser_get_syntax_extensions(parser));

  cmark_node_free(doc);
  cmark_parser_free(parser);

  return repair_footnote_backrefs(html);
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
