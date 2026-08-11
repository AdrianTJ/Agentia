/*
 * run-tests.mjs — drives the real render shell through Chromium.
 *
 * Chromium is not WebKit, so this does not prove WKWebView behaviour. What it
 * does prove is that the CSS, the CSP and shell.js are correct as written:
 * print rules actually wrap code, the page never scrolls sideways, the diff
 * decoration lands on the right blocks, and no script inside a document runs.
 * Those are engine-independent properties of the markup we generate.
 */

import { chromium } from "playwright";
import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildPage, listThemes, Profile, shellScriptHash, ROOT,
} from "./build-page.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "output");
// Built by `swift build`. Driving the real renderer rather than a JS
// reimplementation is what keeps this suite honest about what the app ships.
const CLI = join(ROOT, ".build", "debug", "agentia-render-cli");

let checks = 0;
let failures = 0;
const failureLog = [];

function ok(condition, what, detail) {
  checks++;
  if (!condition) {
    failures++;
    failureLog.push(`  FAIL  ${what}${detail ? `\n        ${detail}` : ""}`);
    console.log(`  FAIL  ${what}${detail ? `\n        ${detail}` : ""}`);
  }
}

function renderMarkdown(path) {
  if (!existsSync(CLI)) {
    throw new Error(
      `render CLI missing at ${CLI} — run \`swift build\` first`
    );
  }
  return execFileSync(CLI, [path], { encoding: "utf8", maxBuffer: 64 << 20 });
}

/* The raw page an HTML artifact is actually served as. Produced by the same
   Swift code the app links, so the CSP injection logic under test here is the
   real one and not a JS mirror of it. */
function renderArtifact(path) {
  if (!existsSync(CLI)) {
    throw new Error(`render CLI missing at ${CLI} — run \`swift build\` first`);
  }
  return execFileSync(CLI, ["--artifact", path], {
    encoding: "utf8", maxBuffer: 64 << 20,
  });
}

/* ------------------------------------------------------------------ */

async function main() {
  mkdirSync(OUT, { recursive: true });

  const torturePath = join(HERE, "fixtures", "torture.md");
  const fragment = renderMarkdown(torturePath);
  const themes = listThemes();

  console.log(`== Agentia render shell (Chromium) ==\n`);
  console.log(`themes: ${themes.map((t) => t.id).join(", ")}`);
  console.log(`shell.js hash: ${shellScriptHash()}\n`);

  // Use a preinstalled Chromium when one is present (CI images often ship a
  // build that does not match the npm package's expected revision).
  const launchOptions = {};
  const preinstalled = process.env.AGENTIA_CHROMIUM || "/opt/pw-browsers/chromium";
  if (existsSync(preinstalled)) launchOptions.executablePath = preinstalled;

  const browser = await chromium.launch(launchOptions);

  try {
    await testSecurity(browser, fragment);
    await testShellBehaviour(browser, fragment);
    await testDiffDecoration(browser);
    await testLayout(browser, fragment, themes);
    await testPrintAndPDF(browser, fragment, themes);
    await testDarkAppearance(browser, fragment);
    await testHTMLArtifactProfile(browser);
    await testDocumentCannotNavigate(browser);
  } finally {
    await browser.close();
  }

  console.log(`\n${checks} checks, ${failures} failures`);
  if (failures) {
    console.log("\nfailures:");
    failureLog.forEach((l) => console.log(l));
  }
  process.exit(failures === 0 ? 0 : 1);
}

/* ---------- 1. security ---------- */

async function testSecurity(browser, fragment) {
  console.log("security");
  const page = await browser.newPage();

  const cspViolations = [];
  await page.exposeFunction("__recordViolation", (d) => cspViolations.push(d));

  const html = buildPage({
    content: fragment,
    themeId: "manuscript",
    title: "Security",
    profile: Profile.markdown,
  });

  await page.setContent(html, { waitUntil: "load" });
  await page.waitForTimeout(400);

  const flags = await page.evaluate(() => ({
    scriptRan: typeof window.__agentiaScriptRan !== "undefined",
    onErrorRan: typeof window.__agentiaOnErrorRan !== "undefined",
    jsURLRan: typeof window.__agentiaJavascriptURLRan !== "undefined",
    shellRan: !!document.querySelector(".agentia-copy"),
    scriptTagInDOM: !!document.querySelector("#agentia-doc script"),
  }));

  ok(!flags.scriptRan, "inline <script> in the document did not execute");
  ok(!flags.onErrorRan, "img onerror handler did not execute");
  ok(!flags.jsURLRan, "javascript: URL did not execute");
  ok(!flags.scriptTagInDOM, "no script element survives into the document body");
  ok(flags.shellRan, "the pinned shell script DID run (CSP is not over-broad)");

  // The old check was weak: nothing ever clicked the link, so the flag could
  // never be set and the assertion was vacuous. Click it for real — shell.js
  // must prevent the navigation before the browser considers a javascript:
  // URL, and the page must not navigate anywhere.
  const jsLink = page.locator('#agentia-doc a[href^="javascript:"]');
  ok(await jsLink.count() >= 1, "fixture contains a javascript: link");
  await jsLink.first().click();
  await page.waitForTimeout(150);
  const afterClick = await page.evaluate(() => ({
    ran: typeof window.__agentiaJavascriptURLRan !== "undefined",
    stillHere: !!document.getElementById("agentia-doc"),
  }));
  ok(!afterClick.ran, "clicking a javascript: link does not execute it");
  ok(afterClick.stillHere, "clicking a javascript: link does not navigate away");

  // The CSP must not have been weakened to make the above pass.
  const csp = await page.evaluate(() => {
    const m = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
    return m ? m.getAttribute("content") : "";
  });
  ok(csp.includes("connect-src 'none'"), "CSP forbids network connections");
  ok(csp.includes("default-src 'none'"), "CSP default-src is none");
  ok(/script-src 'sha256-[A-Za-z0-9+/=]+'/.test(csp),
     "markdown profile pins script-src to a hash", csp);
  ok(!csp.includes("script-src 'unsafe-inline'"),
     "markdown profile does not allow arbitrary inline script");

  await page.close();
}

/* ---------- 2. shell.js behaviour ---------- */

async function testShellBehaviour(browser, fragment) {
  console.log("shell script");
  const page = await browser.newPage();
  await page.setContent(
    buildPage({ content: fragment, themeId: "report", title: "Shell" }),
    { waitUntil: "load" }
  );
  await page.waitForTimeout(250);

  const state = await page.evaluate(() => {
    const doc = document.getElementById("agentia-doc");
    const tables = doc.querySelectorAll("table");
    let wrapped = 0;
    tables.forEach((t) => {
      if (t.parentElement.classList.contains("agentia-scroll")) wrapped++;
    });
    const headings = doc.querySelectorAll("h1,h2,h3,h4,h5,h6");
    let withIds = 0;
    headings.forEach((h) => { if (h.id) withIds++; });
    return {
      tables: tables.length,
      wrapped,
      pres: doc.querySelectorAll("pre").length,
      copyButtons: doc.querySelectorAll(".agentia-copy").length,
      headings: headings.length,
      withIds,
      wrapperKeepsSourcePos:
        doc.querySelector(".agentia-scroll")?.hasAttribute("data-sourcepos") ?? false,
    };
  });

  ok(state.tables > 0, "fixture contains a table");
  ok(state.wrapped === state.tables, "every table is wrapped in a scroll container",
     `${state.wrapped}/${state.tables}`);
  ok(state.pres > 0, "fixture contains code blocks");
  ok(state.copyButtons === state.pres, "every code block gets a copy button",
     `${state.copyButtons}/${state.pres}`);
  ok(state.withIds === state.headings, "every heading has an id for the outline",
     `${state.withIds}/${state.headings}`);
  ok(state.wrapperKeepsSourcePos,
     "table wrapper carries data-sourcepos so diff still finds it");

  await page.close();
}

/* ---------- 3. diff decoration ---------- */

async function testDiffDecoration(browser) {
  console.log("diff decoration");

  // A small document with known line positions.
  const md = [
    "# Title",          // line 1
    "",                 // 2
    "Unchanged para.",  // 3
    "",                 // 4
    "## Added heading", // 5
    "",                 // 6
    "Added body text.", // 7
    "",                 // 8
    "Modified para.",   // 9
  ].join("\n");

  const tmp = join(OUT, "diff-fixture.md");
  writeFileSync(tmp, md + "\n");
  const fragment = renderMarkdown(tmp);

  const page = await browser.newPage();
  await page.setContent(
    buildPage({
      content: fragment,
      themeId: "manuscript",
      title: "Diff",
      bootstrap: {
        diffRanges: [
          { start: 5, end: 7, kind: "added" },
          { start: 9, end: 9, kind: "modified" },
        ],
        diffSince: "14:22:07",
      },
    }),
    { waitUntil: "load" }
  );
  await page.waitForTimeout(200);

  const result = await page.evaluate(() => {
    const doc = document.getElementById("agentia-doc");
    const out = [];
    for (const el of doc.children) {
      out.push({
        tag: el.tagName,
        text: (el.textContent || "").trim().slice(0, 24),
        added: el.classList.contains("agentia-diff-added"),
        modified: el.classList.contains("agentia-diff-modified"),
      });
    }
    return out;
  });

  const byText = (t) => result.find((r) => r.text.startsWith(t));
  ok(byText("Title") && !byText("Title").added && !byText("Title").modified,
     "unchanged heading is not decorated");
  ok(byText("Unchanged para") && !byText("Unchanged para").added,
     "unchanged paragraph is not decorated");
  ok(byText("Added heading")?.added === true, "added heading is marked added");
  ok(byText("Added body text")?.added === true, "added paragraph is marked added");
  ok(byText("Modified para")?.modified === true, "modified paragraph is marked modified");
  ok(byText("Modified para")?.added === false,
     "modified paragraph is not also marked added");

  /* The banner. Decorations alone are ambiguous — a reader who did not turn
     diff mode on has no way to tell a tint from a theme flourish. */
  const banner = await page.evaluate(() => {
    const el = document.querySelector(".agentia-diff-banner");
    const doc = document.getElementById("agentia-doc");
    return el ? {
      text: el.textContent.trim(),
      insideDoc: doc.contains(el),
      isFirst: doc.firstElementChild === el,
      alignedWithText: (() => {
        const h = doc.querySelector("h1");
        return h ? Math.abs(el.getBoundingClientRect().left
                            - h.getBoundingClientRect().left) < 2 : false;
      })(),
      printed: getComputedStyle(el).display,
    } : null;
  });

  ok(banner !== null, "diff mode explains itself with a banner");
  ok(banner?.text === "3 blocks changed since 14:22:07",
     "banner counts decorated blocks and names the baseline", banner?.text);
  ok(banner?.insideDoc === true,
     "banner lives inside .doc so it inherits the theme's measure and padding");
  ok(banner?.isFirst === true, "banner is the first thing in the document");
  ok(banner?.alignedWithText === true,
     "banner lines up with the body text rather than floating off-measure");

  // No ranges means no banner — an unchanged document must stay quiet.
  const quiet = await browser.newPage();
  await quiet.setContent(
    buildPage({ content: fragment, themeId: "manuscript", title: "No diff" }),
    { waitUntil: "load" }
  );
  await quiet.waitForTimeout(150);
  ok(await quiet.evaluate(() => !document.querySelector(".agentia-diff-banner")),
     "no banner when there is nothing to report");
  await quiet.close();

  await page.close();
}

/* ---------- 4. screen layout ---------- */

async function testLayout(browser, fragment, themes) {
  console.log("screen layout");

  for (const theme of themes) {
    const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
    await page.setContent(
      buildPage({ content: fragment, themeId: theme.id, title: theme.name }),
      { waitUntil: "load" }
    );
    await page.waitForTimeout(200);

    const m = await page.evaluate(() => {
      const de = document.documentElement;
      const doc = document.getElementById("agentia-doc");

      // Any element wider than the viewport that is not inside a designated
      // scroll container is a layout bug.
      const overflowing = [];
      for (const el of doc.querySelectorAll("*")) {
        if (el.closest(".agentia-scroll") || el.closest("pre")) continue;
        if (el.getBoundingClientRect().width > de.clientWidth + 1) {
          overflowing.push(el.tagName + "." + (el.className || ""));
        }
      }
      return {
        pageScrollWidth: de.scrollWidth,
        clientWidth: de.clientWidth,
        overflowing: overflowing.slice(0, 4),
        measurePx: doc.getBoundingClientRect().width,
      };
    });

    ok(m.pageScrollWidth <= m.clientWidth + 1,
       `${theme.id}: page does not scroll horizontally`,
       `scrollWidth ${m.pageScrollWidth} vs client ${m.clientWidth}`);
    ok(m.overflowing.length === 0,
       `${theme.id}: no element overflows the viewport`,
       m.overflowing.join(", "));

    await page.screenshot({
      path: join(OUT, `screen-${theme.id}-light.png`),
      fullPage: false,
    });
    await page.close();
  }
}

/* ---------- 5. print + PDF ---------- */

async function testPrintAndPDF(browser, fragment, themes) {
  console.log("print + pdf");

  for (const theme of themes) {
    const page = await browser.newPage();
    await page.setContent(
      buildPage({ content: fragment, themeId: theme.id, title: theme.name }),
      { waitUntil: "load" }
    );

    await page.emulateMedia({ media: "print" });
    await page.waitForTimeout(200);

    // The defect this guards against: a long code line running past the right
    // edge of the sheet and being silently dropped from the PDF.
    const printMetrics = await page.evaluate(() => {
      const over = (el) => el.scrollWidth - el.clientWidth;

      const pres = [...document.querySelectorAll("#agentia-doc pre")];
      const clipped = pres
        .map((p, i) => ({ what: "pre" + i, over: over(p) }))
        .filter((r) => r.over > 1);

      // Tables were the real gap: the print rules reset the container's
      // overflow but not the table's max-content width, so a wide table ran
      // off the sheet and every column past the edge was dropped from the PDF.
      const wraps = [...document.querySelectorAll("#agentia-doc .agentia-scroll")];
      const clippedTables = wraps
        .map((w, i) => ({ what: "table" + i, over: over(w) }))
        .filter((r) => r.over > 1);

      const style = pres.length ? getComputedStyle(pres[0]) : null;
      const copyVisible = [...document.querySelectorAll(".agentia-copy")]
        .some((b) => getComputedStyle(b).display !== "none");

      // A collapsed <details> must print its body: on paper there is no way
      // to expand it, and agents put logs and stack traces in them.
      const collapsed = [...document.querySelectorAll("#agentia-doc details:not([open])")];
      const hiddenBodies = collapsed.filter((d) => {
        const body = [...d.children].find((c) => c.tagName !== "SUMMARY");
        return body ? getComputedStyle(body).display === "none" : false;
      }).length;

      return {
        preCount: pres.length,
        tableCount: wraps.length,
        clipped, clippedTables, hiddenBodies,
        whiteSpace: style ? style.whiteSpace : null,
        copyVisible,
      };
    });

    ok(printMetrics.preCount > 0, `${theme.id}: fixture has code blocks`);
    ok(printMetrics.tableCount > 0, `${theme.id}: fixture has tables`);
    ok(printMetrics.clipped.length === 0,
       `${theme.id}: no code block is clipped in print`,
       JSON.stringify(printMetrics.clipped));
    ok(printMetrics.clippedTables.length === 0,
       `${theme.id}: no table is clipped in print`,
       JSON.stringify(printMetrics.clippedTables));
    ok(printMetrics.hiddenBodies === 0,
       `${theme.id}: collapsed <details> bodies are expanded in print`);
    ok(printMetrics.whiteSpace === "pre-wrap",
       `${theme.id}: code wraps in print`, `white-space=${printMetrics.whiteSpace}`);
    ok(!printMetrics.copyVisible,
       `${theme.id}: copy buttons are hidden in print`);

    // A visual record of what the print stylesheet actually produces, at the
    // real page width. Useful for review; also catches gross layout breakage
    // that a numeric assertion would miss.
    await page.setViewportSize({ width: 816, height: 1056 });
    await page.screenshot({
      path: join(OUT, `print-${theme.id}.png`),
      fullPage: true,
    });

    const pdfPath = join(OUT, `${theme.id}.pdf`);
    await page.pdf({
      path: pdfPath,
      preferCSSPageSize: true,
      printBackground: true,
    });

    const bytes = readFileSync(pdfPath);
    const header = bytes.subarray(0, 5).toString("latin1");
    const pageCount = (bytes.toString("latin1").match(/\/Type\s*\/Page[^s]/g) || []).length;

    ok(header === "%PDF-", `${theme.id}: produced a valid PDF`);
    ok(bytes.length > 5000, `${theme.id}: PDF is not empty`, `${bytes.length} bytes`);
    // The old check was a tautology — any valid PDF has at least one page, so
    // it could never fail. The fixture is well over a sheet of content and
    // measured at 2-4 pages across all six themes: a theme that squeezes the
    // whole document onto one page has broken typography, and a page count
    // past 8 means the sheet size collapsed (e.g. a bad @page width).
    ok(pageCount >= 2, `${theme.id}: PDF paginates the document`, `${pageCount} pages`);
    ok(pageCount <= 8, `${theme.id}: PDF has a sane page count`, `${pageCount} pages`);

    // The defect that matters most: content present on screen but missing from
    // the PDF because it ran off the edge of the sheet. Extract the text and
    // look for markers taken from the very end of the document and from the
    // longest code line.
    const text = await extractPDFText(pdfPath);
    // Whitespace-insensitive comparison. PDF text extraction splits words at
    // ligatures ("fix" arrives as "fi" + "x") and at hyphenated line breaks,
    // so a literal match reports missing content that is in fact present.
    // Collapsing all whitespace still proves the character sequence is there.
    const squashed = text.replace(/\s+/g, "");
    for (const marker of PDF_CONTENT_MARKERS) {
      // Some fonts embed ligature glyphs with an empty ToUnicode map, so the
      // "fi" of "fix" arrives as an empty string rather than "fi". The glyph
      // is drawn — the content did not run off the sheet — so an empty item
      // is treated as matching up to three marker characters (an "ffi" glyph).
      const present = squashed.includes(marker.replace(/\s+/g, ""))
        || looseLigatureMatch(squashed, marker.replace(/\s+/g, ""));
      ok(present, `${theme.id}: PDF retains "${marker.slice(0, 34)}"`);
    }

    console.log(
      `        ${theme.id.padEnd(11)} ${String(pageCount).padStart(2)} pages  ` +
      `${String(Math.round(bytes.length / 1024)).padStart(4)} KB`
    );

    await page.close();
  }
}

/* Markers chosen from places most likely to be lost: the final paragraph, a
   footnote body, deep list nesting, and the tail of the longest code line. */
const PDF_CONTENT_MARKERS = [
  "candidate set with near-duplicates",
  "Pro Git corpus",
  "And no reranker change can fix it",
  "latency_p99=percentile(latencies, 99)",
  // Inside a collapsed <details>, which used to be dropped entirely.
  "Agent Markdown uses this constantly",
  // The last column of the wide table, which used to run off the sheet.
  "retrieval",
];

async function extractPDFText(path) {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const doc = await pdfjs.getDocument({
    data: new Uint8Array(readFileSync(path)),
    useSystemFonts: true,
  }).promise;

  let out = "";
  for (let i = 1; i <= doc.numPages; i++) {
    const page = await doc.getPage(i);
    const content = await page.getTextContent();
    // A glyph drawn but with no usable Unicode mapping extracts as an empty
    // string, or as a private-use character (U+E000–U+F8FF) when the font's
    // cmap leaves the glyph unmapped — Iowan Old Style's "fi" arrives as
    // U+F001. Both mean the glyph is laid out on the sheet but its text is
    // unrecoverable, so both become a sentinel that looseLigatureMatch
    // treats as a drawn glyph.
    out += content.items
      .map((it) => {
        if (!it.str.length) return "\u{E000}";
        return [...it.str].map((ch) => {
          const cp = ch.codePointAt(0);
          return (cp >= 0xE000 && cp <= 0xF8FF) ? "\u{E000}" : ch;
        }).join("");
      })
      .join(" ") + "\n";
  }
  await doc.destroy();
  return out;
}

/* Does `pdf` (whitespace-stripped, sentinel-flagged unmapped glyphs) contain
   `marker`? A sentinel stands for one glyph whose Unicode mapping is missing
   from the PDF: an "fi"/"ffl" ligature (up to three characters), a soft
   hyphen, or an extra space glyph where a line wrapped. Try every plausible
   character count — including zero — so a single unmapped glyph cannot reject
   content that is laid out; every other character must match exactly in
   order. */
function looseLigatureMatch(pdf, marker) {
  const PLACEHOLDER = "\u{E000}";

  function matchAt(start) {
    function walk(p, m) {
      while (m < marker.length) {
        if (pdf[p] === PLACEHOLDER) {
          // One glyph may represent 0–3 marker characters.
          for (let take = 3; take >= 0; take--) {
            if (walk(p + 1, m + take)) return true;
          }
          return false;
        }
        if (pdf[p] !== marker[m]) return false;
        p += 1;
        m += 1;
      }
      return true;
    }
    return walk(start, 0);
  }

  // Sentinels compress the string (one glyph for up to three characters), so
  // a match can start at any position, even when pdf is shorter than marker.
  for (let start = 0; start <= pdf.length; start++) {
    if (matchAt(start)) return true;
  }
  return false;
}

/* ---------- 6. dark appearance ---------- */

async function testDarkAppearance(browser, fragment) {
  console.log("dark appearance");
  const page = await browser.newPage();

  for (const appearance of ["light", "dark"]) {
    await page.setContent(
      buildPage({
        content: fragment, themeId: "manuscript",
        title: "Appearance", appearance,
      }),
      { waitUntil: "load" }
    );
    await page.waitForTimeout(150);

    const c = await page.evaluate(() => {
      const s = getComputedStyle(document.body);
      const parse = (v) => (v.match(/\d+/g) || []).slice(0, 3).map(Number);
      const lum = ([r, g, b]) => 0.2126 * r + 0.7152 * g + 0.0722 * b;
      return { bg: lum(parse(s.backgroundColor)), fg: lum(parse(s.color)) };
    });

    if (appearance === "light") {
      ok(c.bg > 200, "light: background is light", `${c.bg.toFixed(0)}`);
      ok(c.fg < 90, "light: text is dark", `${c.fg.toFixed(0)}`);
    } else {
      ok(c.bg < 70, "dark: background is dark", `${c.bg.toFixed(0)}`);
      ok(c.fg > 180, "dark: text is light", `${c.fg.toFixed(0)}`);
    }
    ok(Math.abs(c.bg - c.fg) > 120,
       `${appearance}: text and background have real contrast`);

    await page.screenshot({ path: join(OUT, `appearance-${appearance}.png`) });
  }

  await page.close();
}

/* ---------- 7. html artifact profile ---------- */

async function testHTMLArtifactProfile(browser) {
  console.log("html artifact profile (raw document)");
  const page = await browser.newPage();

  // The real thing: a complete document with its own ground, measure and code
  // colours, served through the Swift raw-artifact path.
  const html = renderArtifact(join(HERE, "fixtures", "artifact.html"));

  const responses = [];
  page.on("response", (r) => responses.push(r.url()));
  const blocked = [];
  page.on("requestfailed", (r) => blocked.push(r.url()));

  await page.setContent(html, { waitUntil: "load" });
  await page.waitForTimeout(400);

  const ran = await page.evaluate(() => typeof window.__artifactScriptRan !== "undefined");
  ok(ran, "html artifact profile DOES run the document's own script");

  /* --- the point of the raw path: the document renders as authored --- */

  const authored = await page.evaluate(() => {
    const body = getComputedStyle(document.body);
    const pre = document.getElementById("code");
    const wrap = document.querySelector(".wrap");
    return {
      background: body.backgroundColor,
      preColour: pre ? getComputedStyle(pre).color : "",
      preBackground: pre ? getComputedStyle(pre).backgroundColor : "",
      wrapWidth: wrap ? wrap.getBoundingClientRect().width : 0,
      gridColumns: getComputedStyle(document.querySelector(".grid"))
        .gridTemplateColumns.split(" ").length,
      shellContainer: !!document.getElementById("agentia-doc"),
      docClass: !!document.querySelector(".doc"),
      copyButtons: document.querySelectorAll(".agentia-copy").length,
      bootstrap: !!document.getElementById("agentia-bootstrap"),
    };
  });

  ok(authored.background === "rgb(11, 15, 20)",
     "artifact keeps its own dark ground", authored.background);
  ok(authored.preColour === "rgb(126, 231, 135)",
     "artifact's own code colours survive (.doc pre used to override them)",
     authored.preColour);
  ok(authored.preBackground === "rgb(17, 24, 35)",
     "artifact's own pre background survives", authored.preBackground);
  ok(authored.gridColumns === 4,
     "a four-column grid stays four columns", `${authored.gridColumns}`);
  ok(authored.wrapWidth > 700,
     "layout is not clamped to the shell's 68ch reading measure",
     `${Math.round(authored.wrapWidth)}px`);

  ok(!authored.shellContainer, "no #agentia-doc wrapper is added");
  ok(!authored.docClass, "no .doc typography wrapper is added");
  ok(authored.copyButtons === 0, "no Copy buttons are injected into the artifact");
  ok(!authored.bootstrap, "no bootstrap block is added");

  /* --- containment is unchanged --- */

  const csp = await page.evaluate(() => {
    const m = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
    return m ? m.getAttribute("content") : "";
  });
  ok(csp.includes("connect-src 'none'"),
     "raw artifact still forbids network connections");
  ok(csp.includes("img-src artifact: data: blob:"),
     "raw artifact restricts images to local sources");
  ok(csp.includes("default-src 'none'"), "raw artifact keeps default-src none");

  const loaded = responses.filter((u) => u.startsWith("https://remote.test"));
  ok(loaded.length === 0, "no response was received from a remote origin", loaded.join(", "));
  const imgLoaded = await page.evaluate(() => {
    const img = document.querySelector('img[src^="https://remote.test"]');
    return img ? img.complete && img.naturalWidth > 0 : false;
  });
  ok(!imgLoaded, "remote image did not load");
  ok(blocked.some((u) => u.startsWith("https://remote.test")),
     "remote image request was actively blocked", blocked.join(", "));

  /* --- printing, which no longer has any theme print CSS behind it --- */

  // Artifacts skip the shell, so none of themes/*/print.css applies. That is
  // correct — the artifact's own @media print rules should win — but it means
  // nothing of ours stops a wide dashboard running off the sheet, so measure
  // rather than assume.
  const pdfPath = join(OUT, "artifact.pdf");
  await page.pdf({ path: pdfPath, format: "A4", printBackground: true });
  const pdfText = await extractPDFText(pdfPath);
  const squashed = pdfText.replace(/\s+/g, "");

  ok(squashed.includes("OpsDashboard"), "artifact PDF retains its heading");
  ok(squashed.includes("region:us-east-1"),
     "artifact PDF retains code-block content that sits below the fold");
  ok(squashed.includes("recall0.849"), "artifact PDF retains grid tile content");

  const overflow = await page.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth);
  ok(overflow <= 1, "artifact does not overflow horizontally", `${overflow}px`);

  // NOTE on javascript: links. The shelled path used to cancel them in
  // shell.js's interceptLinks, and this suite clicked one to prove it. The raw
  // path runs no shell script, so that page-level guard is gone on purpose:
  //
  //   * it was never a privilege boundary — this profile already permits
  //     'unsafe-inline', so the document's own <script> can do anything a
  //     javascript: URL could;
  //   * navigation is contained host-side by HardenedWebView's navigation
  //     delegate, which permits only artifact://doc and cannot be removed by
  //     the page, unlike a listener it could overwrite.
  //
  // That guard is a host-process decision, so a Chromium suite has nothing to
  // drive. It is covered by AgentiaCore's NavigationPolicyTests, which is why
  // the decision was moved out of HardenedWebView and into AgentiaCore — when
  // this note first claimed the delegate covered it, review pointed out there
  // was no test of the delegate anywhere, and the claim was empty.

  await page.close();
}

/* ---------- 8. navigation ---------- */

async function testDocumentCannotNavigate(browser) {
  console.log("navigation containment");

  // CSP does not govern top-level navigation, and tagfilter does not cover
  // <meta>. Without neutralisation a Markdown document could navigate the view
  // to an arbitrary URL — which both issues a request and replaces the page
  // with attacker-controlled content on the attacker's origin.
  const md = join(OUT, "nav-fixture.md");
  writeFileSync(md, [
    "# Quarterly report",
    "",
    '<meta http-equiv="refresh" content="0; url=http://127.0.0.1:9/EXFIL">',
    '<base href="http://127.0.0.1:9/">',
    "",
    "Body text the reader expected.",
    "",
  ].join("\n"));

  const fragment = renderMarkdown(md);
  ok(!fragment.includes("<meta"), "renderer neutralises <meta> in Markdown");
  ok(!fragment.includes("<base"), "renderer neutralises <base> in Markdown");

  const page = await browser.newPage();
  const navigations = [];
  page.on("framenavigated", (frame) => navigations.push(frame.url()));

  await page.setContent(
    buildPage({ content: fragment, themeId: "report", title: "Nav" }),
    { waitUntil: "load" }
  );
  await page.waitForTimeout(700);

  const escaped = navigations.filter((u) => u.startsWith("http://127.0.0.1:9"));
  ok(escaped.length === 0, "document did not navigate the view away",
     escaped.join(", "));

  const intact = await page.evaluate(() => ({
    hasDoc: !!document.getElementById("agentia-doc"),
    docCount: document.querySelectorAll("#agentia-doc").length,
    bodyKids: [...document.body.children].map((e) => e.tagName).join(","),
  }));
  ok(intact.hasDoc, "the document container survived");

  // A bare </main> used to close the container, leaving everything after it a
  // sibling of <body> — enough to paint a full-window overlay with no script.
  const breakout = join(OUT, "breakout-fixture.md");
  writeFileSync(breakout, [
    "# Innocent report",
    "",
    "</main>",
    "",
    '<div style="position:fixed;inset:0;background:#c00;z-index:99999">PWNED</div>',
    "",
    '<main id="agentia-doc" class="doc">',
    "",
    "## Fake continuation",
    "",
  ].join("\n"));

  const breakoutFragment = renderMarkdown(breakout);
  await page.setContent(
    buildPage({ content: breakoutFragment, themeId: "report", title: "Breakout" }),
    { waitUntil: "load" }
  );
  await page.waitForTimeout(250);

  const after = await page.evaluate(() => {
    const overlays = [...document.body.children].filter(
      (e) => e.id !== "agentia-doc" && e.tagName === "DIV"
    );
    return {
      docCount: document.querySelectorAll("#agentia-doc").length,
      strayOverlays: overlays.length,
      headingsFound: document.querySelectorAll("#agentia-doc h2").length,
    };
  });

  ok(after.docCount === 1, "exactly one document container exists",
     `found ${after.docCount}`);
  ok(after.strayOverlays === 0, "no element escaped the container",
     `${after.strayOverlays} stray`);
  ok(after.headingsFound >= 1,
     "content after the breakout attempt stays inside the container");

  await page.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
