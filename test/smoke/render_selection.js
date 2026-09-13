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

// Synthetic edge cases
const base = JSON.parse(fs.readFileSync(files.find((f) => fs.existsSync(f)), "utf8"));
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

process.exit(failures ? 1 : 0);
