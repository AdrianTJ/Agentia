# Changelog

All notable changes to Agentia are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Math rendering via vendored KaTeX 0.16.22. Documents containing `$$…$$`,
  `\(…\)`, `\[…\]` or `\begin{…}` blocks get typeset math; currency and code
  blocks are untouched (no single-`$` delimiter). KaTeX ships inside the app
  bundle and is served over the `artifact://` scheme — no network is ever
  contacted, the CSP keeps `connect-src 'none'`, and injection only happens
  when the host detects math-shaped delimiters. A new Settings checkbox
  (default on) turns rendering off.
- Sparkle 2 auto-update framework, wired but inert until an `SUFeedURL` is
  configured in `Info.plist` (see README, "Releasing"). Adds a
  "Check for Updates…" item (⌘U) to the app menu when a feed is present.
- MetricKit reporting (`MetricsReporter`): logs daily metric payloads and
  archives crash/hang/CPU-exception diagnostic JSONs under
  `~/Library/Application Support/Agentia/diagnostics` (newest 20 kept).
  Nothing leaves the machine.
- `tools/make-app.sh` release hooks: `SIGN_IDENTITY` enables Developer ID
  signing with the hardened runtime; `NOTARY_PROFILE` additionally notarizes
  and staples via `notarytool`. Default build behavior is unchanged.

### Changed

- Removed stale `HANDOFF.md` and dead configuration surface
  (`ResourceBundle.override`, `ThemeStore.load(id:)`,
  `SyntaxHighlighter.supports(_:)`, `DiffRange.lineCount`) after an
  over-engineering audit; 12 abandoned agent worktrees (~3.7 GB) purged.

## [0.1.0] — initial development release

Markdown and HTML artifact viewer: cmark-gfm rendering in-process, hardened
WKWebView with three-layer containment, live diff decoration, in-place styled
Markdown editing, PDF export, six themes, FSEvents reload.
