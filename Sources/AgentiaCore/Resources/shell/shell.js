/*
 * shell.js — the only script allowed to run in a rendered document.
 *
 * This file is byte-stable: its SHA-256 is computed at build time and pinned
 * into the page's script-src. Nothing derived from the document is ever
 * interpolated into it. Everything variable arrives through the
 * #agentia-bootstrap JSON block, which is data and cannot extend the
 * allowlist.
 *
 * If you edit this file, the hash changes and AgentiaCore recomputes it — but
 * never interpolate document content here, or the CSP stops meaning anything.
 */
(function () {
  "use strict";

  var doc = document.getElementById("agentia-doc");
  if (!doc) return;

  /* ---------- bootstrap ---------- */

  function readBootstrap() {
    var node = document.getElementById("agentia-bootstrap");
    if (!node) return {};
    try {
      return JSON.parse(node.textContent || "{}") || {};
    } catch (e) {
      return {};
    }
  }

  var config = readBootstrap();

  /* The host bridge. Absent in a plain browser (which is how the test suite
     runs), so every call goes through this guard. */
  function post(message) {
    try {
      if (window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.agentia) {
        window.webkit.messageHandlers.agentia.postMessage(message);
        return true;
      }
    } catch (e) { /* bridge unavailable */ }
    return false;
  }

  /* ---------- source position mapping ---------- */

  /* cmark emits data-sourcepos="startLine:startCol-endLine:endCol". */
  function parseSourcePos(value) {
    if (!value) return null;
    var dash = value.indexOf("-");
    if (dash < 0) return null;
    var startLine = parseInt(value.slice(0, value.indexOf(":")), 10);
    var endPart = value.slice(dash + 1);
    var endLine = parseInt(endPart.slice(0, endPart.indexOf(":")), 10);
    if (isNaN(startLine)) return null;
    if (isNaN(endLine)) endLine = startLine;
    return { start: startLine, end: endLine };
  }

  /* ---------- diff decoration ---------- */

  /* Returns how many top-level blocks were decorated, which is what the
     banner reports — the count of ranges would be a different number, and the
     one the reader cannot see. */
  function applyDiff(ranges) {
    if (!ranges || !ranges.length) return 0;

    var decorated = 0;
    var blocks = doc.querySelectorAll("[data-sourcepos]");
    for (var i = 0; i < blocks.length; i++) {
      var el = blocks[i];

      /* Only decorate top-level blocks. Marking a nested <li> as well as its
         parent <ul> double-tints the same text. */
      if (el.parentElement !== doc) continue;

      var span = parseSourcePos(el.getAttribute("data-sourcepos"));
      if (!span) continue;

      for (var r = 0; r < ranges.length; r++) {
        var range = ranges[r];
        var overlaps = span.start <= range.end && span.end >= range.start;
        if (!overlaps) continue;

        el.classList.add("agentia-diff");
        el.classList.add(range.kind === "added"
          ? "agentia-diff-added"
          : "agentia-diff-modified");
        decorated++;
        break;
      }
    }

    return decorated;
  }

  /* Says what the tint means, and when the baseline was taken.
     The decorations alone are ambiguous — a reader who did not turn diff mode
     on themselves has no way to tell a highlight from a theme flourish.

     Inserted as the first child of #agentia-doc rather than as a sibling: a
     sibling has to restate .doc's measure and padding to line up with the
     text, and themes are free to override those on .doc, so the banner drifted
     out of alignment with the very document it labels. Inside, it inherits
     whatever the theme decided.

     It carries no data-sourcepos, so it is invisible to applyDiff. */
  function showDiffBanner(count, since) {
    if (!count) return;

    var banner = document.createElement("p");
    banner.className = "agentia-diff-banner";
    banner.setAttribute("role", "status");

    var text = count === 1 ? "1 block changed" : count + " blocks changed";
    if (since) text += " since " + since;
    banner.textContent = text;

    doc.insertBefore(banner, doc.firstChild);
  }

  /* ---------- wide tables get their own scroll container ---------- */

  function wrapTables() {
    var tables = doc.querySelectorAll("table");
    for (var i = 0; i < tables.length; i++) {
      var table = tables[i];
      if (table.parentElement &&
          table.parentElement.classList.contains("agentia-scroll")) continue;

      var wrap = document.createElement("div");
      wrap.className = "agentia-scroll";
      /* Carry the position through so diff decoration still finds it. */
      var pos = table.getAttribute("data-sourcepos");
      if (pos) wrap.setAttribute("data-sourcepos", pos);

      table.parentNode.insertBefore(wrap, table);
      wrap.appendChild(table);
    }
  }

  /* ---------- copy buttons on code blocks ---------- */

  function addCopyButtons() {
    var blocks = doc.querySelectorAll("pre");
    for (var i = 0; i < blocks.length; i++) {
      (function (pre) {
        var button = document.createElement("button");
        button.className = "agentia-copy";
        button.type = "button";
        button.textContent = "Copy";
        button.setAttribute("aria-label", "Copy code block");

        button.addEventListener("click", function (event) {
          event.preventDefault();
          event.stopPropagation();

          var code = pre.querySelector("code");
          var text = (code || pre).textContent || "";

          /* Prefer the host: NSPasteboard works without the clipboard
             permission dance, and can write several representations. */
          var handled = post({ type: "copy", text: text });
          if (!handled && navigator.clipboard) {
            navigator.clipboard.writeText(text).catch(function () {});
          }

          button.textContent = "Copied";
          button.setAttribute("data-copied", "true");
          window.setTimeout(function () {
            button.textContent = "Copy";
            button.removeAttribute("data-copied");
          }, 1400);
        });

        pre.appendChild(button);
      })(blocks[i]);
    }
  }

  /* ---------- self-describing links ---------- */

  /* Print appends the href after a link so it is reachable on paper. For an
     autolinked bare URL — which GFM produces constantly in agent output — that
     prints the same URL twice. Mark those so the print stylesheet can skip
     them; CSS alone cannot compare text to an attribute. */
  function markSelfLinks() {
    var links = doc.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
      var link = links[i];
      var text = (link.textContent || "").trim();
      var href = link.getAttribute("href") || "";
      if (text === href || text === href.replace(/\/$/, "")) {
        link.setAttribute("data-agentia-self-link", "");
      }
    }
  }

  /* ---------- printing ---------- */

  /* Expand every collapsed <details> for print and restore afterwards.
     Agent Markdown puts logs, stack traces and full command output inside
     them, and on paper a collapsed block is simply lost content. */
  function expandDetailsForPrint() {
    var reopened = [];

    function expand() {
      reopened = [];
      var blocks = doc.querySelectorAll("details:not([open])");
      for (var i = 0; i < blocks.length; i++) {
        blocks[i].setAttribute("open", "");
        reopened.push(blocks[i]);
      }
    }

    function restore() {
      for (var i = 0; i < reopened.length; i++) {
        reopened[i].removeAttribute("open");
      }
      reopened = [];
    }

    window.addEventListener("beforeprint", expand);
    window.addEventListener("afterprint", restore);

    /* Also react to the media type changing directly, which is how a
       headless PDF render and the print-preview path behave. */
    if (window.matchMedia) {
      var query = window.matchMedia("print");
      var onChange = function (event) {
        if (event.matches) { expand(); } else { restore(); }
      };
      if (query.addEventListener) {
        query.addEventListener("change", onChange);
      } else if (query.addListener) {
        query.addListener(onChange);
      }
      if (query.matches) expand();
    }
  }

  /* ---------- outline ---------- */

  function buildOutline() {
    var headings = doc.querySelectorAll("h1, h2, h3, h4, h5, h6");
    var outline = [];
    for (var i = 0; i < headings.length; i++) {
      var h = headings[i];
      if (!h.id) h.id = "agentia-h" + i;
      outline.push({
        id: h.id,
        level: parseInt(h.tagName.slice(1), 10),
        title: (h.textContent || "").trim()
      });
    }
    return outline;
  }

  /* ---------- scroll position ---------- */

  function documentScrollHeight() {
    return Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
  }

  function restoreScroll(fraction) {
    if (typeof fraction !== "number" || fraction <= 0) return;
    /* Wait for layout — images and web fonts change the height after parse,
       and restoring too early lands in the wrong place. */
    window.requestAnimationFrame(function () {
      window.requestAnimationFrame(function () {
        window.scrollTo(0, documentScrollHeight() * fraction);
      });
    });
  }

  var scrollTimer = null;
  function watchScroll() {
    window.addEventListener("scroll", function () {
      if (scrollTimer !== null) window.clearTimeout(scrollTimer);
      scrollTimer = window.setTimeout(function () {
        post({
          type: "scroll",
          fraction: window.scrollY / documentScrollHeight()
        });
      }, 120);
    }, { passive: true });
  }

  /* ---------- links ---------- */

  function interceptLinks() {
    doc.addEventListener("click", function (event) {
      var node = event.target;
      while (node && node !== doc && node.tagName !== "A") node = node.parentElement;
      if (!node || node.tagName !== "A") return;

      var href = node.getAttribute("href") || "";
      if (!href) return;

      /* In-document anchors scroll here; everything else is the host's
         decision, so the artifact can never navigate itself away. */
      if (href.charAt(0) === "#") return;

      event.preventDefault();
      post({ type: "openExternal", url: node.href });
    });
  }

  /* ---------- go ---------- */

  wrapTables();
  addCopyButtons();
  markSelfLinks();
  expandDetailsForPrint();
  showDiffBanner(applyDiff(config.diffRanges), config.diffSince);
  interceptLinks();
  watchScroll();
  restoreScroll(config.scrollFraction);

  post({
    type: "ready",
    outline: buildOutline(),
    blockCount: doc.children.length
  });
})();
