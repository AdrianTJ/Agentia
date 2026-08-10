/*
 * agentia_render_cli — Markdown on stdin (or a file argument), HTML on stdout.
 *
 * Exists so the browser test suite drives the same C code the app links
 * against, rather than a JavaScript reimplementation that could drift.
 *
 *   agentia_render_cli [--no-sourcepos] [--safe] [file.md]
 */

#include "agentia_markdown.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_all(FILE *in, size_t *out_len) {
  size_t cap = 1 << 16;
  size_t len = 0;
  char *buf = (char *)malloc(cap);
  if (!buf) return NULL;

  for (;;) {
    if (len == cap) {
      size_t next = cap * 2;
      char *grown = (char *)realloc(buf, next);
      if (!grown) {
        free(buf);
        return NULL;
      }
      buf = grown;
      cap = next;
    }
    size_t n = fread(buf + len, 1, cap - len, in);
    len += n;
    if (n == 0) break;
  }

  *out_len = len;
  return buf;
}

int main(int argc, char **argv) {
  uint32_t flags = AGENTIA_MD_DEFAULT_FLAGS;
  const char *path = NULL;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--no-sourcepos") == 0) {
      flags &= ~(uint32_t)AGENTIA_MD_SOURCEPOS;
    } else if (strcmp(argv[i], "--safe") == 0) {
      flags &= ~(uint32_t)AGENTIA_MD_UNSAFE_HTML;
    } else if (strcmp(argv[i], "--smart") == 0) {
      flags |= AGENTIA_MD_SMART;
    } else if (strcmp(argv[i], "--version") == 0) {
      printf("%s\n", agentia_md_cmark_version());
      return 0;
    } else {
      path = argv[i];
    }
  }

  FILE *in = stdin;
  if (path) {
    in = fopen(path, "rb");
    if (!in) {
      fprintf(stderr, "agentia_render_cli: cannot open %s\n", path);
      return 2;
    }
  }

  size_t len = 0;
  char *source = read_all(in, &len);
  if (path) fclose(in);

  if (!source) {
    fprintf(stderr, "agentia_render_cli: read failed\n");
    return 2;
  }

  char *html = agentia_md_to_html(source, len, flags);
  free(source);

  if (!html) {
    fprintf(stderr, "agentia_render_cli: render failed\n");
    return 1;
  }

  fputs(html, stdout);
  agentia_md_free(html);
  return 0;
}
