/* Render real server payloads through the real app.js helpers with a tiny DOM
   stub, to catch runtime errors that would silently break the Select page. */
const fs = require("fs");

class Node {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.attrs = {};
    this.className = "";
    this._text = "";
  }
  appendChild(c) {
    this.children.push(c);
    return c;
  }
  replaceChildren(...c) {
    this.children = c.filter((x) => x !== null && x !== undefined);
  }
  setAttribute(k, v) {
    this.attrs[k] = v;
  }
  addEventListener(ev, fn) {
    (this.listeners ||= {})[ev] = fn;
  }
  querySelectorAll() {
    return [];
  }
  set textContent(v) {
    this._text = v;
    this.children = [];
  }
  get textContent() {
    return this._text + this.children.map((c) => c.textContent ?? String(c)).join("");
  }
}

const registry = {};
global.document = {
  createElement: (tag) => new Node(tag),
  createTextNode: (t) => ({ tag: "#text", textContent: String(t), children: [] }),
  querySelector: (sel) => (registry[sel] ||= new Node("div")),
  querySelectorAll: () => [],
};
global.window = { location: { href: "" } };
global.setTimeout = () => 0;
global.clearTimeout = () => {};
global.fetch = async () => {
  throw new Error("no network in this harness");
};
global.confirm = () => true;
global.alert = () => {};

// Load app.js without its DOMContentLoaded bootstrap running fetches.
process.chdir(require("path").join(__dirname, "..", ".."));
let src = fs.readFileSync("static/app.js", "utf8");
src = src.replace(/^"use strict";/, "");
const fn = new Function(
  src + "\nreturn { renderSelectionResult, releaseRow, renderInstanceOptions, el, api };"
);
const app = fn();

/* Collect every button label a render produced, so the wording the owner sees
   is asserted and not just "it did not throw". */
function buttonLabels(node, found = []) {
  if (!node || typeof node !== "object") return found;
  if (node.tag === "button") found.push(node.textContent);
  for (const child of node.children || []) buttonLabels(child, found);
  return found;
}

function describe(node, depth = 0) {
  return node.textContent;
}

let failures = 0;
function tryRender(label, payload) {
  try {
    app.renderSelectionResult(payload);
    const out = registry["#select-result"].textContent;
    console.log(`  PASS ${label} (rendered ${out.length} chars)`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${label}: ${e.constructor.name}: ${e.message}`);
  }
}

const files = process.argv.slice(2);
for (const f of files) {
  if (!fs.existsSync(f)) continue;
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(f, "utf8"));
  } catch {
    continue;
  }
  if (!payload || !payload.candidates) {
    console.log(`  SKIP ${f} (not a selection result)`);
    continue;
  }
  tryRender(f.replace(/.*\//, ""), payload);
}

/* Synthetic edge cases.  A real payload is used when one was passed in, so
   the harness also runs on its own with no e2e output present. */
const sample = {
  media: { title: "Some Movie", year: 2024, media_kind: "movie", media_id: 77 },
  selected: {
    release: {
      id: "r-winner",
      title: "Some.Movie.2024.1080p.WEB-DL.x265-FLUX",
      size_bytes: 6871947674,
      quality: "WEBDL-1080p",
      source: "WEB-DL",
      codec: "x265",
      release_group: "FLUX",
      seeders: 44,
      custom_format_score: 120,
      indexer: "Fake",
    },
    score: 191.5,
    components: [{ component: "preferred_codec", points: 15, detail: "x265 is preferred" }],
  },
  candidates: [],
  rejected: [],
  reason: "best match",
  explanation: ["matches your preference for WEB-DL"],
  conflicts: [],
  method: { kind: "deterministic" },
  llm: null,
  grabbed: false,
  grab_error: null,
  duration_ms: 42,
};
sample.candidates = [sample.selected];
const existing = files.find((f) => fs.existsSync(f));
const base = existing ? JSON.parse(fs.readFileSync(existing, "utf8")) : sample;
tryRender("selected:null + empty candidates", {
  ...base,
  selected: null,
  candidates: [],
  rejected: [],
  reason: "everything was rejected",
  explanation: [],
  conflicts: [],
});
tryRender("missing optional fields", {
  media: { title: "X" },
  selected: null,
  candidates: [],
  rejected: [],
  reason: "r",
  explanation: [],
  conflicts: [],
  method: {},
  grabbed: false,
  grab_error: null,
  duration_ms: 1,
});
tryRender("grab_error present", { ...base, grabbed: false, grab_error: "HTTP 404: not in cache" });

/* Wording and the grab affordances a search result must offer. */
function check(label, fn) {
  try {
    fn();
    console.log(`  PASS ${label}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${label}: ${e.message}`);
  }
}

check("a search result offers Grab selected and Grab this", () => {
  app.renderSelectionResult({ ...base, grabbed: false, grab_error: null });
  const card = registry["#select-result"];
  const labels = buttonLabels(card);
  if (!labels.includes("Grab selected"))
    throw new Error("no Grab selected button: " + JSON.stringify(labels));
  if (!labels.includes("Grab this"))
    throw new Error("no per-candidate Grab this button: " + JSON.stringify(labels));
  const text = card.textContent;
  if (!text.includes("not grabbed yet"))
    throw new Error("a search result must say 'not grabbed yet': " + text.slice(0, 200));
});

check("a grabbed result says grabbed and offers Grab again", () => {
  app.renderSelectionResult({ ...base, grabbed: true, grab_error: null });
  const card = registry["#select-result"];
  const labels = buttonLabels(card);
  if (!labels.includes("Grab again"))
    throw new Error("expected Grab again: " + JSON.stringify(labels));
  const text = card.textContent;
  if (text.includes("not grabbed"))
    throw new Error("a grabbed result must not say 'not grabbed': " + text.slice(0, 200));
});

check("a failed grab keeps the failure wording", () => {
  app.renderSelectionResult({
    ...base,
    grabbed: false,
    grab_error: "HTTP 404: not in cache",
  });
  const text = registry["#select-result"].textContent;
  if (!text.includes("Grab failed: HTTP 404: not in cache"))
    throw new Error("missing grab failure line: " + text.slice(0, 200));
  if (text.includes("not grabbed yet"))
    throw new Error("a failed grab is not a plain search: " + text.slice(0, 200));
});

check("no old wording survives in a result card", () => {
  app.renderSelectionResult({ ...base, grabbed: false, grab_error: null });
  const labels = buttonLabels(registry["#select-result"]);
  for (const gone of ["Preview", "Select & grab", "Grab"]) {
    if (labels.includes(gone)) throw new Error(`stale label ${gone}: ${JSON.stringify(labels)}`);
  }
});

process.exit(failures ? 1 : 0);
