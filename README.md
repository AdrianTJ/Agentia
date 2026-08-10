# Agentia

A fast, minimalist macOS reader for Markdown and HTML — built for reviewing the artifacts
that coding agents leave behind.

Not a note-taker (Obsidian owns that). Not an IDE (VS Code owns that). A place to open a
generated file, read it, see what changed since the last run, export it well, and push it
somewhere useful.

---

## Architecture

Parse Markdown with **cmark-gfm in Swift**, emit HTML, and render everything — Markdown and
HTML alike — through a **single WKWebView** in a plain AppKit window.

The case rests on one observation: **you need a web view anyway.** Nothing else on macOS
renders arbitrary agent-written HTML. Once WebKit is on the critical path for half your file
types, adding a native Markdown renderer beside it buys nothing and costs two theme systems,
two PDF paths, and two sets of bugs.

One refinement over the libraries in the wild: **parse in Swift, not in the page.** The
popular WKWebView Markdown views ship `markdown-it` inside the HTML, which forces JavaScript
to stay on. Parsing in-process means the web view receives finished HTML and Markdown can
render with scripting pinned to a single hash.

```
file.md ──► cmark-gfm (C, in-process) ──► HTML ──┐
                                                  ├──► WKWebView ──► screen
file.html ───────────────── as-is ───────────────┘        │           └──► PDF
                                                     network blocked
```

| Layer | Path | What it does |
| --- | --- | --- |
| C shim | `Sources/CAgentiaMarkdown/` | cmark-gfm behind three functions; GFM extensions, footnotes, source positions |
| Core | `Sources/AgentiaCore/` | Page assembly, themes, diff engine, asset-path validation. Foundation only |
| App | `Sources/Agentia/` | AppKit shell, hardened web view, `artifact://` handler, FSEvents watcher, PDF export |
| Shell | `Sources/AgentiaCore/Resources/` | HTML template, base CSS, pinned script, six themes |

## Security model

Agent-written HTML is code nobody reviewed. Containment is **three independent mechanisms**,
because any one of them can be wrong:

1. **Page CSP.** `shell.js` is byte-stable, so its SHA-256 is fixed and pinned into
   `script-src`. All variable data arrives as a JSON block, which cannot extend the allowlist.
   Both profiles set `connect-src 'none'` and name no remote origin.
2. **Content rule list.** A compiled `WKContentRuleList` blocks every non-`artifact:` load
   inside WebKit, before a request is issued, and reports the count to the toolbar.
3. **Navigation delegate.** The only permitted navigation is the document's own load. A
   document cannot replace itself with something else.

Two profiles differ *only* in scripting:

| | Markdown | HTML artifact |
| --- | --- | --- |
| Document's own JS | cannot run | runs |
| Network | none | none, with a per-document override |
| Storage | non-persistent | non-persistent |

The parser is **not** a sanitiser, and the tests pin that: `tagfilter` escapes `<script>` and
`<iframe>`, but `onerror=` passes straight through. The CSP is load-bearing, not a second
layer.

## Building and testing

Two of the three layers are testable **without a Mac**, which is how they were developed:

```bash
./tools/build-ctest.sh              # C parsing core — 71 checks, clang only
node tools/webtest/run-tests.mjs    # render shell in real Chromium — 104 checks
python3 tools/verify-diff-vectors.py  # diff reference implementation — 15 vectors
```

On macOS:

```bash
swift test                          # AgentiaCore
tools/make-app.sh                   # builds .build/Agentia.app
```

### What is verified, and what is not

Being honest about this matters more than looking finished.

| Layer | Status |
| --- | --- |
| C parsing core | **Tested.** 71 checks: CommonMark, every GFM extension, source positions, edge cases, throughput, pathological input |
| Render shell, themes, print CSS | **Tested in a real browser.** 104 checks including CSP enforcement and PDF content extraction |
| Diff engine | **Algorithm verified** via a Python transcription run against 15 hand-checked vectors |
| AgentiaCore Swift | **Written, not yet compiled.** Full XCTest suite ships; needs `swift test` on a Mac |
| macOS app layer | **Written, not yet compiled.** Needs the macOS SDK |

The Swift layers were written on Linux with no Swift toolchain available
(`download.swift.org` is unreachable from the build environment). To keep them honest anyway:

- `tools/gen-golden.mjs` emits the values `AgentiaCore` and `build-page.mjs` must agree on
  byte for byte. Expectations are **computed by running the JS implementation**, never written
  by hand, so a golden value cannot itself be wrong.
- `tools/verify-diff-vectors.py` is a transcription of `DiffEngine` that executes here and
  generates the vectors the Swift tests assert.

Expect first `swift build` on a Mac to surface compile errors. That is the known cost of the
environment, not a design assumption.

## Things the testing actually caught

- **A real bug in `swiftlang/swift-cmark`.** Its gfm branch emits an unterminated attribute on
  the footnote backref — `aria-label="Back to reference 1↩</a>` with no closing `">`. An
  unterminated attribute swallows the rest of the document, so a **single footnote corrupts
  the entire page**, including the shell script. Upstream `github/cmark-gfm` is correct; the
  defect is specific to Apple's fork. `CAgentiaMarkdown` repairs it, with tests pinning both
  the repair and the correct multi-backref path it must not touch. It becomes a no-op if the
  dependency is fixed.
- **Code blocks squeezing instead of scrolling.** Tables inside a scroll container inherited
  `width: 100%` and wrapped every cell rather than overflowing, so the container never
  actually scrolled.
- **A case-preservation bug** in the Swift `</script` neutralisation, found by building the
  parity harness rather than by reading the code.

## Measured

On an x86 vCPU with cmark-gfm 0.29.0.gfm.13:

| Input | Parse |
| --- | --- |
| 10 KB | 0.46 ms |
| 50 KB | 1.8 ms |
| 200 KB | 7.5 ms |

Source positions roughly double parse cost, which is still negligible at artifact scale, so
they stay on for the diff view. No quadratic blowup on unclosed-bracket, backtick or
angle-bracket bombs at 50k characters.

**The number that still does not exist** is cold launch to first paint from a Finder
double-click on Apple Silicon. No public source establishes it, so `AppDelegate` carries
`os_signpost` markers and `tools/make-app.sh` prints the commands to measure it:

```bash
log stream --predicate 'subsystem == "app.agentia"' --style compact &
open -a .build/Agentia.app report.md
```

| Result | Response |
| --- | --- |
| under ~250 ms | Proceed as designed |
| 250–450 ms | Proceed; trim frameworks and defer non-essential init |
| over ~450 ms | Ship a Quick Look extension for the instant peek; the app becomes the deliberate open |

## Design documents

| Document | What's in it |
| --- | --- |
| [`docs/interface-study.html`](docs/interface-study.html) | Interactive window mock — side tabs, reading themes, diff view, PDF theme gallery |
| [`docs/technical-proposal.html`](docs/technical-proposal.html) | Architecture decision, security model, launch budget, phased plan, risk register |

## Themes

Six ship. A theme is a folder — `theme.json`, `screen.css`, `print.css` — so adding one needs
no code, and the reading view and the PDF are the same rendering path.

Manuscript · Report · Technical · Editorial · Compact · Terminal

Font stacks degrade to system faces when the optional OFL families are absent. The iA Writer
families and IBM Plex are OFL 1.1 and can be bundled outright; Charter, Palatino and SF Mono
already ship with macOS. Running heads come from `NSPrintInfo`, not CSS — no shipping browser
engine implements CSS `@page` margin boxes.

## Not built yet

Sidebar document list and folder mode, find bar UI, send-to-app menu, Quick Look extension,
syntax highlighting, Mermaid and KaTeX behind a per-document opt-in, App Intents, notarisation
and Sparkle.
