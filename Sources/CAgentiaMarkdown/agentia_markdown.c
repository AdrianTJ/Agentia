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
