# Handoff

You are picking up Agentia on a Mac. The previous agent built it on Linux with **no Swift
toolchain**, so a large part of your value is doing what that environment could not.

Read `README.md` for what the app is and why it is built this way. This document is the
operational handoff: what state things are in, what to do first, and what not to break.

---

## 1. The one thing that matters most

**The Swift has never been compiled.** Not once. Neither `AgentiaCore` nor the app target.

Everything else — the C parsing core, the render shell, the themes, the print CSS, the diff
algorithm — is genuinely tested and passing. The Swift is careful, reviewed, and unverified.

So your first job is `swift build`, and you should expect it to fail. That is not a surprise
or a regression; it is the known cost of where it was written. Work through the errors, then
run `swift test` and expect a second round.

Do not treat a compile error as evidence the design is wrong. Fix the mechanical problem and
keep the structure unless the error is telling you something real about the architecture.

### Specific things most likely to break

Ordered by how confident the reviewer was that they are wrong:

| Location | Problem | Suggested fix |
|---|---|---|
| `PDFExporter.write` | `info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url` — the subscript takes `Any`, and `AttributeKey` is a `RawRepresentable` struct, not a string | Use `.rawValue as NSString` as the key, or set `jobDisposition` and let the save panel supply the URL |
| `MarkdownRenderer.maximumInputBytes` | `Int(AGENTIA_MD_MAX_INPUT)` — the macro is `((size_t)16 * 1024 * 1024)`, and macros containing C casts sit at the edge of what ClangImporter imports | If it does not import, expose it as a real symbol: `extern const size_t agentia_md_max_input;` |
| `Launch.signposter` | `OSSignposter(logHandle:)` availability, and the property is unused anyway | Delete it; the `os_signpost` calls are what the measurement uses |
| `HardenedWebView.deinit` | Reads the `userContent` computed property, which touches `configuration` during deallocation | If it misbehaves, capture the controller in a stored property at init instead |
| `Preferences.appearance` | Reads `NSApp.effectiveAppearance`; safe as called today (from `applicationWillFinishLaunching`) but fragile | Pass appearance in rather than reading a global |
| Strict concurrency | `Launch.processStart`, `Launch.didLogFirstPaint`, `ResourceBundle.override` are mutable statics | Fine in Swift 5 mode. Under Swift 6 mode they need boxing — the package is **not** strict-concurrency clean and should not be advertised as such |

The manifest declares `swift-tools-version: 5.9`. `nonisolated(unsafe)` was removed because it
needs 5.10; if you raise the tools version, you may want it back.

---

## 2. Test suites, and which ones you can trust

```bash
./tools/build-ctest.sh                # 102 checks — C parsing core, clang only
node tools/webtest/run-tests.mjs      # 147 checks — render shell in real Chromium
python3 tools/verify-diff-vectors.py  #  15 vectors — diff reference implementation
swift test                            # AgentiaCore — NEVER YET RUN
tools/make-app.sh                     # builds .build/Agentia.app
```

The first three pass today. Run them before and after any change to the C shim, the shell, or
the themes — they are fast and they have already caught real bugs.

`tools/webtest/` needs `npm install` once. Chromium comes from `PLAYWRIGHT_BROWSERS_PATH` or
falls back to a system install; on your Mac you may need `npx playwright install chromium`,
and can drop the `executablePath` override in `run-tests.mjs`.

### Four tests are known to be weak

Do not read them as coverage:

- The `javascript:` URL check never clicks the link, so it passes with no CSP at all.
- `check(1, "free(NULL) is safe")` is a tautology (the preceding call is the real test).
- `ok(pageCount >= 1, "PDF has pages")` cannot fail on a valid PDF.
- The copy-button count lacks the non-empty guard its neighbour has.

---

## 3. Invariants — do not break these

These are load-bearing. Each one exists because something went wrong without it.

**1. `shell.js` must stay byte-stable and must never contain interpolated document content.**
Its SHA-256 is pinned into `script-src`. The moment anything document-derived is written into
that file, the CSP stops meaning anything. All variable data goes through the
`#agentia-bootstrap` JSON block. After editing `shell.js`, run `node tools/gen-golden.mjs` or
the Swift parity test fails.

**2. The page-to-host bridge exists only for the markdown profile.**
`HardenedWebView.setBridgeInstalled(_:)`. Script message handlers live in the page content
world, which is the same world an HTML artifact's own script runs in. With the bridge present,
one line inside an artifact could call `postMessage({type:"openExternal", …})` and have the
host open a URL carrying document text — past the CSP, past the content rule list, past the
navigation delegate. If you add a message type, ask what an artifact could do with it.

**3. `AgentiaCore.RenderShell` and `tools/webtest/build-page.mjs` must stay behaviourally
identical.** The browser suite tests the JS one; the app ships the Swift one. `golden.json`
is what keeps them honest, and its expectations are *computed by running the JS*, never
written by hand. Change one, change both, regenerate.

**4. Source positions must stay aligned with the original file.**
`data-sourcepos` line numbers drive the diff view. This is why front matter is blanked with
spaces rather than removed — byte count and line count are preserved. Any future
preprocessing must do the same.

**5. `AssetResolver` rejects `..` before touching the filesystem.**
Reject-then-resolve, not resolve-then-check, so the handler cannot be used to probe for files
outside the document folder. It also resolves symlinks and compares by path component, not
string prefix. The reviewer tried to break it and could not; keep it that way.

**6. The footnote backref repair is a workaround, not a feature.**
`swiftlang/swift-cmark`'s gfm branch emits an unterminated `aria-label`, which swallows the
rest of the document — one footnote corrupts the whole page. Upstream `github/cmark-gfm` is
correct. If the dependency is ever fixed, the repair stops matching and becomes a no-op, which
is by design. Do not delete it without checking the linked version.

---

## 4. Open decision: why there is C, and whether it should stay

**Do not read the C layer as a considered language choice.** It was not one, and you should
know that before building on it.

`Sources/CAgentiaMarkdown/` is 439 lines of C. It exists because of two forces, only one of
which is a real engineering reason:

1. cmark-gfm **is** a C library, so something has to cross a C boundary regardless.
2. The previous session had no Swift toolchain, and needed the parsing core to be testable
   *somewhere*. clang was available, so the logic went where it could be verified.

Rust was also installed on that machine (`/root/.cargo/bin/cargo`) and was never checked for.
That is a gap in the process, not a conclusion about Rust.

### The 439 lines are two different things

| Part | Roughly | Why it is C |
|---|---|---|
| FFI over cmark — parser lifecycle, extension registration, render, tree walk | ~150 lines | Legitimate. The boundary has to exist. |
| Byte manipulation — footnote repair, structural tag escaping, front-matter blanking | ~250 lines | **Accident of environment.** Pure string processing that happens to live in C because that is where it could be tested. |

The second block holds every raw `malloc`/`memcpy`/`memcmp` in the project — hand-rolled
buffer arithmetic, which is the classic overflow shape. It was audited (ASan, UBSan,
LeakSanitizer, and a 300k-iteration structured fuzz run, all clean), but that is mitigation,
not absence of risk.

### Recommended: move the byte manipulation to Swift, keep the FFI in C

You have a Swift toolchain; the constraint that put that code in C is gone. Moving
`repair_footnote_backrefs`, `neutralise_structural_tags` and the front-matter pass into
`AgentiaCore` makes them bounds-checked and considerably easier to read, and shrinks the C to
thin FFI with essentially no unsafe surface.

Two things to preserve if you do this:

- The front-matter pass must keep **blanking with spaces rather than removing**, or source
  positions shift and the diff view misaligns (invariant 4 above).
- Port the C tests rather than dropping them. They currently pin the footnote repair against
  the paths it must *not* touch, which is the part most likely to regress.

### When Rust becomes the right answer

Not as a shim language — as a **parser replacement**. Swapping cmark-gfm for comrak (the Rust
cmark-gfm-compatible implementation) would remove three things this codebase currently carries:

- The malformed footnote backref, which is Apple's fork diverging from upstream and would not
  follow you
- cmark-gfm's quadratic-blowup CVE history, which is why the depth and output caps exist
- Every raw memory operation in the parse path

The cost is real and permanent: **SwiftPM cannot build Rust.** You would need a prebuilt static
library, a hand-written C header, universal-binary handling for arm64 and x86_64, and a build
step living outside `swift build` — ongoing friction in a project whose thesis is few moving
parts. Performance is not the tiebreaker; parsing is 0.46 ms for 10 KB and comrak is in the
same class. (Comrak's own edge-case behaviour has not been evaluated here — assume it has
different quirks, not none.)

**Suggested trigger:** if the footnote workaround ever needs a second workaround beside it,
that is cmark-gfm's fork telling you it is a liability, and the switch earns its build
complexity. Better decided early than after more code depends on the current shim's API.

Either path stays open: the C tests are written against the shim's three-function interface,
and the browser suite only shells out to the CLI, so both port largely intact.

## 5. What to do, in order

### Phase 0 — the measurement gate (do this before building features)

The entire architecture rests on a number nobody has published: cold launch to first paint
from a Finder double-click. Nothing in the research established it.

```bash
tools/make-app.sh
log stream --predicate 'subsystem == "app.agentia"' --style compact &
open -a .build/Agentia.app some-report.md
```

Measure cold (after a reboot) and warm, on a 20 KB artifact.

| Result | What it means |
|---|---|
| under ~250 ms | Proceed as designed |
| 250–450 ms | Proceed; trim frameworks and defer non-essential init |
| over ~450 ms | Ship a Quick Look extension for the instant peek and let the app be the deliberate open — it shares the render framework, so it is a target, not a second codebase |

Report the number. It changes what is worth building next.

### Then, in priority order

0. **Settle the C question** (§4). Cheap to do early, expensive to defer — the byte-manipulation
   passes should probably move to Swift now that a toolchain exists.
1. **HTML artifacts render as authored.** Currently they are spliced into the shell's
   `<main class="doc">`, so a self-contained dashboard gets clamped to a 68ch measure, has its
   `<pre>` colours overridden by `.doc pre`, and gets a light-themed Copy button injected into
   a dark page. For an app pitched as an artifact viewer this is the biggest functional gap.
   Wants a raw-document path: serve the artifact's own markup with an injected CSP `<meta>`,
   skip `.doc` typography, and skip shell.js's DOM mutations. Do not fix it by adding CSS
   overrides.
2. **Empty state for an empty document.** A whitespace-only `.md` currently opens as a blank
   white window. `.agentia-empty` exists but is only wired to "no document open".
3. **Sidebar and folder mode.** `SidebarView` is a stub that is never added to the view
   hierarchy, so the toolbar button and `⌘⇧E` do nothing. Either build it or disable the menu
   items so they do not read as broken.
4. **Find bar.** `performFind` only moves focus; `find(_:forward:)` has no caller.
5. **Diff-since-last-write, end to end.** The engine, the bootstrap plumbing and the CSS all
   exist and are tested. What is missing is the UI to enter the mode and show "3 blocks changed
   since 14:22:07".
6. **Send-to-app menu.** Nothing is built. Ranked design is in
   `docs/technical-proposal.html` §08 — clipboard first, real Open With second, Obsidian by
   writing into the vault folder rather than through the URL scheme.
7. **Syntax highlighting.** Deliberately absent. Must be native (tree-sitter), not
   highlight.js — the markdown profile has no JS budget beyond the pinned shell script.

`README.md` has the full Known Issues table, including smaller cosmetic ones.

---

## 6. Traps specific to this codebase

- **`Bundle.module` and the app bundle.** SwiftPM emits resources as a `.bundle` beside the
  binary; `tools/make-app.sh` copies it into `Contents/Resources`. `Contents/MacOS` looks
  plausible and is wrong — `Bundle.module` never searches there and the generated accessor
  ends in `fatalError()`. This does **not** reproduce under `swift run`, where
  `Bundle.main.bundleURL` happens to be the bin directory. If the app crashes at launch but
  `swift run` is fine, this is why.
- **cmark emits `EXIT` only for container nodes.** A depth counter driven by `ENTER`/`EXIT`
  events climbs on every text node and never comes back down. `max_block_depth` walks the
  parent chain instead. Same trap awaits anyone iterating the tree.
- **CSS cannot reveal a closed `<details>`.** The UA hides the slot, not the children, so
  `display: block` on children does nothing. `shell.js` sets the `open` attribute for print
  and restores after.
- **`NSAttributedString`'s HTML importer fetches remote subresources synchronously.** Anything
  that hands it untrusted HTML is a phone-home outside the entire security perimeter.
  `Clipboard.strippingRemoteReferences` exists for exactly this.
- **Agents write files by rename, not in place.** A `DispatchSource` on a file descriptor goes
  deaf after one regeneration. `FileWatcher` watches the containing directory with FSEvents.
- **`tagfilter` is not a sanitiser.** It escapes the GFM blocklist and nothing else —
  `onerror=` passes straight through, and `<meta>`/`</main>` needed a separate pass
  (`AGENTIA_MD_NEUTRALISE_STRUCTURAL`). Tests pin this so nobody later assumes otherwise.

---

## 7. Conventions

- Branch: `claude/agentia-mvp-implementation`. Eight commits, all green on the runnable suites.
- Commits are authored as **Adrian Tame Jacobo `<adrian.tame.jacobo@gmail.com>`** with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Commit messages explain *why*, and say plainly when something is unverified. Keep that.
- Comments explain reasoning, not mechanics. Several encode a bug that was actually hit —
  those are worth more than the code around them.
- No new dependencies without a reason. The whole app is AppKit, WebKit, and one C library.

## 8. Design references

| File | What it is |
|---|---|
| `docs/interface-study.html` | Interactive mock — toolbar rationale, side tabs, diff view, PDF theme gallery |
| `docs/technical-proposal.html` | Architecture decision, security model, launch budget, risk register |

Both are self-contained; open them in a browser. The interface study is the visual target, not
a spec — the implemented toolbar is a subset.
