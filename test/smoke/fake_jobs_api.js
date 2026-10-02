/* The queue UI end to end, without a browser or a server: the real app.js
   runs against a tiny DOM stub and an in-memory jobs/events backend that
   implements the HTTP API of docs/ARCHITECTURE.md (POST/GET /api/jobs,
   cancel, retry, DELETE finished, GET /api/events).

     node test/smoke/fake_jobs_api.js

   Timers never fire here (setTimeout is a no-op), so the test drives the
   polling by calling tickJobWatchers / pollQueueBadge / loadQueue /
   pollEvents itself, and advances jobs through the fake backend. */
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

/* ------------------------------------------------------------------ */
/* DOM stub                                                            */
/* ------------------------------------------------------------------ */

class Node {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.attrs = {};
    this.className = "";
    this.hidden = false;
    this.disabled = false;
    this.dataset = {};
    this.listeners = {};
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
    (this.listeners[ev] ||= []).push(fn);
  }
  scrollIntoView() {}
  select() {}
  querySelectorAll() {
    return [];
  }
  querySelector(sel) {
    const m = /^\[data-key="(.+)"\]$/.exec(sel);
    if (!m) return null;
    return findNode(this, (n) => n.dataset && n.dataset.key === m[1]);
  }
  get value() {
    return this._value !== undefined ? this._value : this.attrs.value;
  }
  set value(v) {
    this._value = v;
  }
  set textContent(v) {
    this._text = String(v);
    this.children = [];
  }
  get textContent() {
    return this._text + this.children.map((c) => (c && c.textContent !== undefined ? c.textContent : String(c))).join("");
  }
}

function findNode(root, pred) {
  if (!root || typeof root !== "object") return null;
  if (pred(root)) return root;
  for (const c of root.children || []) {
    const hit = findNode(c, pred);
    if (hit) return hit;
  }
  return null;
}

function findAll(root, pred, out = []) {
  if (!root || typeof root !== "object") return out;
  if (pred(root)) out.push(root);
  for (const c of root.children || []) findAll(c, pred, out);
  return out;
}

const buttonsIn = (root) => findAll(root, (n) => n.tag === "button");
const buttonLabels = (root) => buttonsIn(root).map((b) => b.textContent);
function button(root, label) {
  const b = buttonsIn(root).find((x) => x.textContent === label);
  if (!b) throw new Error(`no "${label}" button among ${JSON.stringify(buttonLabels(root))}`);
  return b;
}
function fire(node, event, arg) {
  for (const fn of (node.listeners && node.listeners[event]) || []) fn(arg || { preventDefault() {} });
}
const click = (node) => fire(node, "click");
const rowsOf = (root) => findAll(root, (n) => n.tag === "tbody").flatMap((t) => t.children);

const registry = {};
const $ = (sel) => (registry[sel] ||= new Node("div"));
global.document = {
  createElement: (tag) => new Node(tag),
  createTextNode: (t) => ({ tag: "#text", textContent: String(t), children: [] }),
  querySelector: $,
  querySelectorAll: () => [],
  hidden: false,
};
global.window = { location: { href: "" } };
global.location = { host: "pickarr:8484", protocol: "http:" };
/* A fake clock: timers are recorded and only run when a check runs them. */
const timers = [];
global.setTimeout = (fn, ms) => {
  timers.push({ fn, ms });
  return timers.length;
};
global.clearTimeout = () => {};
let confirms = 0;
global.confirm = () => {
  confirms++;
  return true;
};
global.alert = () => {};

/* ------------------------------------------------------------------ */
/* in-memory backend                                                   */
/* ------------------------------------------------------------------ */

const FINISHED = new Set(["succeeded", "failed", "cancelled"]);
const KINDS = new Set([
  "search",
  "grab_best",
  "grab_release",
  "seerr_select",
  "seerr_fulfil",
  "automatic_pass",
  "seerr_pass",
  "seerr_webhook",
]);
const LEVELS = { info: 0, warn: 1, error: 2 };

const backend = {
  jobs: [],
  events: [],
  nextJob: 1,
  nextEvent: 1,
  requests: [],
  reset() {
    this.jobs = [];
    this.events = [];
    this.requests = [];
  },
  now() {
    return new Date().toISOString().replace(/\.\d+Z$/, "Z");
  },
  emit(type, message, extra) {
    const e = Object.assign(
      {
        id: this.nextEvent++,
        ts: this.now(),
        level: "info",
        type,
        message,
        job_id: null,
        instance_id: null,
        media: null,
        data: {},
      },
      extra || {}
    );
    this.events.push(e);
    return e;
  },
  view(job, withResult) {
    const out = Object.assign({}, job);
    if (job.status === "queued") {
      const queued = this.jobs.filter((j) => j.status === "queued").sort((a, b) => a.id - b.id);
      out.position = queued.findIndex((j) => j.id === job.id) + 1;
    } else out.position = null;
    if (!withResult) delete out.result;
    return out;
  },
  counts() {
    const c = { queued: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0 };
    for (const j of this.jobs) c[j.status]++;
    return c;
  },
  add(kind, params, extra) {
    const job = Object.assign(
      {
        id: this.nextJob++,
        kind,
        status: "queued",
        label: `${kind} · ${JSON.stringify(params.target || params.request_id || "")}`,
        source: "ui",
        instance_id: params.instance_id || null,
        params,
        created_at: this.now(),
        started_at: null,
        finished_at: null,
        duration_ms: null,
        progress: null,
        attempt: 1,
        retry_of: null,
        error: null,
        result: null,
      },
      extra || {}
    );
    this.jobs.push(job);
    this.emit("job.queued", `queued ${job.label}`, { job_id: job.id });
    return job;
  },
  job(id) {
    const j = this.jobs.find((x) => x.id === id);
    if (!j) throw new Error("no job " + id);
    return j;
  },
  start(id, progress) {
    const j = this.job(id);
    j.status = "running";
    j.started_at = this.now();
    j.progress = progress || null;
  },
  finish(id, result) {
    const j = this.job(id);
    j.status = "succeeded";
    j.finished_at = this.now();
    j.duration_ms = 4200;
    j.result = result;
    j.progress = null;
  },
  fail(id, error) {
    const j = this.job(id);
    j.status = "failed";
    j.finished_at = this.now();
    j.duration_ms = 300;
    j.error = error;
  },
  route(method, url, body) {
    const u = new URL(url, "http://pickarr");
    const p = u.pathname;
    const q = u.searchParams;
    let m;
    if (method === "POST" && p === "/api/jobs") {
      if (!KINDS.has(body.kind)) return [400, { error: `unknown job kind ${body.kind}` }];
      const key = JSON.stringify([body.kind, body.params]);
      const dup = this.jobs.find(
        (j) => !FINISHED.has(j.status) && JSON.stringify([j.kind, j.params]) === key
      );
      if (dup) return [202, { job: this.view(dup) }];
      const job = this.add(body.kind, body.params || {}, { source: body.source || "api" });
      return [202, { job: this.view(job) }];
    }
    if (method === "GET" && p === "/api/jobs") {
      const statuses = q.get("status") ? q.get("status").split(",") : null;
      const limit = parseInt(q.get("limit") || "100", 10);
      const list = this.jobs
        .filter((j) => !statuses || statuses.includes(j.status))
        .filter((j) => !q.get("kind") || j.kind === q.get("kind"))
        .sort((a, b) => b.id - a.id)
        .slice(0, limit)
        .map((j) => this.view(j, q.get("include") === "result"));
      return [200, { jobs: list, counts: this.counts() }];
    }
    if (method === "DELETE" && p === "/api/jobs") {
      if (q.get("status") !== "finished") return [400, { error: "status=finished required" }];
      const before = this.jobs.length;
      this.jobs = this.jobs.filter((j) => !FINISHED.has(j.status));
      return [200, { cleared: before - this.jobs.length }];
    }
    if ((m = /^\/api\/jobs\/(\d+)$/.exec(p)) && method === "GET") {
      const j = this.jobs.find((x) => x.id === Number(m[1]));
      return j ? [200, { job: this.view(j, true) }] : [404, { error: "no such job" }];
    }
    if ((m = /^\/api\/jobs\/(\d+)\/cancel$/.exec(p)) && method === "POST") {
      const j = this.jobs.find((x) => x.id === Number(m[1]));
      if (!j) return [404, { error: "no such job" }];
      if (FINISHED.has(j.status)) return [409, { error: "already finished" }];
      j.status = "cancelled";
      j.finished_at = this.now();
      return [200, { job: this.view(j) }];
    }
    if ((m = /^\/api\/jobs\/(\d+)\/retry$/.exec(p)) && method === "POST") {
      const j = this.jobs.find((x) => x.id === Number(m[1]));
      if (!j) return [404, { error: "no such job" }];
      if (!(j.status === "failed" || j.status === "cancelled")) return [409, { error: "not retryable" }];
      const fresh = this.add(j.kind, j.params, { source: "ui", retry_of: j.id, attempt: j.attempt + 1 });
      return [202, { job: this.view(fresh) }];
    }
    if (method === "GET" && p === "/api/events") {
      const since = q.has("since_id") ? parseInt(q.get("since_id"), 10) : null;
      const limit = parseInt(q.get("limit") || "200", 10);
      const minLevel = LEVELS[q.get("level") || "info"];
      const text = (q.get("q") || "").toLowerCase();
      let list = this.events
        .filter((e) => since === null || e.id > since)
        .filter((e) => !q.get("type") || e.type.startsWith(q.get("type")))
        .filter((e) => LEVELS[e.level] >= minLevel)
        .filter((e) => !q.get("job_id") || e.job_id === Number(q.get("job_id")))
        .filter((e) => !text || e.message.toLowerCase().includes(text));
      list = since === null ? list.slice(-limit) : list.slice(0, limit);
      const last = this.events.length ? this.events[this.events.length - 1].id : 0;
      return [200, { events: list, last_id: last }];
    }
    if (method === "GET" && p === "/api/status") return [200, { version: "test", instances: 2 }];
    if (method === "GET" && p === "/api/config") return [200, config];
    if (method === "PUT" && p === "/api/config") {
      Object.assign(config, body);
      return [200, config];
    }
    if (method === "GET" && p === "/api/history") return [200, []];
    if (method === "GET" && p === "/api/logs") return [200, []];
    if (method === "GET" && p === "/api/security") return [200, { username: "admin", api_key: "k" }];
    if (method === "GET" && p === "/api/automatic/status") return [200, { enabled: false }];
    if (method === "GET" && p === "/api/seerr/status") return [200, { enabled: true, configured: true }];
    if (method === "GET" && p === "/api/seerr/requests") return [200, { results: [] }];
    if ((m = /^\/api\/seerr\/requests\/(\d+)\/approve$/.exec(p)) && method === "POST") {
      /* As the server does: approving queues a seerr_fulfil job. */
      const job = this.add("seerr_fulfil", { request_id: Number(m[1]) }, { label: `Seerr request #${m[1]} · fulfil` });
      return [200, { ok: true, action: "approved", request: { id: Number(m[1]) }, job_id: job.id }];
    }
    if ((m = /^\/api\/seerr\/requests\/(\d+)\/resolve$/.exec(p)) && method === "POST")
      return [
        200,
        {
          /* request 43 is still pending in Seerr */
          request: Object.assign({}, seerrRequest, { id: Number(m[1]), status: Number(m[1]) === 43 ? 1 : 2 }),
          targets: [{ instance_id: "radarr", instance_name: "Radarr", app: "radarr", kind: "movie", media_id: 77 }],
        },
      ];
    return [404, { error: `no fake route for ${method} ${p}` }];
  },
};

const config = {
  instances: [
    { id: "radarr", name: "Radarr", app: "radarr", url: "http://radarr:7878", enabled: true },
    { id: "sonarr", name: "Sonarr", app: "sonarr", url: "http://sonarr:8989", enabled: true },
  ],
  llm: { enabled: true },
  automatic: {},
  seasons: {},
  network: {},
  hard_rules: {},
  preferences: {},
  weights: {},
  seerr: { enabled: true },
  queue: { workers: 3, per_instance: 1, keep_finished: 500 },
};

const seerrRequest = {
  id: 41,
  status: 2,
  status_label: "approved",
  type: "movie",
  title: "Some Movie",
  year: 2024,
  seasons: [],
  requested_by: "alice",
  media_status_label: "processing",
  pushed_to_arr: true,
};

global.fetch = async (url, options) => {
  const o = options || {};
  const method = (o.method || "GET").toUpperCase();
  const body = o.body ? JSON.parse(o.body) : undefined;
  backend.requests.push({ method, url, body });
  const [status, json] = backend.route(method, url, body);
  return {
    status,
    ok: status >= 200 && status < 300,
    text: async () => JSON.stringify(json),
  };
};

/* ------------------------------------------------------------------ */
/* load app.js                                                         */
/* ------------------------------------------------------------------ */

process.chdir(path.join(__dirname, "..", ".."));
let src = fs.readFileSync("static/app.js", "utf8");
src = src.replace(/^"use strict";/, "");
src = src.replace(/^main\(\);$/m, "").replace(/^wireSeerr\(\);$/m, "");
const app = new Function(
  src +
    `
return {
  state, el, main, wireSeerr, showTab, runSelection, runSeasonSelection, runSeriesSelection,
  tickJobWatchers, pollQueueBadge, loadQueue, setQueueFilter, queueView, loadEvents, pollEvents,
  setEventType, toggleEventsPause, eventsView, openJobDrawer, loadDashboardQueue,
  loadDashboardActivity, openSeerrRequest, renderSelectionResult, fmtDuration, jobWatchers,
  uiJobKeys, pollLoops, startBackgroundPolling, watchJob, seerrAction, stripStatusPrefix,
};`
)();

const flush = async (n = 40) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
};
const posts = (prefix) => backend.requests.filter((r) => r.method === "POST" && r.url.startsWith(prefix));
const lastJobPost = () => {
  const list = posts("/api/jobs").filter((r) => r.url === "/api/jobs");
  return list[list.length - 1];
};
const gets = (prefix) => backend.requests.filter((r) => r.method === "GET" && r.url.startsWith(prefix));

/* ------------------------------------------------------------------ */
/* sample results                                                      */
/* ------------------------------------------------------------------ */

function selection(media, overrides) {
  const winner = {
    release: {
      id: "r-winner",
      guid: "magnet:?xt=urn:btih:ABC",
      indexer_id: 4,
      title: "Some.Movie.2024.1080p.WEB-DL.x265-FLUX",
      size_bytes: 6871947674,
      quality: "WEBDL-1080p",
      indexer: "Fake",
    },
    score: 191.5,
    components: [{ component: "preferred_codec", points: 15, detail: "x265 is preferred" }],
  };
  const other = {
    release: {
      id: "r-other",
      guid: "g-other",
      indexer_id: 7,
      title: "Some.Movie.2024.2160p.REMUX-GRP",
      size_bytes: 60871947674,
    },
    score: 120,
    components: [],
  };
  return Object.assign(
    {
      media,
      selected: winner,
      candidates: [winner, other],
      rejected: [],
      reason: "best match",
      explanation: ["matches your preference for WEB-DL"],
      conflicts: [],
      method: { kind: "deterministic" },
      llm: null,
      grabbed: false,
      grab_error: null,
      grab_notes: [],
      duration_ms: 4100,
    },
    overrides || {}
  );
}

const movieMedia = { title: "Some Movie", year: 2024, media_kind: "movie", media_id: 77, app: "radarr" };

/* ------------------------------------------------------------------ */
/* checks                                                              */
/* ------------------------------------------------------------------ */

let failures = 0;
async function check(label, fn) {
  try {
    await fn();
    console.log(`  PASS ${label}`);
  } catch (e) {
    failures++;
    console.log(`  FAIL ${label}: ${e.stack.split("\n").slice(0, 3).join(" | ")}`);
  }
}

(async () => {
  await app.main();
  app.wireSeerr();
  await flush();

  await check("startup loads the queue form from config.queue", async () => {
    const form = $("#queue-form");
    const workers = form.querySelector('[data-key="workers"]');
    assert.ok(workers, "no workers field");
    assert.strictEqual(Number(workers.value), 3);
  });

  /* --- badge -------------------------------------------------------- */
  await check("badge shows running and queued counts", async () => {
    backend.reset();
    for (let i = 0; i < 5; i++) backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 900 + i } });
    backend.start(1);
    backend.start(2);
    await app.pollQueueBadge();
    const badge = $("#queue-badge");
    assert.strictEqual(badge.textContent, "2 running · 3 queued");
    assert.strictEqual(badge.hidden, false);
    assert.ok(gets("/api/jobs?status=queued,running").length > 0, "badge must poll active jobs");
  });

  await check("badge hides when nothing is active", async () => {
    for (const j of backend.jobs) j.status = "succeeded";
    await app.pollQueueBadge();
    assert.strictEqual($("#queue-badge").hidden, true);
  });

  /* --- Search page: search job --------------------------------------- */
  backend.reset();
  $("#select-instance").value = "radarr";
  $("#select-use-ai").checked = true;
  $("#select-instruction").value = "  pick small  ";
  const searchButton = app.el("button", { class: "small" }, "Search");
  let searchJobId;

  await check("Search enqueues a search job with the contract params", async () => {
    app.runSelection(false, 77, searchButton);
    await flush();
    const post = lastJobPost();
    assert.ok(post, "no POST /api/jobs");
    assert.deepStrictEqual(post.body, {
      kind: "search",
      params: {
        instance_id: "radarr",
        target: { kind: "movie", media_id: 77 },
        use_ai: true,
        instruction: "pick small",
      },
      source: "ui",
    });
    searchJobId = backend.jobs[backend.jobs.length - 1].id;
  });

  await check("the status line says queued with the position, the button is busy", async () => {
    const line = $("#select-status").textContent;
    assert.ok(line.includes(`#${searchJobId} queued (position 1)`), line);
    assert.strictEqual(searchButton.disabled, true);
    assert.strictEqual(searchButton.textContent, "queued…");
    assert.ok($("#toast").textContent.includes(`Queued #${searchJobId}`), $("#toast").textContent);
    assert.ok(buttonLabels($("#toast")).includes("View queue"));
  });

  await check("a double click does not queue twice", async () => {
    const before = posts("/api/jobs").length;
    app.runSelection(false, 77, searchButton);
    await flush();
    assert.strictEqual(posts("/api/jobs").length, before);
    assert.ok($("#toast").textContent.includes("Already queued"), $("#toast").textContent);
  });

  await check("running: the progress text replaces the status", async () => {
    backend.start(searchJobId, "searching Radarr (4 indexers)…");
    await app.tickJobWatchers();
    assert.ok($("#select-status").textContent.includes("searching Radarr (4 indexers)…"));
    assert.strictEqual(searchButton.textContent, "running…");
  });

  await check("done: the result is drawn in place with the grab buttons", async () => {
    backend.finish(searchJobId, selection(movieMedia));
    await app.tickJobWatchers();
    assert.ok($("#select-status").textContent.includes(`#${searchJobId} done in 4.2 s`), $("#select-status").textContent);
    const text = $("#select-result").textContent;
    assert.ok(text.includes("Candidates (2)"), text.slice(0, 200));
    const labels = buttonLabels($("#select-result"));
    assert.ok(labels.includes("Grab selected") && labels.includes("Grab this"), JSON.stringify(labels));
    assert.strictEqual(searchButton.disabled, false);
    assert.strictEqual(searchButton.textContent, "Search");
    assert.strictEqual(app.jobWatchers.size, 0, "finished jobs must stop being polled");
  });

  /* --- grab_release from the result card ----------------------------- */
  let grabJobId;
  await check("Grab this enqueues grab_release with target, release id, guid and indexer", async () => {
    const other = buttonsIn($("#select-result")).filter((b) => b.textContent === "Grab this")[1];
    click(other);
    await flush();
    assert.deepStrictEqual(lastJobPost().body, {
      kind: "grab_release",
      params: {
        instance_id: "radarr",
        target: { kind: "movie", media_id: 77 },
        release_id: "r-other",
        guid: "g-other",
        indexer_id: 7,
      },
      source: "ui",
    });
    grabJobId = backend.jobs[backend.jobs.length - 1].id;
    assert.strictEqual(other.textContent, "queued…");
  });

  await check("a finished grab redraws the card as grabbed", async () => {
    backend.start(grabJobId);
    backend.finish(
      grabJobId,
      selection(movieMedia, { grabbed: true, grab_notes: ["grabbed directly", "in the download queue via qBittorrent"] })
    );
    await app.tickJobWatchers();
    const text = $("#select-result").textContent;
    assert.ok(text.includes("grabbed"), text.slice(0, 200));
    assert.ok(buttonLabels($("#select-result")).includes("Grab again"));
    assert.ok($("#select-status").textContent.includes("grabbed · grabbed directly"), $("#select-status").textContent);
  });

  await check("Grab selected on the winner enqueues the winner's guid", async () => {
    click(button($("#select-result"), "Grab again"));
    await flush();
    const body = lastJobPost().body;
    assert.strictEqual(body.kind, "grab_release");
    assert.strictEqual(body.params.release_id, "r-winner");
    assert.strictEqual(body.params.guid, "magnet:?xt=urn:btih:ABC");
    assert.strictEqual(body.params.indexer_id, 4);
    backend.finish(backend.jobs[backend.jobs.length - 1].id, selection(movieMedia, { grabbed: true }));
    await app.tickJobWatchers();
  });

  /* --- other targets --------------------------------------------------- */
  await check("Grab on a Sonarr episode enqueues grab_best for the episode", async () => {
    $("#select-instance").value = "sonarr";
    $("#select-instruction").value = "";
    app.runSelection(true, 5150);
    await flush();
    assert.deepStrictEqual(lastJobPost().body.params, {
      instance_id: "sonarr",
      target: { kind: "episode", media_id: 5150 },
      use_ai: true,
    });
    assert.strictEqual(lastJobPost().body.kind, "grab_best");
  });

  let seasonJobId;
  await check("a season row enqueues a season target", async () => {
    app.runSeasonSelection(false, 12, 2);
    await flush();
    assert.deepStrictEqual(lastJobPost().body.params.target, { kind: "season", series_id: 12, season_number: 2 });
    seasonJobId = backend.jobs[backend.jobs.length - 1].id;
  });

  await check("a season pack from the result is grabbed with the season target", async () => {
    const seasonMedia = { title: "Some Show", media_kind: "season", media_id: 12, series_id: 12, season_number: 2, app: "sonarr" };
    backend.finish(seasonJobId, selection(seasonMedia));
    await app.tickJobWatchers();
    click(button($("#select-result"), "Grab selected"));
    await flush();
    assert.deepStrictEqual(lastJobPost().body.params.target, { kind: "season", series_id: 12, season_number: 2 });
    assert.strictEqual(lastJobPost().body.params.instance_id, "sonarr");
  });

  await check("whole series / ticked seasons enqueue a series target", async () => {
    app.runSeriesSelection(false, 12, [1, 2]);
    await flush();
    assert.deepStrictEqual(lastJobPost().body.params.target, { kind: "series", series_id: 12, seasons: [1, 2] });
    const id = backend.jobs[backend.jobs.length - 1].id;
    backend.finish(id, {
      series: { title: "Some Show", app: "sonarr" },
      summary: { seasons: 2, selections: 2, selected: 1, grabbed: 0 },
      seasons: [
        { season_number: 1, missing: 1, total: 4, outcome: { kind: "skipped", reason: "1 of 4 missing" } },
        {
          season_number: 2,
          missing: 2,
          total: 2,
          outcome: { kind: "pack", selection: selection({ title: "Some Show", media_kind: "season", media_id: 12, series_id: 12, season_number: 2 }) },
        },
      ],
    });
    await app.tickJobWatchers();
    assert.ok($("#select-result").textContent.includes("season pack"), $("#select-result").textContent.slice(0, 200));
    assert.ok($("#select-status").textContent.includes("2 season(s), 0 grabbed"), $("#select-status").textContent);
  });

  await check("an older search finishing after a newer one does not overwrite the page", async () => {
    $("#select-instance").value = "radarr";
    app.runSelection(false, 501);
    await flush();
    const older = backend.jobs[backend.jobs.length - 1].id;
    app.runSelection(false, 502);
    await flush();
    const newer = backend.jobs[backend.jobs.length - 1].id;
    backend.finish(older, selection(Object.assign({}, movieMedia, { title: "Older Movie", media_id: 501 })));
    await app.tickJobWatchers();
    assert.ok(!$("#select-result").textContent.includes("Older Movie"), "the older result was drawn");
    backend.finish(newer, selection(Object.assign({}, movieMedia, { title: "Newer Movie", media_id: 502 })));
    await app.tickJobWatchers();
    assert.ok($("#select-result").textContent.includes("Newer Movie"));
  });

  await check("a failed job shows the error inline with Retry, which queues a retry", async () => {
    app.runSelection(false, 600);
    await flush();
    const id = backend.jobs[backend.jobs.length - 1].id;
    backend.fail(id, "HTTP 502 · Radarr: release search failed: timed out");
    await app.tickJobWatchers();
    const status = $("#select-status");
    assert.ok(status.textContent.includes(`#${id} failed: HTTP 502`), status.textContent);
    assert.ok(status.className.includes("bad"));
    click(button(status, "Retry"));
    await flush();
    assert.ok(posts(`/api/jobs/${id}/retry`).length === 1, "no retry POST");
    const fresh = backend.jobs[backend.jobs.length - 1];
    assert.strictEqual(fresh.retry_of, id);
    assert.ok($("#select-status").textContent.includes(`#${fresh.id} queued`), $("#select-status").textContent);
    backend.finish(fresh.id, selection(Object.assign({}, movieMedia, { title: "Retried Movie" })));
    await app.tickJobWatchers();
    assert.ok($("#select-result").textContent.includes("Retried Movie"));
  });

  await check("a rejected enqueue (400) says not queued and frees the button", async () => {
    const b = app.el("button", {}, "Search");
    const realRoute = backend.route;
    backend.route = (method, url, body) =>
      method === "POST" && url === "/api/jobs" ? [400, { error: "target.media_id must be positive" }] : realRoute.call(backend, method, url, body);
    app.runSelection(false, 700, b);
    await flush();
    backend.route = realRoute;
    assert.ok($("#select-status").textContent.includes("not queued: HTTP 400 · target.media_id must be positive"), $("#select-status").textContent);
    assert.strictEqual(b.disabled, false);
    assert.strictEqual(b.textContent, "Search");
  });

  /* --- Queue tab ------------------------------------------------------ */
  backend.reset();
  const qa = backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 1 } });
  const qb = backend.add("grab_release", { instance_id: "radarr", target: { kind: "movie", media_id: 1 }, release_id: "x" });
  const qc = backend.add("seerr_pass", {});
  const qd = backend.add("grab_best", { instance_id: "sonarr", target: { kind: "episode", media_id: 2 } });
  const qe = backend.add("automatic_pass", {}, { source: "automatic" });
  const qf = backend.add("search", { instance_id: "sonarr", target: { kind: "episode", media_id: 3 } });
  backend.start(qb.id, "grabbing…");
  backend.finish(qc.id, { approved: 1, fulfilled: 2, dry_run: false, duration_ms: 1500, results: [] });
  backend.fail(qd.id, "HTTP 409: Unable to add release");
  backend.finish(qe.id, { instances: 2, duration_ms: 900, dry_run: true, results: [{ instance: "Radarr", media: "X", selected: "X.2024", grabbed: false }] });
  qf.status = "cancelled";
  backend.finish(qa.id, selection(movieMedia));
  const qg = backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 10 } });
  const qh = backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 11 } });

  await check("Queue tab lists every job newest first with status pills", async () => {
    app.showTab("queue");
    await flush();
    const rows = rowsOf($("#queue-list"));
    assert.strictEqual(rows.length, 8);
    const ids = rows.map((r) => r.children[0].textContent);
    assert.deepStrictEqual(ids, [qh, qg, qf, qe, qd, qc, qb, qa].map((j) => `#${j.id}`));
    assert.ok(rows[0].textContent.includes("queued · #2 in line"), rows[0].textContent);
    assert.ok(rows[1].textContent.includes("queued · #1 in line"), rows[1].textContent);
    const failed = rows.find((r) => r.children[0].textContent === `#${qd.id}`);
    assert.ok(failed.className.includes("job-failed"));
    assert.ok(failed.textContent.includes("HTTP 409: Unable to add release"));
    const cancelled = rows.find((r) => r.children[0].textContent === `#${qf.id}`);
    assert.ok(cancelled.className.includes("job-cancelled"));
    const running = rows.find((r) => r.children[0].textContent === `#${qb.id}`);
    assert.ok(running.textContent.includes("grabbing…"));
  });

  await check("row actions: View always, Cancel while active, Retry once failed/cancelled", async () => {
    const rows = rowsOf($("#queue-list"));
    const byId = (id) => rows.find((r) => r.children[0].textContent === `#${id}`);
    assert.deepStrictEqual(buttonLabels(byId(qb.id)), ["View", "Cancel"]);
    assert.deepStrictEqual(buttonLabels(byId(qg.id)), ["View", "Cancel"]);
    assert.deepStrictEqual(buttonLabels(byId(qd.id)), ["View", "Retry"]);
    assert.deepStrictEqual(buttonLabels(byId(qf.id)), ["View", "Retry"]);
    assert.deepStrictEqual(buttonLabels(byId(qa.id)), ["View"]);
  });

  await check("Cancel posts to /api/jobs/:id/cancel and reloads", async () => {
    const row = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${qg.id}`);
    const before = gets("/api/jobs?limit=200").length;
    click(button(row, "Cancel"));
    await flush();
    assert.strictEqual(posts(`/api/jobs/${qg.id}/cancel`).length, 1);
    assert.ok(gets("/api/jobs?limit=200").length > before, "no reload after cancel");
    const again = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${qg.id}`);
    assert.ok(again.className.includes("job-cancelled"), again.className);
  });

  await check("Retry posts to /api/jobs/:id/retry and the new job appears", async () => {
    const row = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${qd.id}`);
    click(button(row, "Retry"));
    await flush();
    assert.strictEqual(posts(`/api/jobs/${qd.id}/retry`).length, 1);
    const top = rowsOf($("#queue-list"))[0];
    assert.ok(top.textContent.includes(`retry of #${qd.id}`), top.textContent);
  });

  await check("filters ask the server for the right statuses", async () => {
    await app.setQueueFilter("failed");
    await flush();
    assert.ok(gets("/api/jobs?limit=200&status=failed%2Ccancelled").length >= 1, JSON.stringify(gets("/api/jobs?limit=200").map((r) => r.url)));
    const rows = rowsOf($("#queue-list"));
    assert.ok(rows.every((r) => /job-(failed|cancelled)/.test(r.className)), rows.map((r) => r.className).join());
    await app.setQueueFilter("active");
    assert.ok(gets("/api/jobs?limit=200&status=queued%2Crunning").length >= 1);
    await app.setQueueFilter("succeeded");
    assert.ok(rowsOf($("#queue-list")).every((r) => r.className.includes("job-succeeded")));
    const chips = buttonLabels($("#queue-filters"));
    assert.ok(chips.some((c) => c.startsWith("Succeeded (")), JSON.stringify(chips));
    await app.setQueueFilter("all");
  });

  await check("View opens the drawer with the job's result and working Grab buttons", async () => {
    const row = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${qa.id}`);
    click(button(row, "View"));
    await flush();
    assert.strictEqual($("#job-drawer").hidden, false);
    assert.ok($("#job-drawer-title").textContent.includes(`Job #${qa.id}`));
    assert.ok($("#job-drawer-meta").textContent.includes("succeeded"));
    const body = $("#job-drawer-body");
    assert.ok(body.textContent.includes("Candidates (2)"), body.textContent.slice(0, 200));
    click(button(body, "Grab selected"));
    await flush();
    const post = lastJobPost().body;
    assert.strictEqual(post.kind, "grab_release");
    assert.strictEqual(post.params.instance_id, "radarr");
    assert.strictEqual(post.params.release_id, "r-winner");
    assert.ok($("#job-drawer-status").textContent.includes("queued"), $("#job-drawer-status").textContent);
  });

  await check("the drawer of a failed job offers Retry and then follows the new job", async () => {
    await app.openJobDrawer(qd.id);
    await flush();
    assert.ok($("#job-drawer-meta").textContent.includes("HTTP 409: Unable to add release"));
    const retries = posts(`/api/jobs/${qd.id}/retry`).length;
    click(button($("#job-drawer-meta"), "Retry"));
    await flush();
    assert.strictEqual(posts(`/api/jobs/${qd.id}/retry`).length, retries + 1);
    const fresh = backend.jobs[backend.jobs.length - 1];
    assert.ok($("#job-drawer-title").textContent.includes(`Job #${fresh.id}`), $("#job-drawer-title").textContent);
    assert.ok($("#job-drawer-meta").textContent.includes(`#${qd.id}`), "retry_of not shown");
  });

  await check("the drawer draws pass summaries", async () => {
    await app.openJobDrawer(qe.id);
    await flush();
    const text = $("#job-drawer-body").textContent;
    assert.ok(text.includes("2 instance(s)") && text.includes("dry run"), text.slice(0, 200));
    assert.ok(text.includes("X.2024"), text.slice(0, 300));
    await app.openJobDrawer(qc.id);
    await flush();
    assert.ok($("#job-drawer-body").textContent.includes("1 approved, 2 auto-grabbed"));
  });

  await check("Clear finished sends DELETE /api/jobs?status=finished", async () => {
    click($("#queue-clear"));
    await flush();
    assert.strictEqual(backend.requests.filter((r) => r.method === "DELETE" && r.url === "/api/jobs?status=finished").length, 1);
    assert.ok($("#queue-result").textContent.startsWith("cleared "), $("#queue-result").textContent);
    assert.ok(rowsOf($("#queue-list")).every((r) => /job-(queued|running)/.test(r.className)));
  });

  /* --- Events tab ----------------------------------------------------- */
  backend.reset();
  backend.emit("job.queued", "queued Search · Some Movie", { job_id: 3 });
  backend.emit("search.done", "Some Movie: 12 candidates", { instance_id: "radarr", media: "Some Movie (2024)", job_id: 3 });
  backend.emit("grab.failed", "Radarr refused the grab", { level: "error", instance_id: "radarr", job_id: 3 });
  backend.emit("seerr.approved", "approved request #41 The Matrix");
  backend.emit("log.warn", "indexer slow", { level: "warn" });

  await check("Events tab loads the newest events first", async () => {
    app.showTab("events");
    await flush();
    assert.ok(gets("/api/events?limit=200").length >= 1);
    const rows = rowsOf($("#events-list"));
    assert.strictEqual(rows.length, 5);
    assert.ok(rows[0].textContent.includes("indexer slow"));
    assert.ok(rows[4].textContent.includes("queued Search"));
    assert.ok(rows[2].className.includes("event-error"));
    assert.ok($("#events-summary").textContent.includes("5 event(s)"));
  });

  await check("level, type and text filters go to the server", async () => {
    $("#events-level").value = "warn";
    fire($("#events-level"), "change");
    await flush();
    assert.ok(gets("/api/events?limit=200&level=warn").length === 1, JSON.stringify(gets("/api/events").map((r) => r.url)));
    assert.strictEqual(rowsOf($("#events-list")).length, 2);
    $("#events-level").value = "info";
    await app.setEventType("grab");
    assert.ok(gets("/api/events?limit=200&type=grab").length === 1);
    assert.strictEqual(rowsOf($("#events-list")).length, 1);
    const chips = $("#events-types");
    assert.ok(findNode(chips, (n) => n.tag === "button" && n.textContent === "grab" && n.className.includes("active")));
    await app.setEventType("");
    $("#events-q").value = "Matrix";
    fire($("#events-q"), "keydown", { key: "Enter", preventDefault() {} });
    await flush();
    assert.ok(gets("/api/events?limit=200&q=Matrix").length === 1);
    assert.strictEqual(rowsOf($("#events-list")).length, 1);
    $("#events-q").value = "";
    await app.loadEvents();
  });

  await check("follow asks only for events after the last id and prepends them", async () => {
    $("#events-follow").checked = true;
    const last = backend.events[backend.events.length - 1].id;
    const fresh = backend.emit("grab.accepted", "Radarr accepted the grab", { job_id: 9 });
    await app.pollEvents();
    assert.ok(gets(`/api/events?since_id=${last}&`).length === 1, JSON.stringify(gets("/api/events").map((r) => r.url)));
    const rows = rowsOf($("#events-list"));
    assert.strictEqual(rows.length, 6);
    assert.ok(rows[0].textContent.includes("Radarr accepted the grab"));
    await app.pollEvents();
    assert.ok(gets(`/api/events?since_id=${fresh.id}&`).length === 1);
    assert.strictEqual(rowsOf($("#events-list")).length, 6);
  });

  await check("pause holds new events back until resumed", async () => {
    click($("#events-pause"));
    backend.emit("job.started", "started #10");
    backend.emit("job.succeeded", "finished #10");
    await app.pollEvents();
    assert.strictEqual(rowsOf($("#events-list")).length, 6);
    assert.strictEqual($("#events-pause").textContent, "Resume (2 new)");
    click($("#events-pause"));
    const rows = rowsOf($("#events-list"));
    assert.strictEqual(rows.length, 8);
    assert.ok(rows[0].textContent.includes("finished #10"));
    assert.strictEqual($("#events-pause").textContent, "Pause");
  });

  await check("follow off: no polling", async () => {
    $("#events-follow").checked = false;
    const before = gets("/api/events?since_id").length;
    await app.pollEvents();
    assert.strictEqual(gets("/api/events?since_id").length, before);
    $("#events-follow").checked = true;
  });

  await check("at most 1000 rows are kept", async () => {
    for (let i = 0; i < 1200; i++) backend.emit("search.started", `bulk ${i}`);
    await app.pollEvents();
    await app.pollEvents();
    await app.pollEvents();
    assert.strictEqual(app.eventsView.events.length, 1000);
    assert.strictEqual(rowsOf($("#events-list")).length, 1000);
    assert.ok(rowsOf($("#events-list"))[0].textContent.includes("bulk 1199"));
  });

  await check("the #job link of an event opens that job", async () => {
    backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 1 } });
    const jobId = backend.jobs[backend.jobs.length - 1].id;
    backend.emit("job.queued", "queued for the link test", { job_id: jobId });
    await app.pollEvents();
    const row = rowsOf($("#events-list"))[0];
    click(button(row, `#${jobId}`));
    await flush();
    assert.ok(gets(`/api/jobs/${jobId}`).length >= 1);
    assert.ok($("#job-drawer-title").textContent.includes(`Job #${jobId}`));
  });

  /* --- dashboard -------------------------------------------------------- */
  await check("dashboard shows queue counts and the last 10 events", async () => {
    await app.loadDashboardQueue();
    await app.loadDashboardActivity();
    assert.ok(gets("/api/events?limit=10").length >= 1);
    assert.strictEqual(rowsOf($("#dashboard-activity")).length, 10);
    const q = $("#dashboard-queue").textContent;
    assert.ok(q.includes("Queued") && q.includes("Running"), q);
    assert.ok(buttonLabels($("#dashboard-queue")).includes("Open queue"));
  });

  /* --- passes and Seerr -------------------------------------------------- */
  await check("dashboard Run now enqueues automatic_pass and shows its summary", async () => {
    click($("#run-automatic"));
    await flush();
    assert.deepStrictEqual(lastJobPost().body, { kind: "automatic_pass", params: {}, source: "ui" });
    const id = backend.jobs[backend.jobs.length - 1].id;
    backend.finish(id, { instances: 2, duration_ms: 1200, dry_run: true, results: [{ instance: "Radarr", media: "M", reason: "nothing wanted" }] });
    await app.tickJobWatchers();
    assert.ok($("#automatic-run-result").textContent.includes("2 instance(s) in 1.2 s (dry run)"), $("#automatic-run-result").textContent);
    assert.ok($("#automatic-results").textContent.includes("nothing wanted"));
  });

  await check("Requests Run now enqueues seerr_pass", async () => {
    click($("#seerr-run"));
    await flush();
    assert.deepStrictEqual(lastJobPost().body, { kind: "seerr_pass", params: {}, source: "ui" });
    const id = backend.jobs[backend.jobs.length - 1].id;
    backend.finish(id, { approved: 0, fulfilled: 1, dry_run: false, duration_ms: 800, results: [] });
    await app.tickJobWatchers();
    assert.ok($("#seerr-run-result").textContent.includes("0 approved, 1 auto-grabbed"));
  });

  await check("the request panel's Search enqueues seerr_select and draws the result", async () => {
    $("#seerr-instruction").value = "";
    await app.openSeerrRequest(seerrRequest);
    await flush();
    click($("#seerr-panel-search"));
    await flush();
    assert.deepStrictEqual(lastJobPost().body, {
      kind: "seerr_select",
      params: { request_id: 41, grab: false, use_ai: true, approve: false, instance_id: "radarr" },
      source: "ui",
    });
    const id = backend.jobs[backend.jobs.length - 1].id;
    backend.finish(id, { request: seerrRequest, instance_id: "radarr", kind: "movie", grabbed: 0, selection: selection(movieMedia) });
    await app.tickJobWatchers();
    assert.ok($("#seerr-request-result").textContent.includes("Candidates (2)"));
    assert.ok($("#seerr-select-status").textContent.includes("movie: 0 grabbed"), $("#seerr-select-status").textContent);
    click(button($("#seerr-request-result"), "Grab selected"));
    await flush();
    assert.strictEqual(lastJobPost().body.kind, "grab_release");
    assert.strictEqual(lastJobPost().body.params.instance_id, "radarr");
  });

  await check("Approve & grab on a pending request enqueues seerr_select with approve", async () => {
    await app.openSeerrRequest(Object.assign({}, seerrRequest, { id: 43, status: 1 }), { grab: true });
    await flush();
    const body = lastJobPost().body;
    assert.strictEqual(body.kind, "seerr_select");
    assert.strictEqual(body.params.request_id, 43);
    assert.strictEqual(body.params.grab, true);
    assert.strictEqual(body.params.approve, true);
  });

  /* --- settings ------------------------------------------------------------ */
  await check("Save queue settings PUTs config.queue", async () => {
    const form = $("#queue-form");
    form.querySelector('[data-key="workers"]').value = "4";
    form.querySelector('[data-key="per_instance"]').value = "9";
    click($("#save-queue"));
    await flush();
    const put = backend.requests.filter((r) => r.method === "PUT" && r.url === "/api/config").pop();
    assert.deepStrictEqual(put.body, { queue: { workers: 4, per_instance: 4, keep_finished: 500 } });
  });

  /* With a fake clock: the loops re-arm themselves, poll the badge on every
     tick, the full queue only while the Queue tab is open, events only while
     the Events tab is open, and a watched job once a second. */
  await check("background loops poll on their intervals (fake clock)", async () => {
    /* Earlier checks left the loops of main() and toast timers around;
       keep only an unfired job-watch timer, if any. */
    const leftover = timers.filter((t) => t.ms === 1000);
    timers.length = 0;
    timers.push(...leftover);
    for (const k of Object.keys(app.pollLoops)) delete app.pollLoops[k];
    backend.requests = [];
    app.state.activeTab = "queue";
    app.startBackgroundPolling();
    const loops = () => timers.filter((t) => t.ms === 2000 || t.ms === 3000);
    assert.deepStrictEqual(loops().map((t) => t.ms).sort(), [2000, 2000, 3000]);
    const run = async () => {
      const due = loops();
      for (const t of due) timers.splice(timers.indexOf(t), 1);
      for (const t of due) t.fn();
      await flush();
    };
    await run();
    assert.ok(gets("/api/jobs?status=queued,running").length >= 1, "badge not polled");
    assert.ok(gets("/api/jobs?limit=200").length === 1, "queue tab not refreshed");
    assert.ok(gets("/api/events?").length === 0, "events polled while not visible");
    assert.strictEqual(loops().length, 3, "loops must re-arm");
    app.state.activeTab = "events";
    await run();
    assert.ok(gets("/api/events?since_id").length === 1, "events not followed");
    assert.ok(gets("/api/jobs?limit=200").length === 1, "queue polled while hidden");
    /* a watched job is polled once a second until it finishes */
    const job = backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 4242 } });
    let finished = null;
    app.watchJob(job.id, { onFinish: (j) => (finished = j) });
    const watch = timers.find((t) => t.ms === 1000);
    assert.ok(watch, "no 1 s watch timer");
    backend.finish(job.id, selection(movieMedia));
    timers.splice(timers.indexOf(watch), 1);
    watch.fn();
    await flush();
    assert.ok(finished && finished.status === "succeeded");
    assert.ok(!app.jobWatchers.has(job.id), "a finished job must stop being watched");
    /* other checks left unfinished jobs behind, so the timer stays armed
       exactly while something is still watched */
    assert.strictEqual(timers.some((t) => t.ms === 1000), app.jobWatchers.size > 0);
    app.jobWatchers.clear();
    const again = timers.find((t) => t.ms === 1000);
    if (again) {
      timers.splice(timers.indexOf(again), 1);
      again.fn();
      await flush();
    }
    assert.ok(!timers.some((t) => t.ms === 1000), "watch timer must stop with no watchers");
  });

  await check("a [ddd] status prefix on job.error is never shown", async () => {
    assert.strictEqual(app.stripStatusPrefix("[502] Radarr: down"), "Radarr: down");
    assert.strictEqual(app.stripStatusPrefix("Radarr: [502] stays"), "Radarr: [502] stays");
    const j = backend.add("search", { instance_id: "radarr", target: { kind: "movie", media_id: 9502 } });
    backend.fail(j.id, "[502] Radarr: release search failed for Come and See (1985)");
    await app.loadQueue();
    await flush();
    const row = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${j.id}`);
    assert.ok(row, "failed job not listed");
    assert.ok(row.textContent.includes("Radarr: release search failed"), row.textContent);
    assert.ok(!row.textContent.includes("[502]"), row.textContent);
    await app.openJobDrawer(j.id);
    await flush();
    assert.ok(!$("#job-drawer-meta").textContent.includes("[502]"), $("#job-drawer-meta").textContent);
    /* The inline status line and toast are covered by the Approve check. */
  });

  await check("seerr_fulfil: kind label, and View draws the request outcome", async () => {
    const j = backend.add("seerr_fulfil", { request_id: 41 }, { label: "Seerr request #41 · fulfil" });
    backend.finish(j.id, {
      request_id: 41,
      request: Object.assign({}, seerrRequest, { links: { seerr: "http://seerr:5055/movie/603" } }),
      results: [{ request_id: 41, request: "Some Movie (2024)", action: "grabbed", selected: "Some.Movie.2024.1080p-FLUX", grabbed: true }],
    });
    await app.loadQueue();
    await flush();
    const row = rowsOf($("#queue-list")).find((r) => r.children[0].textContent === `#${j.id}`);
    assert.ok(row.textContent.includes("Seerr fulfil"), row.textContent);
    await app.openJobDrawer(j.id);
    await flush();
    const body = $("#job-drawer-body");
    assert.ok(body.textContent.includes("Some Movie (2024)"), body.textContent.slice(0, 300));
    assert.ok(body.textContent.includes("Outcome"), body.textContent.slice(0, 300));
    assert.ok(body.textContent.includes("Some.Movie.2024.1080p-FLUX"), body.textContent.slice(0, 300));
    assert.ok(body.textContent.includes("Open in Seerr"), body.textContent.slice(0, 300));
    assert.ok(buttonLabels(body).includes("Open in the Requests panel"), JSON.stringify(buttonLabels(body)));
  });

  await check("grab_best with gate and grab_release with release_title get a hint", async () => {
    const g = backend.add("grab_best", { instance_id: "radarr", target: { kind: "movie", media_id: 31 }, gate: "automatic" });
    const r = backend.add("grab_release", {
      instance_id: "radarr",
      target: { kind: "movie", media_id: 32 },
      release_id: "x",
      release_title: "Exact.Release.Title-GRP",
    });
    await app.loadQueue();
    await flush();
    const rows = rowsOf($("#queue-list"));
    const gr = rows.find((x) => x.children[0].textContent === `#${g.id}`);
    const rr = rows.find((x) => x.children[0].textContent === `#${r.id}`);
    assert.ok(gr.textContent.includes("automatic gate"), gr.textContent);
    assert.ok(rr.textContent.includes("Exact.Release.Title-GRP"), rr.textContent);
  });

  await check("Approve in the Requests tab tracks the queued fulfilment job", async () => {
    const status = document.createElement("span");
    const before = backend.jobs.length;
    await app.seerrAction(43, "approve", status);
    await flush();
    assert.strictEqual(backend.jobs.length, before + 1, "approve must queue exactly one job");
    const job = backend.jobs[backend.jobs.length - 1];
    assert.strictEqual(job.kind, "seerr_fulfil");
    assert.ok(app.jobWatchers.has(job.id), "the fulfil job is not followed");
    assert.ok(status.textContent.includes(`#${job.id}`), status.textContent);
    assert.ok($("#toast").textContent.includes(`Queued #${job.id}`), $("#toast").textContent);
    backend.fail(job.id, "[502] Seerr: request #43 could not be fulfilled");
    await app.tickJobWatchers();
    await flush();
    assert.ok(status.textContent.includes("could not be fulfilled"), status.textContent);
    assert.ok(!status.textContent.includes("[502]"), status.textContent);
    assert.ok(!$("#toast").textContent.includes("[502]"), $("#toast").textContent);
  });

  await check("fmtDuration formats ms, seconds and minutes", async () => {
    assert.strictEqual(app.fmtDuration(850), "850 ms");
    assert.strictEqual(app.fmtDuration(12300), "12.3 s");
    assert.strictEqual(app.fmtDuration(125000), "2 m 05 s");
  });

  console.log(failures === 0 ? "\nALL QUEUE UI CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
