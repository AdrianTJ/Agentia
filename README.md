# Agentia

A fast, minimalist macOS reader for Markdown and HTML — built for reviewing the artifacts
that coding agents leave behind.

Not a note-taker (Obsidian owns that). Not an IDE (VS Code owns that). A place to open a
generated file, read it, see what changed since the last run, export it well, and push it
somewhere useful.

**Status:** design phase. No implementation yet — Phase 0 is a measurement spike, see below.

---

## The proposal in one paragraph

Parse Markdown with **cmark-gfm in Swift**, emit HTML, and render everything — Markdown and
HTML alike — through a **single WKWebView** inside a plain AppKit window. Ship unsandboxed
under Developer ID with Sparkle updates. Read-only rendering with a source toggle for v1;
no Typora-style live preview.

The case rests on one observation: **you need a web view anyway.** Nothing else on macOS
renders arbitrary agent-written HTML. Once WebKit is on the critical path for half your file
types, adding a native Markdown renderer beside it buys nothing and costs you two theme
systems, two PDF paths, and two sets of bugs.

## Design documents

| Document | What's in it |
| --- | --- |
| [`docs/interface-study.html`](docs/interface-study.html) | Interactive window mock — side tabs, reading themes, diff view, PDF theme gallery, toolbar rationale |
| [`docs/technical-proposal.html`](docs/technical-proposal.html) | Architecture decision, security model, launch budget, phased build plan, risk register |

Both are self-contained HTML — open them in a browser.

## Feature set

1. **Clean reading view by default.** Rendered Markdown at a proper measure, several
   typographic themes, light and dark.
2. **Markdown and HTML in one window.** HTML artifacts render with the network cut at the
   WebKit layer; the toolbar reports what was blocked.
3. **Side tabs, hidden by default.** `⌘⇧E` reveals them. Point the app at a folder and it
   becomes a live list of artifacts, newest first.
4. **Diff since last write.** The app already watches the file, so it keeps the previous
   version and highlights changed blocks when an agent regenerates the document. This is the
   feature nothing else has.
5. **PDF export with real typography.** Themes are folders — a manifest, a screen stylesheet
   and a print stylesheet — so the reading view and the PDF are the same rendering path.
6. **Copy and send.** Multi-representation clipboard, a real Open With list, and a pinned
   Obsidian vault target that writes the file rather than stuffing it through a URL scheme.

## What the research established

105 research agents, 23 sources, 25 claims adversarially verified — 14 confirmed, 11 killed.

**Confirmed**

- Every shipping macOS Markdown previewer uses a C parser feeding a web view (MacDown,
  QLMarkdown), verified by reading source rather than READMEs.
- Markdown parsing is not a bottleneck: cmark runs 20–26 ms/MB, so a 50 KB artifact parses in
  under a millisecond. Latency lives in launch and layout, never the parser.
- The native-SwiftUI route has no stable landing place — MarkdownUI is in maintenance mode and
  its successor Textual is 0.5.0, macOS 15+, with eager layout and `Mirror` reflection into
  SwiftUI privates.
- TextKit 2 still had open scroll and viewport defects being worked around in April 2026.
- `createPDF(configuration:)` and `printOperation(with:)` have been public since macOS 11 —
  the "WKWebView printing is broken" folklore traces to a repo last tested on macOS 10.15.
- iA Writer Mono/Duo/Quattro are OFL 1.1 and can be bundled in a commercial app.

**Killed**

- "Pre-warming a WKWebView cuts first load ~45%" — the cited benchmark is an iPhone XR on
  iOS 12.2 measuring per-load deltas inside a running app. Wrong platform, wrong measurement.
- "JS Markdown renderers are ~7× slower than cmark" — measures library throughput on an 11 MB
  corpus, irrelevant at artifact scale.
- "TextKit 2 is production-ready as of macOS 14" — failed verification 0–3.

**Unresolved**

- Nothing in public establishes WKWebView cold-start cost on modern macOS. This is the single
  most important number for the project and it has to be measured.

## Build sequence

| Phase | Duration | Scope |
| --- | --- | --- |
| **0 — Gate** | 2–3 days | Measurement spike: cold and warm launch-to-first-paint from a real Finder double-click, plus both PDF APIs on a hostile document. Nothing else starts until this number exists. |
| 1 | ~2 weeks | AppKit shell, hardened WKWebView, cmark-gfm, three themes, source toggle, find, copy, UTI registration |
| 2 | ~1 week | Print stylesheet, six theme folders, bundled OFL faces, export sheet |
| 3 | ~1.5 weeks | FSEvents watching, live reload with scroll preservation, side tabs, folder mode, diff view |
| 4 | ~1 week | Send-to menu, Quick Look extension, tree-sitter highlighting, notarization and Sparkle |

Deferred on purpose: Mermaid/KaTeX behind a per-document opt-in, App Intents, click-to-edit
blocks, a sandboxed App Store build.

## Phase 0 acceptance

| Cold-launch result | Response |
| --- | --- |
| under ~250 ms | Proceed as proposed |
| 250–450 ms | Proceed, then trim frameworks and defer non-essential init |
| over ~450 ms | Ship a Quick Look extension for the instant peek; the app becomes the deliberate open |

The third branch is a good outcome, not a failure — a Quick Look extension runs inside an
already-resident host process, and it shares the rendering framework, so it's a build target
rather than a second codebase.
