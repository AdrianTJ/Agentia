#!/usr/bin/env bash
#
# Builds and runs the C tests for the agentia_markdown shim against real
# cmark-gfm sources. Works on Linux and macOS — no Swift toolchain needed, so
# the parsing core stays testable anywhere.
#
# The cmark-gfm source is fetched into .build-cache/ and reused.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/.build-cache"
CMARK="$CACHE/swift-cmark"
OUT="$CACHE/ctest"

# Pinned to the gfm branch of swift-cmark, which is what Package.swift resolves.
CMARK_REPO="${AGENTIA_CMARK_REPO:-https://github.com/swiftlang/swift-cmark.git}"
CMARK_BRANCH="gfm"

CC="${CC:-clang}"

mkdir -p "$CACHE" "$OUT"

if [ ! -d "$CMARK/src" ]; then
  echo "==> fetching cmark-gfm ($CMARK_BRANCH)"
  rm -rf "$CMARK"
  git clone --depth 1 -b "$CMARK_BRANCH" "$CMARK_REPO" "$CMARK" >/dev/null 2>&1
fi

INCLUDES=(
  -I"$CMARK/src/include"
  -I"$CMARK/src"
  -I"$CMARK/extensions"
  -I"$CMARK/extensions/include"
  -I"$ROOT/Sources/CAgentiaMarkdown/include"
)

LIB="$OUT/libcmarkgfm.a"
if [ ! -f "$LIB" ]; then
  echo "==> building cmark-gfm"
  OBJDIR="$OUT/obj"
  mkdir -p "$OBJDIR"
  (
    cd "$OBJDIR"
    # -w: cmark-gfm's own warnings are not our problem and drown out ours.
    $CC -c -O2 -fPIC -w "${INCLUDES[@]}" "$CMARK"/src/*.c "$CMARK"/extensions/*.c
    ar rcs "$LIB" ./*.o
  )
fi

echo "==> building shim + tests"
# Our own code is held to a stricter bar than the vendored library.
# gnu11 rather than c11: the tests use clock_gettime, which strict ISO mode
# hides behind feature-test macros that differ between Linux and macOS.
$CC -O2 -std=gnu11 -Wall -Wextra -Werror \
  "${INCLUDES[@]}" \
  "$ROOT/Sources/CAgentiaMarkdown/agentia_markdown.c" \
  "$ROOT/tools/ctest/test_markdown.c" \
  "$LIB" \
  -lpthread \
  -o "$OUT/test_markdown"

echo "==> building render CLI"
$CC -O2 -std=gnu11 -Wall -Wextra -Werror \
  "${INCLUDES[@]}" \
  "$ROOT/Sources/CAgentiaMarkdown/agentia_markdown.c" \
  "$ROOT/tools/cli/agentia_render_cli.c" \
  "$LIB" \
  -lpthread \
  -o "$OUT/agentia_render_cli"

echo "==> running"
echo
"$OUT/test_markdown"
