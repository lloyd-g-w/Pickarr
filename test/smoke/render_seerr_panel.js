/* Render the Requests tab's per-request panel through the real app.js
   functions with a tiny DOM stub, so a runtime error in the panel is caught
   without a browser.
   
   Feed it the payloads test/smoke/seerr_ux_e2e.sh leaves in /tmp:

     node test/smoke/render_seerr_panel.js

   It falls back to built-in samples when those files are absent. */
const fs = require("fs");
const path = require("path");

class Node {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.attrs = {};
    this.className = "";
    this.hidden = false;
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
  scrollIntoView() {}
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

process.chdir(path.join(__dirname, "..", ".."));
let src = fs.readFileSync("static/app.js", "utf8");
src = src.replace(/^"use strict";/, "");
const app = new Function(
  src +
    "\nreturn { renderSeerrPanelHeader, renderSeerrTargets, renderSeerrSelection," +
    " renderSeerrRequests, seerrSelectionBody, grabUrlFor, closeSeerrPanel };"
)();

let failures = 0;
function check(label, fn) {
  try {
    fn();
    console.log(`  PASS ${label}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${label}: ${e.constructor.name}: ${e.message}`);
  }
}

function readIfPresent(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

const movieResolve = readIfPresent("/tmp/seerr-ux-resolve41.json") || {
  request: {
    id: 41,
    status: 2,
    status_label: "approved",
    type: "movie",
    is4k: false,
    title: "Some Movie",
    year: 2024,
    seasons: [],
    requested_by: "alice",
    media_status_label: "processing",
    pushed_to_arr: true,
  },
  targets: [
    { instance_id: "radarr", instance_name: "Radarr", app: "radarr", kind: "movie", media_id: 77 },
  ],
};
const tvResolve = readIfPresent("/tmp/seerr-ux-resolve45.json") || {
  request: {
    id: 45,
    status: 2,
    status_label: "approved",
    type: "tv",
    is4k: false,
    title: "Some Show",
    year: 2019,
    seasons: [2],
    requested_by: "alice",
    media_status_label: "processing",
    pushed_to_arr: true,
  },
  targets: [
    {
      instance_id: "sonarr",
      instance_name: "Sonarr",
      app: "sonarr",
      kind: "series",
      series_id: 12,
      seasons: [{ season_number: 2, missing: 2, total: 2, monitored: true }],
    },
  ],
};

check("movie request header", () => app.renderSeerrPanelHeader(movieResolve.request));
check("movie request targets", () => app.renderSeerrTargets(movieResolve));
check("tv request header", () => app.renderSeerrPanelHeader(tvResolve.request, "detail line"));
check("tv request targets (per-season buttons)", () => {
  app.renderSeerrTargets(tvResolve);
  const text = registry["#seerr-panel-targets"].textContent;
  if (!text.includes("Season 2")) throw new Error("no season row rendered: " + text);
  if (!text.includes("Select & grab")) throw new Error("no per-season grab button");
});
check("nothing resolved yet", () =>
  app.renderSeerrTargets({
    request: movieResolve.request,
    targets: [
      {
        instance_id: "radarr",
        instance_name: "Radarr",
        app: "radarr",
        kind: "nothing",
        reason: "Seerr has not pushed this to radarr yet",
      },
    ],
  })
);
check("no targets at all", () => app.renderSeerrTargets({ targets: [], detail: "nothing here" }));

const movieSelect = readIfPresent("/tmp/seerr-ux-preview.json");
if (movieSelect) {
  check("movie selection payload", () => {
    app.renderSeerrSelection(movieSelect);
    const text = registry["#seerr-request-result"].textContent;
    if (!text.includes("Candidates")) throw new Error("no candidate table: " + text.slice(0, 120));
  });
}
const seasonSelect = readIfPresent("/tmp/seerr-ux-season.json");
if (seasonSelect) {
  check("season selection payload", () => app.renderSeerrSelection(seasonSelect));
}
const seriesSelect = readIfPresent("/tmp/seerr-ux-series.json");
if (seriesSelect) {
  check("whole-series payload", () => app.renderSeerrSelection(seriesSelect));
}
check("empty selection payload", () => app.renderSeerrSelection({ instance_id: "radarr" }));
check("episode-fallback payload", () =>
  app.renderSeerrSelection({
    instance_id: "sonarr",
    kind: "episodes",
    selections: seasonSelect ? [seasonSelect.selection] : [],
  })
);

check("request rows offer preview and grab", () => {
  app.renderSeerrRequests("#seerr-processing", { results: [movieResolve.request] }, "processing");
  const text = registry["#seerr-processing"].textContent;
  for (const label of ["Preview", "Select & grab", "Fulfil now"]) {
    if (!text.includes(label)) throw new Error(`missing ${label}: ${text}`);
  }
});
check("pending rows offer approve & select", () => {
  app.renderSeerrRequests(
    "#seerr-pending",
    { results: [Object.assign({}, movieResolve.request, { status: 1, status_label: "pending" })] },
    "pending"
  );
  const text = registry["#seerr-pending"].textContent;
  for (const label of ["Approve", "Approve & select", "Decline"]) {
    if (!text.includes(label)) throw new Error(`missing ${label}: ${text}`);
  }
});

check("a season pack is grabbed through the season route", () => {
  const url = app.grabUrlFor("sonarr", {
    media_kind: "season",
    media_id: 12,
    series_id: 12,
    season_number: 2,
  });
  if (url !== "/api/grab/sonarr/season/12/2") throw new Error(url);
});
check("an episode is grabbed through the media route", () => {
  const url = app.grabUrlFor("sonarr", { media_kind: "episode", media_id: 5150 });
  if (url !== "/api/grab/sonarr/5150") throw new Error(url);
});

console.log(failures === 0 ? "\nALL PANEL RENDER CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
