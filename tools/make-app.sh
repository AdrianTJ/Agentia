#!/usr/bin/env bash
#
# Wraps the SwiftPM executable into a double-clickable Agentia.app.
#
# Using SwiftPM plus this script rather than an Xcode project keeps the whole
# build reproducible from the command line, which is what the Phase 0 launch
# measurement needs — an Xcode-managed app is harder to launch identically
# across cold and warm runs.
#
#   tools/make-app.sh [debug|release] [--install]     default: release
#
# Release signing, once an Apple Developer identity exists:
#
#   SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#   NOTARY_PROFILE=agentia-notary \
#     tools/make-app.sh
#
# SIGN_IDENTITY switches from ad-hoc to a real Developer ID signature with the
# hardened runtime. NOTARY_PROFILE names a credential profile stored with
# `xcrun notarytool store-credentials`; when set, the bundle is submitted,
# awaited and stapled. Either variable alone is fine: signing without
# notarisation still clears Gatekeeper for machines that skip the warning.
#
# --install replaces /Applications/Agentia.app with what was just built. Without
# it the bundle stays in .build, and a copy installed earlier keeps running the
# code it was built from — which reads as "the app ignored my changes".
#
# Then, for the Phase 0 number:
#   open -a "$PWD/.build/Agentia.app" path/to/document.md
#   log stream --predicate 'subsystem == "app.agentia"' --style compact

set -euo pipefail

if [ "$(uname)" != "Darwin" ]; then
  echo "make-app.sh builds a macOS app bundle and only runs on macOS." >&2
  echo "The render shell is testable anywhere Chromium runs:" >&2
  echo "  node tools/webtest/run-tests.mjs  # browser tests" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Agentia.app"
INSTALL_DIR="/Applications"
CONFIG="release"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install)     INSTALL=1 ;;
    *)
      echo "usage: make-app.sh [debug|release] [--install]" >&2
      exit 2
      ;;
  esac
done

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

# Stamp which commit this bundle was built from.
#
# Info.plist ships CFBundleVersion as a placeholder, so every build claimed to
# be build 1 and an installed copy was indistinguishable from a fresh one by
# anything short of hashing the binary. About Agentia now names the commit, so
# "is the app running my changes?" is a question the app itself answers.
#
# A dirty tree is marked as such: the bundle then contains code that is in no
# commit, and silently reporting the parent commit would be a lie.
REVISION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  REVISION="$REVISION+dirty"
fi
# Commit count: monotonic and numeric, which is what CFBundleVersion is
# specified to be. The revision goes in its own key rather than being crammed
# in here, so a future notarised build needs no change.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

PLB=/usr/libexec/PlistBuddy
"$PLB" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist" >/dev/null
"$PLB" -c "Add :AGBuildRevision string $REVISION" "$APP/Contents/Info.plist" >/dev/null
echo "   $REVISION (build $BUILD)"

# The icon, named to match CFBundleIconFile. Regenerate with design/make-icon.sh
# after editing design/icon.svg; it is committed so a build needs no Chromium.
if [ -f "$ROOT/Sources/Agentia/Agentia.icns" ]; then
  cp "$ROOT/Sources/Agentia/Agentia.icns" "$APP/Contents/Resources/Agentia.icns"
else
  echo "   no Agentia.icns — run design/make-icon.sh for the app icon" >&2
fi

# SwiftPM emits resources as a .bundle beside the binary. It must land in
# Contents/Resources: Bundle.module only searches Bundle.main.resourceURL,
# the defining bundle's resourceURL, and Bundle.main.bundleURL. Contents/MacOS
# is none of those, and the generated accessor ends in fatalError() — which
# would crash during applicationWillFinishLaunching, before first paint.
# This does not reproduce under `swift run`, where bundleURL is the bin dir.
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  # Test fixtures are built into the same directory and were being shipped
  # inside the app. They are dead weight a user downloads and never runs.
  case "$(basename "$bundle")" in
    *Tests.bundle) continue ;;
  esac
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Ad-hoc signature by default: enough for local launching. With SIGN_IDENTITY
# set, sign as Developer ID with the hardened runtime instead; with
# NOTARY_PROFILE also set, notarise and staple so Gatekeeper opens silently.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> signing ($SIGN_IDENTITY, hardened runtime)"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP" || {
    echo "   Developer ID signing failed" >&2
    exit 1
  }
else
  echo "==> signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "   ad-hoc signing failed; the app may still run locally" >&2
  }
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "NOTARY_PROFILE without SIGN_IDENTITY: Apple rejects unsigned uploads" >&2
    exit 1
  fi
  ZIP="$ROOT/.build/Agentia-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait || {
    echo "   notarisation failed; see 'xcrun notarytool log' output above" >&2
    exit 1
  }
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# Register with Launch Services so "Open With" sees it without a logout.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" || true
fi

echo
echo "built $APP"

if [ "$INSTALL" -eq 1 ]; then
  TARGET="$INSTALL_DIR/Agentia.app"

  # Replacing a bundle while it is running leaves the running copy with its
  # code pulled out from under it, which crashes it in confusing ways.
  if pgrep -x Agentia >/dev/null 2>&1; then
    echo
    echo "Agentia is running. Quit it first, then re-run with --install." >&2
    echo "  osascript -e 'quit app \"Agentia\"'   # asks about unsaved edits" >&2
    exit 1
  fi

  echo "==> installing to $TARGET"
  # Swap through a staging path and delete afterwards, so an interrupted copy
  # cannot leave a half-written bundle where a working app used to be.
  STAGE="$INSTALL_DIR/.Agentia.app.incoming.$$"
  rm -rf "$STAGE"
  cp -R "$APP" "$STAGE"
  if [ -d "$TARGET" ]; then
    OLD="$INSTALL_DIR/.Agentia.app.previous.$$"
    mv "$TARGET" "$OLD"
    mv "$STAGE" "$TARGET" || { mv "$OLD" "$TARGET"; exit 1; }
    rm -rf "$OLD"
  else
    mv "$STAGE" "$TARGET"
  fi

  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$TARGET" || true
  echo "installed $REVISION (build $BUILD)"
fi

echo
echo "which build is installed:"
echo "  defaults read $INSTALL_DIR/Agentia.app/Contents/Info AGBuildRevision"
echo
echo "measure cold launch:"
echo "  log stream --predicate 'subsystem == \"app.agentia\"' --style compact &"
echo "  open -a \"$APP\" <file.md>"
