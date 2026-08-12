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
file.md ──► cmark-gfm (in-process) ──► HTML ──┐
                                               ├──► WKWebView ──► screen
file.html ─────────────── as-is ──────────────┘        │           └──► PDF
                                                  network blocked
```

Agentia's own code is entirely Swift. cmark-gfm is the only C on the path, driven
directly through its C API — there is no intermediate shim to keep in step.

| Layer | Path | What it does |
| --- | --- | --- |
| Core | `Sources/AgentiaCore/` | cmark-gfm driving, GFM extensions, footnotes, source positions, page assembly, themes, diff engine, asset-path validation |
| App | `Sources/Agentia/` | AppKit shell, hardened web view, `artifact://` handler, FSEvents watcher, PDF export |
| Shell | `Sources/AgentiaCore/Resources/` | HTML template, base CSS, pinned script, six themes |
| CLI | `Sources/agentia-render-cli/` | Drives the renderer from a terminal, so the browser suite tests the code the app ships |

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

The two profiles differ in scripting, and in how much of the page is ours:

| | Markdown | HTML artifact |
| --- | --- | --- |
| Document's own JS | cannot run | runs |
| Network | none | none, with a per-document override |
| Storage | non-persistent | non-persistent |
| Page assembly | rendered into the shell | **served as authored** |

A Markdown file becomes a fragment inside the reading shell, which owns the typography and
runs one hash-pinned script. An HTML artifact arrives complete, so the shell would only
damage it: it is served as its own document with a CSP `<meta>` injected and nothing else
added — no stylesheet, no script, no DOM rewriting. See `Sources/AgentiaCore/RawArtifact.swift`,
which is mostly an argument about where that `<meta>` has to land: inside a comment or a
script body it is not a weaker policy, it is no policy, and the page looks identical either
way.

Losing the shell for artifacts also removes its link interception. That is deliberate — the
artifact profile already permits `'unsafe-inline'`, so a `javascript:` link grants nothing the
document's own `<script>` could not do, and navigation is contained host-side by the
navigation delegate, which the page cannot remove.

The parser is **not** a sanitiser, and the tests pin that: `tagfilter` escapes `<script>` and
`<iframe>`, but `onerror=` passes straight through. The CSP is load-bearing, not a second
layer.

## Building and testing

```bash
swift build                           # core, app, and the render CLI
swift test                            # 231 checks, green in debug and release
node tools/webtest/run-tests.mjs      # render shell in real Chromium — 210 checks
python3 tools/verify-diff-vectors.py  # diff reference implementation — 15 vectors
tools/make-app.sh                     # builds .build/Agentia.app
```

The browser suite shells out to `.build/debug/agentia-render-cli`, so `swift build` has to
run first. It renders through the same code the app links rather than a JavaScript
reimplementation that could drift.

If `swift test` reports `no such module 'XCTest'`, `xcode-select` is pointing at the Command
Line Tools, which do not ship it. Point it at Xcode, or prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### What is verified, and what is not

Being honest about this matters more than looking finished.

| Layer | Status |
| --- | --- |
| Parsing core | **Tested.** 51 checks: CommonMark, every GFM extension, source positions, front matter, structural neutralisation, nesting caps, edge cases, throughput, pathological input |
| Render shell, themes, print CSS | **Tested in a real browser.** 210 checks including CSP enforcement, navigation containment, print-overflow measurement and PDF content extraction |
| Diff engine | **Algorithm verified** via a Python transcription run against 15 hand-checked vectors, plus XCTest |
| AgentiaCore Swift | **Tested.** 231 XCTest cases, run in both debug and release |
| macOS app layer | **Partly tested.** The navigation guard moved into AgentiaCore so it could be; the rest is AppKit and WebKit wiring, verified by use |

Two harnesses exist to keep implementations that must agree from drifting:

- `tools/gen-golden.mjs` emits the values `AgentiaCore` and `build-page.mjs` must agree on
  byte for byte. Expectations are **computed by running the JS implementation**, never written
  by hand, so a golden value cannot itself be wrong.
- `tools/verify-diff-vectors.py` is a transcription of `DiffEngine` that generates the vectors
  the Swift tests assert.

## Things the testing actually caught

- **A real bug in `swiftlang/swift-cmark`.** Its gfm branch emits an unterminated attribute on
  the footnote backref — `aria-label="Back to reference 1↩</a>` with no closing `">`. An
  unterminated attribute swallows the rest of the document, so a **single footnote corrupts
  the entire page**, including the shell script. Upstream `github/cmark-gfm` is correct; the
  defect is specific to Apple's fork. `FootnoteBackref` repairs it, with tests pinning both
  the repair and the correct multi-backref path it must not touch. It becomes a no-op if the
  dependency is fixed.
- **Code blocks squeezing instead of scrolling.** Tables inside a scroll container inherited
  `width: 100%` and wrapped every cell rather than overflowing, so the container never
  actually scrolled.
- **A case-preservation bug** in the Swift `</script` neutralisation, found by building the
  parity harness rather than by reading the code.

A review pass and a dogfooding pass then found more, including three defects that would
each have stopped the app on first run (the resource bundle in a directory `Bundle.module`
never searches; a weak app delegate held only by a local; an empty state that overwrote
every Finder-opened document), a message-bridge hole that let an HTML artifact exfiltrate
document text with one line of script, wide tables losing 18 of 28 columns in the PDF, and a
200 KB file that could wedge the renderer indefinitely.

## Measured

Apple Silicon, release build, cmark-gfm 0.29.0.gfm.13. The C column is the shim this code
replaced, measured on the same machine against the same corpus before it was deleted:

| Input | Swift | C (former shim) |
| --- | --- | --- |
| 10 KB | 0.39 ms | 0.41 ms |
| 50 KB | 1.73 ms | 1.69 ms |
| 200 KB | 6.79 ms | 6.96 ms |
| 1 MB | 33.9 ms | 36.2 ms |

Source positions cost about 43%, which is negligible at artifact scale, so they stay on for
the diff view. No quadratic blowup on unclosed-bracket, backtick or angle-bracket bombs at
50k characters.

A debug build is roughly 30x slower — it compiles cmark-gfm at `-O0` along with everything
else — so `swift test` reports about 1 s/MB. The throughput test picks its ceiling by
configuration for that reason; only the release number means anything.

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

## Picking this up

If you are continuing this work — especially on a Mac, where the Swift can finally be
compiled — start with [`HANDOFF.md`](HANDOFF.md). It covers the compile errors to expect
first, the invariants that must not be broken, and the task order.

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

## Known issues

Found by dogfooding and not yet fixed. Recorded rather than quietly dropped.

| Issue | Impact |
| --- | --- |
| Mermaid fences render as plain code blocks; `$…$` math renders as raw TeX | Deferred deliberately (both need JS, behind a per-document opt-in), but very visible in agent output |
| Dark mode looks nearly identical across all six themes — only the accent differs | Paper and ink come from `base.css`; whether that is right is a design call |
| A wide table gives no visual hint that columns continue off-screen | It scrolls, but nothing says so |
| Technical theme has `##`/`###` heading markers but no `#` on h1 | Terminal theme has all three |
| Adjacent footnote references render as `34` rather than `3,4` | Reads as "thirty-four" |

The three formerly-weak tests have been strengthened: the `javascript:` URL
check now clicks the link in both the hash-pinned and the artifact profiles
(the artifact profile allows inline script, so only `shell.js`'s
`preventDefault` stands between the click and execution), the PDF page count
is asserted to a non-tautological band derived from the fixture's measured
2–4 pages, and the copy-button check first proves the fixture has code
blocks so it cannot pass by having nothing to count.

## Not built yet

Four items remain, and three of them are blocked by packaging rather than by effort.
Recording why, so nobody re-derives it:

| Item | What stands in the way |
| --- | --- |
| Quick Look extension | SwiftPM builds only `executable` and `library` products — there is no app-extension product type, so this needs an Xcode project. It is also no longer forced: the measured ~436 ms launch sits inside the "proceed as designed" band rather than past it, so Quick Look is a nice-to-have, not the fallback the original plan made it |
| App Intents | Intents are registered by an Xcode build phase that extracts metadata at compile time. Without it the definitions compile and never appear in Shortcuts |
| Notarisation and Sparkle | Needs a Developer ID certificate. `security find-identity -v -p codesigning` reports 0 valid identities here, so the app is ad-hoc signed and cannot be notarised from this machine |
| Mermaid and KaTeX | Not blocked, just expensive and unresolved. Both are megabytes of vendored JavaScript, and the markdown profile pins `script-src` to one hash — so each needs a second pinned hash and a per-document opt-in, which is a security surface worth designing rather than bolting on |

Folder mode is built: the sidebar lists the documents beside the one being read, newest
first, because an agent writes a run — report, summary, dashboard — into one directory and
moving between those is the navigation this app is for. The same sidebar switches to the
document's outline, which `shell.js` has been building on every load since the beginning.

Source view (⌘U) is editable and saves on ⌘S — only on ⌘S, never on a timer, because this
app opens files in directories an agent is watching and writing on a timer there invites a
loop. While the buffer has unsaved edits the file watcher stops, so a rerun cannot reload over
them; a save that finds the file rewritten asks rather than choosing for you; and closing,
quitting or switching documents with unsaved edits all prompt. A save reproduces the file's
own encoding, BOM and line endings, and follows symlinks rather than replacing them.

Launching with no document opens a scratchpad (`~/Library/Application Support/Agentia/`)
with the caret already in it, rather than a page explaining how to open a file. It is an
ordinary Markdown file, so it persists between launches and Reveal in Finder works on it.

The reader controls two things, in Settings (⌘,) and in the View menu: which of the six
themes, and text size. Size is a multiplier rather than an absolute, so each theme keeps the
relationship it designed between body size, measure and typeface — the six range from 13.5px
to 18.5px at 1.0 and all move together. It is pinned back to 1 for print, since a sheet of
paper is a fixed size and scaling type there only makes the document longer.

Syntax highlighting is native and lexical — `SyntaxHighlighter` in AgentiaCore, one tokeniser
driven by a small table per language. The proposal named tree-sitter; that would mean the
tree-sitter runtime plus a C grammar per language, which is a lot of vendored C to re-acquire
in a project that just finished removing its own, to build parse trees nothing here needs.
`Language.spec(for:)` is the only thing a tree-sitter backend would have to replace.
