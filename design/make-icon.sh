#!/usr/bin/env bash
#
# make-icon.sh — renders design/icon.svg into Sources/Agentia/Agentia.icns.
#
# Rendering goes through the Chromium that tools/webtest already depends on,
# rather than adding an image toolchain: the browser suite needs it anyway, and
# it is the same renderer the app's own pages are tested in. `iconutil` (part of
# macOS) does the final .icns assembly.
#
# Run after editing the SVG:
#     design/make-icon.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/design/icon.svg"
OUT="$ROOT/Sources/Agentia/Agentia.icns"
WORK="$(mktemp -d)"
ICONSET="$WORK/Agentia.iconset"

trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$ROOT/tools/webtest/node_modules/playwright" ]; then
  echo "playwright missing — run: (cd tools/webtest && npm install)" >&2
  exit 1
fi

mkdir -p "$ICONSET"

# Every size macOS asks for. The @2x entries are the same pixels as the next
# size up, which is why they are rendered once and copied.
# Run from tools/webtest: Node resolves a bare `playwright` import relative to
# the importing module's directory, not the working directory, so a script run
# from anywhere else cannot find it.
cd "$ROOT/tools/webtest"
node - "$SVG" "$ICONSET" <<'JS'
import { chromium } from "playwright";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const [svgPath, outDir] = process.argv.slice(2);
const svg = readFileSync(svgPath, "utf8");

// 1024 is rendered and downscaled by the browser at each step, so every size
// gets a properly resampled image rather than one nearest-neighboured copy.
const sizes = [16, 32, 64, 128, 256, 512, 1024];

const browser = await chromium.launch();
for (const size of sizes) {
  const page = await browser.newPage({
    viewport: { width: size, height: size },
    deviceScaleFactor: 1,
  });
  await page.setContent(
    `<html><body style="margin:0;background:transparent">
       <div style="width:${size}px;height:${size}px">${svg
         .replace(/width="1024"/, `width="${size}"`)
         .replace(/height="1024"/, `height="${size}"`)}</div>
     </body></html>`,
    { waitUntil: "load" }
  );
  await page.screenshot({
    path: join(outDir, `icon_${size}x${size}.png`),
    omitBackground: true,
  });
  await page.close();
}
await browser.close();
JS

cd "$ICONSET"
# iconutil's required names: the @2x file is the double-resolution image.
mv icon_32x32.png   icon_16x16@2x.png.tmp
mv icon_64x64.png   icon_32x32@2x.png.tmp
mv icon_256x256.png icon_128x128@2x.png.tmp
mv icon_512x512.png icon_256x256@2x.png.tmp
mv icon_1024x1024.png icon_512x512@2x.png.tmp

# The single-resolution entries reuse the same pixels at the nominal size.
cp icon_16x16@2x.png.tmp   icon_32x32.png
cp icon_128x128@2x.png.tmp icon_256x256.png
cp icon_256x256@2x.png.tmp icon_512x512.png
for f in *.tmp; do mv "$f" "${f%.tmp}"; done

cd "$WORK"
iconutil --convert icns --output "$OUT" "$ICONSET"

echo "wrote $OUT"
ls -lh "$OUT" | awk '{print "  " $5}'
