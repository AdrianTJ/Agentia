/*
 * build-page.mjs — assembles a rendered document page from the shell template,
 * base CSS, a theme, and an HTML fragment.
 *
 * This mirrors AgentiaCore.RenderShell exactly. Both must produce identical
 * output for the same inputs; Tests/AgentiaCoreTests compares the Swift
 * implementation against golden files emitted by this script, so a drift
 * between the two fails the Swift test suite rather than going unnoticed.
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = join(HERE, "..", "..");
const RES = join(ROOT, "Sources", "AgentiaCore", "Resources");
const SHELL_DIR = join(RES, "shell");
const THEME_DIR = join(RES, "themes");

/** Document trust profiles. See docs/technical-proposal.html §05. */
export const Profile = {
  /** Markdown we rendered ourselves: only the pinned shell script may run. */
  markdown: "markdown",
  /** An HTML artifact: its own scripts run, but nothing may leave the machine. */
  htmlArtifact: "htmlArtifact",
};

export function shellScript() {
  return readFileSync(join(SHELL_DIR, "shell.js"), "utf8");
}

/** SHA-256 of the shell script, base64, in the form CSP expects. */
export function shellScriptHash(js = shellScript()) {
  return "sha256-" + createHash("sha256").update(js, "utf8").digest("base64");
}

/**
 * The Content-Security-Policy for a document.
 *
 * Both profiles set connect-src 'none' and omit any remote origin, so the
 * page cannot originate a network request even before the host's content
 * rule list is consulted. The difference between profiles is only how much of
 * the document's own code may run.
 */
export function contentSecurityPolicy(profile, scriptHash) {
  const scriptSrc =
    profile === Profile.htmlArtifact
      ? "'unsafe-inline' 'unsafe-eval'"
      : `'${scriptHash}'`;

  return [
    "default-src 'none'",
    "img-src artifact: data: blob:",
    "media-src artifact: data:",
    "font-src artifact: data:",
    // Inline styles cannot execute script, and agent Markdown uses them
    // routinely, so they are allowed in both profiles.
    "style-src 'unsafe-inline' artifact:",
    `script-src ${scriptSrc}`,
    "connect-src 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; ");
}

export function listThemes() {
  return readdirSync(THEME_DIR)
    .filter((name) => existsSync(join(THEME_DIR, name, "theme.json")))
    .map((name) =>
      JSON.parse(readFileSync(join(THEME_DIR, name, "theme.json"), "utf8"))
    )
    .sort((a, b) => a.order - b.order);
}

export function themeCSS(themeId) {
  const screen = readFileSync(join(THEME_DIR, themeId, "screen.css"), "utf8");
  const print = readFileSync(join(THEME_DIR, themeId, "print.css"), "utf8");
  return screen + "\n" + print;
}

export function escapeForHTMLText(value) {
  return String(value).replace(/[&<>]/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c])
  );
}

/**
 * JSON destined for a <script type="application/json"> block.
 *
 * The sequence "</script" must not appear, or the block closes early and the
 * remainder is parsed as markup. Escaping the forward slash is valid JSON and
 * keeps the payload inert.
 */
export function neutraliseClosingScriptTags(json) {
  // Case is preserved: the sequence lives inside a JSON string value, so
  // rewriting "</SCRIPT" as "<\\/script" would change the data as well as
  // neutralising the tag.
  return json.replace(/<\/(script)/gi, (m) => "<\\" + m.slice(1));
}

export function bootstrapJSON(config) {
  return neutraliseClosingScriptTags(JSON.stringify(config ?? {}));
}

/**
 * Assemble the full page.
 *
 * @param {object} o
 * @param {string} o.content     rendered HTML fragment (from the C shim)
 * @param {string} o.themeId
 * @param {string} o.title
 * @param {"light"|"dark"} o.appearance
 * @param {string} o.profile
 * @param {object} o.bootstrap   diffRanges, scrollFraction, …
 */
export function buildPage({
  content,
  themeId = "manuscript",
  title = "Untitled",
  appearance = "light",
  profile = Profile.markdown,
  bootstrap = {},
}) {
  const template = readFileSync(join(SHELL_DIR, "shell.html"), "utf8");
  const baseCSS = readFileSync(join(SHELL_DIR, "base.css"), "utf8");
  const js = shellScript();
  const csp = contentSecurityPolicy(profile, shellScriptHash(js));

  const values = {
    APPEARANCE: appearance,
    CSP: csp,
    TITLE: escapeForHTMLText(title),
    BASE_CSS: baseCSS,
    THEME_CSS: themeCSS(themeId),
    BOOTSTRAP_JSON: bootstrapJSON(bootstrap),
    CONTENT: content,
    SHELL_JS: js,
  };

  return substitute(template, values);
}

/**
 * Single-pass placeholder fill, mirroring AgentiaCore.RenderShell.substitute.
 *
 * Sequential replaces were wrong in both directions: a token could be
 * re-substituted by a later pass if the document contained one, and an unknown
 * token aborted the render. A document about Handlebars or Jinja is an ordinary
 * thing for an agent to write, so unknown tokens pass through as literal text.
 *
 * The replacer function form also avoids "$&" and "$1" inside document content
 * being treated as replacement patterns.
 */
export function substitute(template, values) {
  return template.replace(/\{\{([A-Z_]{1,32})\}\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(values, name) ? values[name] : match
  );
}
