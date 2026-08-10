/*
 * test_markdown.c — exercises the agentia_markdown shim against real cmark-gfm.
 *
 * Build and run with tools/build-ctest.sh. These run on Linux, so they cover
 * the parsing core on any machine, not just a Mac.
 */

#include "agentia_markdown.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int g_failures = 0;
static int g_checks = 0;

static void check(int condition, const char *what) {
  g_checks++;
  if (!condition) {
    g_failures++;
    printf("  FAIL  %s\n", what);
  }
}

static void check_contains(const char *haystack, const char *needle,
                           const char *what) {
  g_checks++;
  if (haystack == NULL || strstr(haystack, needle) == NULL) {
    g_failures++;
    printf("  FAIL  %s\n        expected to find: %s\n        in: %.300s\n",
           what, needle, haystack ? haystack : "(null)");
  }
}

static void check_absent(const char *haystack, const char *needle,
                         const char *what) {
  g_checks++;
  if (haystack != NULL && strstr(haystack, needle) != NULL) {
    g_failures++;
    printf("  FAIL  %s\n        did NOT expect: %s\n        in: %.300s\n", what,
           needle, haystack);
  }
}

static char *render(const char *md, uint32_t flags) {
  return agentia_md_to_html(md, strlen(md), flags);
}

static char *render_default(const char *md) {
  return render(md, AGENTIA_MD_DEFAULT_FLAGS);
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

/* ------------------------------------------------------------------ */

static void test_basics(void) {
  printf("basics\n");

  char *h = render_default("# Title\n\nSome *emphasis* and **strong**.\n");
  check_contains(h, "<h1", "heading renders");
  check_contains(h, "Title</h1>", "heading text");
  check_contains(h, "<em>emphasis</em>", "emphasis");
  check_contains(h, "<strong>strong</strong>", "strong");
  agentia_md_free(h);

  h = render_default("Text with `inline code` here.\n");
  check_contains(h, "<code>inline code</code>", "inline code");
  agentia_md_free(h);

  h = render_default("```swift\nlet x = 1\n```\n");
  check_contains(h, "<pre", "fenced block produces pre");
  check_contains(h, "language-swift", "info string becomes language class");
  check_contains(h, "let x = 1", "code content preserved");
  agentia_md_free(h);

  h = render_default("- one\n- two\n\n1. first\n2. second\n");
  check_contains(h, "<ul", "bullet list");
  check_contains(h, "<ol", "ordered list");
  agentia_md_free(h);

  h = render_default("> quoted\n");
  check_contains(h, "<blockquote", "blockquote");
  agentia_md_free(h);

  h = render_default("[link](https://example.com)\n");
  check_contains(h, "href=\"https://example.com\"", "link href");
  agentia_md_free(h);
}

static void test_gfm_extensions(void) {
  printf("gfm extensions\n");

  char *h = render_default(
      "| Metric | Value |\n| ------ | ----: |\n| Recall | 0.849 |\n");
  check_contains(h, "<table", "table extension active");
  check_contains(h, "<th", "table header cell");
  check_contains(h, "0.849", "table body content");
  check_contains(h, "align=\"right\"", "column alignment honoured");
  agentia_md_free(h);

  h = render_default("~~struck~~\n");
  check_contains(h, "<del>struck</del>", "strikethrough extension");
  agentia_md_free(h);

  h = render_default("Visit https://example.com today.\n");
  check_contains(h, "<a href=\"https://example.com\"", "autolink extension");
  agentia_md_free(h);

  h = render_default("- [ ] todo\n- [x] done\n");
  check_contains(h, "type=\"checkbox\"", "tasklist extension");
  check_contains(h, "disabled", "task checkboxes are disabled");
  check_contains(h, "checked", "completed task is checked");
  agentia_md_free(h);

  h = render_default("A note[^1]\n\n[^1]: The footnote text.\n");
  check_contains(h, "footnote", "footnotes enabled");
  check_contains(h, "The footnote text", "footnote body rendered");
  agentia_md_free(h);
}

/* swift-cmark's gfm branch emits an unterminated aria-label on the footnote
   backref, which swallows the rest of the document. The shim repairs it; these
   tests pin both the repair and the paths it must not touch. */
static void test_footnote_backref_repair(void) {
  printf("footnote backref repair\n");

  char *h = render_default("A note[^1]\n\n[^1]: Body text.\n");
  check_absent(h, "reference 1\xe2\x86\xa9", "unterminated aria-label is repaired");
  check_contains(h, "aria-label=\"Back to reference 1\">\xe2\x86\xa9",
                 "backref closes its attribute and tag");
  check_contains(h, "Body text", "footnote body still present");
  agentia_md_free(h);

  /* Named footnotes go down the same path. */
  h = render_default("See[^method]\n\n[^method]: How it works.\n");
  check_contains(h, "aria-label=\"Back to reference 1\">", "named footnote repaired");
  check_absent(h, "reference 1\xe2\x86\xa9", "no unterminated attribute remains");
  agentia_md_free(h);

  /* Two separate footnotes: two repairs in one document. */
  h = render_default("A[^a] and B[^b]\n\n[^a]: First.\n\n[^b]: Second.\n");
  check_contains(h, "aria-label=\"Back to reference 1\">", "first of two repaired");
  check_contains(h, "aria-label=\"Back to reference 2\">", "second of two repaired");
  check_absent(h, "reference 1\xe2\x86\xa9", "first has no dangling attribute");
  check_absent(h, "reference 2\xe2\x86\xa9", "second has no dangling attribute");
  agentia_md_free(h);

  /* A footnote referenced twice takes the multi-backref path, which upstream
     already writes correctly. The repair must leave it alone. */
  h = render_default("A[^x] then again[^x]\n\n[^x]: Shared.\n");
  check_absent(h, "\">\">", "correct multi-backref markup is not double-patched");
  agentia_md_free(h);

  /* The literal arrow in ordinary prose must survive untouched. */
  h = render_default("Press the return arrow \xe2\x86\xa9 to continue.\n");
  check_contains(h, "\xe2\x86\xa9", "arrow in body text is preserved");
  check_absent(h, "\">\xe2\x86\xa9", "no spurious quote inserted in prose");
  agentia_md_free(h);

  /* Text that merely resembles the pattern must not be rewritten. */
  h = render_default("Back to reference 1 is a phrase, not markup.\n");
  check_contains(h, "Back to reference 1 is a phrase",
                 "prose resembling the pattern is untouched");
  agentia_md_free(h);

  /* A document with no footnotes must take the zero-copy path unharmed. */
  h = render_default("# Plain\n\nNothing to repair.\n");
  check_contains(h, "Nothing to repair", "documents without footnotes are unchanged");
  agentia_md_free(h);
}

/* The real failure mode was structural: malformed markup ended the document
   early. Assert well-formedness directly rather than only pattern-matching. */
static void test_output_is_well_formed(void) {
  printf("output well-formedness\n");

  const char *docs[] = {
      "A note[^1]\n\n[^1]: Body.\n",
      "# H\n\nText[^a]\n\n## H2\n\nMore\n\n[^a]: Note.\n",
      "| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter[^n]\n\n[^n]: End.\n",
  };

  for (size_t i = 0; i < sizeof(docs) / sizeof(docs[0]); i++) {
    char *h = render_default(docs[i]);
    if (h == NULL) {
      check(0, "render succeeded");
      continue;
    }

    /* Every double quote inside a tag must be balanced: walk the output and
       confirm we never reach EOF while inside an attribute value. */
    int in_tag = 0, in_quote = 0;
    for (const char *p = h; *p; p++) {
      if (!in_tag && *p == '<') in_tag = 1;
      else if (in_tag && *p == '"') in_quote = !in_quote;
      else if (in_tag && *p == '>' && !in_quote) in_tag = 0;
    }
    check(!in_quote, "output never ends inside an attribute value");
    check(!in_tag, "output never ends inside a tag");

    agentia_md_free(h);
  }
}

static void test_sourcepos(void) {
  printf("sourcepos\n");

  char *h = render_default("# One\n\nParagraph two.\n\n## Three\n");
  check_contains(h, "data-sourcepos=", "sourcepos attribute emitted");
  check_contains(h, "data-sourcepos=\"1:1-1:5\"", "heading maps to line 1");
  check_contains(h, "data-sourcepos=\"3:1-3:14\"", "paragraph maps to line 3");
  check_contains(h, "data-sourcepos=\"5:1-5:8\"", "second heading maps to line 5");
  agentia_md_free(h);

  /* Without the flag there should be no positions at all. */
  h = render("# One\n", AGENTIA_MD_UNSAFE_HTML);
  check_absent(h, "data-sourcepos", "sourcepos suppressed when flag is off");
  agentia_md_free(h);
}

static void test_raw_html_and_tagfilter(void) {
  printf("raw html + tagfilter (security)\n");

  /* Benign raw HTML should survive: agent Markdown uses it constantly. */
  char *h = render_default("<details><summary>More</summary>\n\nBody\n\n</details>\n");
  check_contains(h, "<details", "benign raw HTML passes through");
  check_contains(h, "<summary>", "summary tag survives");
  agentia_md_free(h);

  /* The GFM blocklist must be neutralised even with raw HTML enabled. */
  h = render_default("<script>alert(1)</script>\n");
  check_absent(h, "<script>", "script tag is filtered, not emitted raw");
  check_contains(h, "&lt;script", "script tag is escaped by tagfilter");
  agentia_md_free(h);

  h = render_default("<iframe src=\"https://evil.test\"></iframe>\n");
  check_absent(h, "<iframe", "iframe is filtered");
  agentia_md_free(h);

  /* tagfilter does NOT cover attribute-based handlers — this is exactly why
     the render shell also ships a CSP. Assert the real behaviour so nobody
     later assumes the parser alone is a sanitiser. */
  h = render_default("<img src=x onerror=\"alert(1)\">\n");
  check_contains(h, "onerror", "onerror survives the parser (CSP must catch it)");
  agentia_md_free(h);

  /* With raw HTML disabled, cmark strips it entirely. */
  h = render("<div>hi</div>\n", AGENTIA_MD_SOURCEPOS);
  check_absent(h, "<div", "raw HTML removed when UNSAFE is off");
  agentia_md_free(h);
}

static void test_edge_cases(void) {
  printf("edge cases\n");

  char *h = agentia_md_to_html("", 0, AGENTIA_MD_DEFAULT_FLAGS);
  check(h != NULL, "empty input returns a buffer, not NULL");
  if (h) {
    check(strlen(h) == 0, "empty input renders empty string");
    agentia_md_free(h);
  }

  h = agentia_md_to_html(NULL, 0, AGENTIA_MD_DEFAULT_FLAGS);
  check(h != NULL, "NULL with zero length is treated as empty");
  agentia_md_free(h);

  h = agentia_md_to_html(NULL, 10, AGENTIA_MD_DEFAULT_FLAGS);
  check(h == NULL, "NULL with nonzero length is rejected");

  /* Length must govern, not a NUL terminator. */
  const char *truncated = "# Visible\n# Hidden\n";
  h = agentia_md_to_html(truncated, 10, AGENTIA_MD_DEFAULT_FLAGS);
  check_contains(h, "Visible", "length-bounded read includes prefix");
  check_absent(h, "Hidden", "length-bounded read excludes suffix");
  agentia_md_free(h);

  /* Invalid UTF-8 must not propagate into the web view. */
  const char bad[] = {'a', (char)0xFF, (char)0xFE, 'b', '\n'};
  h = agentia_md_to_html(bad, sizeof(bad), AGENTIA_MD_DEFAULT_FLAGS);
  check(h != NULL, "invalid UTF-8 does not crash the parser");
  if (h) {
    check_absent(h, "\xFF", "invalid byte replaced, not passed through");
    agentia_md_free(h);
  }

  agentia_md_free(NULL); /* must be a no-op */
  check(1, "free(NULL) is safe");

  h = render_default("no trailing newline");
  check_contains(h, "no trailing newline", "input without trailing newline");
  agentia_md_free(h);
}

static void test_throughput(void) {
  printf("throughput\n");

  /* Build a realistic ~1 MB document: prose, headings, code, tables. */
  const char *unit =
      "## Section heading\n\n"
      "This run swapped the reranker and widened the candidate pool from 20 to\n"
      "50 documents. Recall improved materially; latency did not degrade as\n"
      "much as the pilot suggested. See `harness.py` for the exact sweep.\n\n"
      "| Metric | Run 40 | Run 41 |\n| --- | ---: | ---: |\n"
      "| Recall@10 | 0.712 | 0.849 |\n| p99 | 602 ms | 871 ms |\n\n"
      "```python\ndef score(q, docs):\n    return rerank(q, docs)[:10]\n```\n\n"
      "- Table fragmentation accounts for most remaining misses.\n"
      "- Acronym collisions need a domain glossary.\n\n";

  const size_t unit_len = strlen(unit);
  const size_t target = 1024 * 1024;
  const size_t reps = target / unit_len + 1;
  const size_t total = unit_len * reps;

  char *big = (char *)malloc(total + 1);
  if (big == NULL) {
    printf("  SKIP  could not allocate corpus\n");
    return;
  }
  for (size_t i = 0; i < reps; i++) {
    memcpy(big + i * unit_len, unit, unit_len);
  }
  big[total] = '\0';

  double best = 1e18;
  for (int run = 0; run < 3; run++) {
    double t0 = now_ms();
    char *h = agentia_md_to_html(big, total, AGENTIA_MD_DEFAULT_FLAGS);
    double dt = now_ms() - t0;
    check(h != NULL, "1 MB document renders");
    agentia_md_free(h);
    if (dt < best) best = dt;
  }
  double per_mb = best / ((double)total / (1024.0 * 1024.0));
  printf("        1 MB corpus: %.1f ms  (%.1f ms/MB)\n", best, per_mb);

  /* Artifact-scale timings — the sizes this app actually opens. */
  const size_t sizes[] = {10 * 1024, 50 * 1024, 200 * 1024};
  for (size_t s = 0; s < 3; s++) {
    size_t n = sizes[s] < total ? sizes[s] : total;
    double t0 = now_ms();
    char *h = agentia_md_to_html(big, n, AGENTIA_MD_DEFAULT_FLAGS);
    double dt = now_ms() - t0;
    agentia_md_free(h);
    printf("        %4zu KB: %.3f ms\n", n / 1024, dt);
  }

  /* What does turning sourcepos on actually cost? Agentia needs it for the
     diff view, so the answer decides whether it can be always-on. */
  double bare = 1e18;
  for (int run = 0; run < 3; run++) {
    double t0 = now_ms();
    char *h = agentia_md_to_html(big, total, AGENTIA_MD_UNSAFE_HTML);
    double dt = now_ms() - t0;
    agentia_md_free(h);
    if (dt < bare) bare = dt;
  }
  printf("        without sourcepos: %.1f ms  (sourcepos costs %+.1f%%)\n", bare,
         (best - bare) / bare * 100.0);

  /* The research claim was 20-26 ms/MB on old hardware. Fail only if we are
     wildly off, which would mean the extension set is pathological. */
  check(per_mb < 250.0, "throughput is within a sane envelope");

  free(big);
}

static void test_pathological(void) {
  printf("pathological input\n");

  struct {
    const char *name;
    char fill;
    size_t count;
    const char *prefix;
  } cases[] = {
      {"deeply nested emphasis", '*', 20000, ""},
      {"unclosed brackets", '[', 50000, ""},
      {"unclosed backticks", '`', 50000, ""},
      {"angle brackets", '<', 50000, ""},
  };

  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    size_t n = cases[i].count;
    char *buf = (char *)malloc(n + 2);
    if (!buf) continue;
    memset(buf, cases[i].fill, n);
    buf[n] = '\n';
    buf[n + 1] = '\0';

    double t0 = now_ms();
    char *h = agentia_md_to_html(buf, n + 1, AGENTIA_MD_DEFAULT_FLAGS);
    double dt = now_ms() - t0;
    agentia_md_free(h);
    free(buf);

    printf("        %-24s %6zu chars: %8.1f ms\n", cases[i].name, n, dt);
    /* Not a hard assertion on time — hardware varies. This exists so a
       regression into quadratic behaviour is visible in CI output. */
  }

  /* The input ceiling must actually be enforced. */
  size_t over = AGENTIA_MD_MAX_INPUT + 1;
  char *h = agentia_md_to_html("x", over, AGENTIA_MD_DEFAULT_FLAGS);
  check(h == NULL, "oversized input is rejected before parsing");
}

static void test_version(void) {
  printf("version\n");
  const char *v = agentia_md_cmark_version();
  check(v != NULL && v[0] != '\0', "cmark version string is present");
  printf("        cmark-gfm %s\n", v);
}

int main(void) {
  printf("== agentia_markdown C tests ==\n\n");

  test_basics();
  test_gfm_extensions();
  test_footnote_backref_repair();
  test_output_is_well_formed();
  test_sourcepos();
  test_raw_html_and_tagfilter();
  test_edge_cases();
  test_throughput();
  test_pathological();
  test_version();

  printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
