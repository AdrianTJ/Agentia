#!/usr/bin/env bash
#
# Wraps the SwiftPM executable into a double-clickable Agentia.app.
#
# Using SwiftPM plus this script rather than an Xcode project keeps the whole
# build reproducible from the command line, which is what the Phase 0 launch
# measurement needs — an Xcode-managed app is harder to launch identically
# across cold and warm runs.
#
#   tools/make-app.sh [debug|release]     default: release
#
# Then, for the Phase 0 number:
#   open -a "$PWD/.build/Agentia.app" path/to/document.md
#   log stream --predicate 'subsystem == "app.agentia"' --style compact

set -euo pipefail

if [ "$(uname)" != "Darwin" ]; then
  echo "make-app.sh builds a macOS app bundle and only runs on macOS." >&2
  echo "The parsing core and render shell are testable anywhere:" >&2
  echo "  tools/build-ctest.sh              # C tests" >&2
  echo "  node tools/webtest/run-tests.mjs  # browser tests" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/.build/Agentia.app"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product Agentia

BIN="$(swift build -c "$CONFIG" --product Agentia --show-bin-path)/Agentia"
if [ ! -x "$BIN" ]; then
  echo "build produced no executable at $BIN" >&2
  exit 1
fi

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Agentia"
cp "$ROOT/Sources/Agentia/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM emits resources as a .bundle beside the binary; the app needs it
# alongside the executable so Bundle.module resolves.
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/MacOS/"
done

# Ad-hoc signature: enough for local launching. A distributed build needs a
# Developer ID identity, the hardened runtime, and notarisation.
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "   ad-hoc signing failed; the app may still run locally" >&2
}

# Register with Launch Services so "Open With" sees it without a logout.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" || true
fi

echo
echo "built $APP"
echo
echo "measure cold launch:"
echo "  log stream --predicate 'subsystem == \"app.agentia\"' --style compact &"
echo "  open -a \"$APP\" <file.md>"
