/* Pickarr UI — vanilla JS, no build step, no external dependencies. */

"use strict";

const state = {
  security: null,
  config: null,
  status: null,
  automatic: null,
  lastResult: null,
  proposal: null,
  activeTab: "dashboard",
  /* the last search job started from the Search page; only its result is
     drawn there */
  selectJobId: null,
  queueCounts: {},
};

/* Sonarr/Radarr only answer an interactive search once every indexer has
   replied, so this request legitimately takes far longer than any other.
   Saying so stops it looking hung (see network.arr_search_timeout_seconds). */
const GRAB_WAIT_HINT = " this can take a moment; Pickarr confirms the download queue afterwards";
const SEARCH_WAIT_HINT =
  " — this can take a minute or two while Sonarr/Radarr query every indexer";

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

const $ = (sel) => document.querySelector(sel);
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
  }
  return node;
};

/* [action] is an optional {label, onclick} drawn as a button after the
   message, e.g. "View queue" after a job was queued. */
function toast(message, isError, action) {
  const t = $("#toast");
  const parts = [el("span", {}, String(message))];
  if (action)
    parts.push(
      el(
        "button",
        {
          class: "small toast-action",
          onclick: () => {
            t.hidden = true;
            action.onclick();
          },
        },
        action.label
      )
    );
  t.replaceChildren(...parts);
  t.className = isError ? "bad" : "";
  t.hidden = false;
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => (t.hidden = true), isError ? 8000 : action ? 6000 : 3500);
}

function setResult(selector, message, ok) {
  const node = $(selector);
  if (!node) return;
  node.textContent = message || "";
  node.className = "result" + (message ? (ok ? " ok" : " bad") : "");
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (options.body) headers["Content-Type"] = "application/json";
  const response = await fetch(path, Object.assign({}, options, { headers, credentials: "same-origin" }));
  if (response.status === 401 && !path.startsWith("/api/auth/")) {
    // The session expired: the server-rendered login page takes over. The
    // error below still fires, so it must read sensibly for the moment
    // before the redirect happens.
    window.location.href = "/login";
    throw new Error("session expired — log in again and retry");
  }
  let payload = null;
  const text = await response.text();
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch (_) {
      payload = { error: text };
    }
  }
  if (!response.ok) {
    const message = (payload && payload.error) || `HTTP ${response.status}`;
    const error = new Error(message);
    error.payload = payload;
    error.status = response.status;
    throw error;
  }
  return payload;
}

const fmtGiB = (bytes) => (Number(bytes) / 1024 ** 3).toFixed(2) + " GiB";
const num = (v, d = "—") => (v === null || v === undefined ? d : v);

/* 850 ms · 12.3 s · 2 m 05 s */
function fmtDuration(ms) {
  if (ms === null || ms === undefined || Number.isNaN(Number(ms))) return "—";
  const n = Number(ms);
  if (n < 1000) return `${Math.round(n)} ms`;
  if (n < 60000) return `${(n / 1000).toFixed(1)} s`;
  const minutes = Math.floor(n / 60000);
  const seconds = Math.round((n % 60000) / 1000);
  return `${minutes} m ${String(seconds).padStart(2, "0")} s`;
}

/* A server timestamp as local time; today's only as HH:MM:SS. */
function fmtTime(ts) {
  if (!ts) return "—";
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return String(ts);
  const pad = (x) => String(x).padStart(2, "0");
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return time;
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
}

/* A button whose handler gets the button itself, so a queued job can show
   its busy state on exactly the button that started it. */
function actionButton(label, cls, handler, title) {
  const button = el("button", { class: cls || "small", title: title || false }, label);
  button.addEventListener("click", () => handler(button));
  return button;
}

/* ------------------------------------------------------------------ */
/* generic form builder                                               */
/* ------------------------------------------------------------------ */

/* A schema entry is {key, label, type, hint, options}.
   type: text | number | int | bool | list | intlist | select | float */
function buildForm(container, schema, values) {
  container.textContent = "";
  for (const field of schema) {
    const id = `${container.id}--${field.key}`;
    const value = values ? values[field.key] : undefined;
    let input;
    switch (field.type) {
      case "bool":
        input = el("input", { type: "checkbox", id });
        input.checked = value === true;
        break;
      case "select":
        input = el(
          "select",
          { id },
          field.options.map((o) => el("option", { value: o, selected: o === value ? "selected" : false }, o))
        );
        break;
      case "list":
      case "intlist":
        input = el("input", {
          type: "text",
          id,
          placeholder: field.placeholder || "comma separated",
          value: Array.isArray(value) ? value.join(", ") : "",
        });
        break;
      case "number":
      case "int":
      case "float":
        input = el("input", {
          type: "number",
          id,
          step: field.type === "int" ? "1" : "any",
          min: field.min !== undefined ? field.min : false,
          max: field.max !== undefined ? field.max : false,
          value: value === null || value === undefined ? "" : value,
        });
        break;
      default:
        input = el("input", {
          type: field.password ? "password" : "text",
          id,
          placeholder: field.placeholder || "",
          value: value === null || value === undefined ? "" : value,
        });
    }
    input.dataset.key = field.key;
    input.dataset.type = field.type;
    const label = el(
      "label",
      { for: id },
      field.label,
      field.hint ? el("span", { class: "hint-inline" }, " " + field.hint) : null,
      input
    );
    container.appendChild(label);
  }
}

/* Reads a form built by buildForm. Empty optional numbers become null, which
   the API interprets as "clear this limit". */
function readForm(container, schema) {
  const out = {};
  for (const field of schema) {
    const input = container.querySelector(`[data-key="${field.key}"]`);
    if (!input) continue;
    const raw = input.value;
    switch (field.type) {
      case "bool":
        out[field.key] = input.checked;
        break;
      case "list":
        out[field.key] = raw
          .split(",")
          .map((s) => s.trim())
          .filter((s) => s.length > 0);
        break;
      case "intlist":
        out[field.key] = raw
          .split(",")
          .map((s) => parseInt(s.trim(), 10))
          .filter((n) => !Number.isNaN(n));
        break;
      case "int":
        out[field.key] = raw === "" ? (field.optional ? null : 0) : parseInt(raw, 10);
        break;
      case "number":
      case "float":
        out[field.key] = raw === "" ? (field.optional ? null : 0) : parseFloat(raw);
        break;
      default:
        out[field.key] = raw;
    }
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* schemas (mirror the Config module of the core library)             */
/* ------------------------------------------------------------------ */

const hardRulesSchema = [
  { key: "max_size_gib", label: "Maximum release size (GiB)", type: "float", optional: true, hint: "empty = no limit" },
  { key: "min_size_gib", label: "Minimum release size (GiB)", type: "float", optional: true, hint: "empty = no limit" },
  { key: "min_seeders", label: "Minimum seeders", type: "int", optional: true, hint: "torrents only" },
  { key: "blocked_groups", label: "Blocked release groups", type: "list" },
  { key: "blocked_codecs", label: "Disallowed codecs", type: "list", placeholder: "AV1, XviD" },
  { key: "allowed_codecs", label: "Allowed codecs", type: "list", hint: "empty = all" },
  { key: "reject_unknown_codec", label: "Reject releases with an unknown codec", type: "bool" },
  { key: "blocked_languages", label: "Blocked languages", type: "list" },
  { key: "required_languages", label: "Required languages", type: "list", hint: "at least one" },
  { key: "allowed_resolutions", label: "Allowed resolutions", type: "intlist", placeholder: "1080, 2160" },
  { key: "allowed_protocols", label: "Allowed protocols", type: "list", placeholder: "torrent, usenet" },
  { key: "blocked_hdr_formats", label: "Blocked HDR formats", type: "list", placeholder: "HDR10+" },
  { key: "blocked_title_patterns", label: "Blocked title patterns", type: "list" },
  { key: "allow_remux", label: "Allow remuxes", type: "bool" },
  { key: "allow_hdr", label: "Allow HDR", type: "bool" },
  { key: "allow_dolby_vision", label: "Allow Dolby Vision", type: "bool" },
  {
    key: "require_hdr10_fallback_for_dv",
    label: "Require HDR10 fallback for Dolby Vision",
    type: "bool",
    hint: "rejects DV profile 5",
  },
  {
    key: "respect_arr_rejections",
    label: "Respect Sonarr/Radarr rejections",
    type: "bool",
    hint:
      "on: anything Sonarr/Radarr reject (profile cutoff, minimum custom-format score, size limits, delay…) is off-limits. " +
      "off: those become a scored penalty Pickarr and the AI may override; only unmappable or blocklisted releases stay rejected",
  },
];

/* Season packs. The config stores a 0..1 fraction; the form shows a
   percentage, which is easier to reason about. */
const seasonsSchema = [
  {
    key: "prefer_packs",
    label: "Prefer season packs",
    type: "bool",
    hint: "off = always select episode by episode",
  },
  {
    key: "min_missing_percent",
    label: "Use a pack when this much of the season is missing (%)",
    type: "int",
    min: 0,
    max: 100,
    hint: "100 = only for a completely missing season",
  },
  {
    key: "fallback_to_episodes",
    label: "Fall back to single episodes",
    type: "bool",
    hint: "when no acceptable pack exists, or the pack grab fails",
  },
];

function seasonsToForm(seasons) {
  const s = seasons || {};
  return {
    prefer_packs: s.prefer_packs !== false,
    min_missing_percent: Math.round((s.min_missing_fraction || 0) * 100),
    fallback_to_episodes: s.fallback_to_episodes !== false,
  };
}

function seasonsFromForm() {
  const v = readForm($("#seasons-form"), seasonsSchema);
  const percent = Math.min(100, Math.max(0, v.min_missing_percent || 0));
  return {
    prefer_packs: v.prefer_packs,
    min_missing_fraction: percent / 100,
    fallback_to_episodes: v.fallback_to_episodes,
  };
}

const preferencesSchema = [
  { key: "preferred_codecs", label: "Preferred codecs", type: "list", placeholder: "x265, x264" },
  { key: "disliked_codecs", label: "Disliked codecs", type: "list" },
  { key: "preferred_sources", label: "Preferred sources", type: "list", placeholder: "WEB-DL, Bluray" },
  { key: "preferred_groups", label: "Preferred release groups", type: "list", placeholder: "FLUX, NTb, HONE" },
  { key: "disliked_groups", label: "Disliked release groups", type: "list" },
  { key: "preferred_languages", label: "Preferred languages", type: "list" },
  { key: "preferred_resolutions", label: "Preferred resolutions", type: "intlist", placeholder: "1080" },
  { key: "preferred_audio", label: "Preferred audio", type: "list", placeholder: "Atmos, TrueHD" },
  { key: "hdr_preference", label: "HDR preference", type: "select", options: ["prefer", "neutral", "avoid"] },
  {
    key: "dolby_vision_preference",
    label: "Dolby Vision preference",
    type: "select",
    options: ["prefer", "neutral", "avoid"],
  },
  { key: "prefer_remux", label: "Prefer remuxes", type: "bool" },
  { key: "prefer_repacks", label: "Prefer repacks/propers", type: "bool" },
  { key: "ideal_size_gib", label: "Ideal size (GiB)", type: "float", optional: true, hint: "empty = no target" },
  { key: "size_tolerance_gib", label: "Size tolerance (GiB)", type: "float" },
];

const weightKeys = [
  "custom_format",
  "quality_weight",
  "web_dl_over_webrip",
  "bluray_over_web",
  "remux",
  "preferred_codec",
  "disliked_codec",
  "preferred_source",
  "preferred_group",
  "disliked_group",
  "preferred_language",
  "preferred_resolution",
  "preferred_audio",
  "hdr",
  "dolby_vision",
  "repack",
  "seeders",
  "seeders_cap",
  "size_penalty_per_gib",
  "arr_approved",
  "arr_rejected",
  "age_penalty_per_day",
  "age_penalty_cap",
];

const weightsSchema = weightKeys.map((k) => ({
  key: k,
  label: k.replace(/_/g, " "),
  type: "float",
}));

const llmSchema = [
  { key: "enabled", label: "AI selection enabled", type: "bool" },
  { key: "provider", label: "Provider", type: "text", placeholder: "openai-compatible" },
  { key: "base_url", label: "LLM base URL", type: "text", placeholder: "http://localhost:11434/v1" },
  { key: "api_key", label: "LLM API key", type: "text", password: true, hint: "leave ******** to keep" },
  { key: "model", label: "LLM model", type: "text", placeholder: "gpt-4o-mini" },
  { key: "temperature", label: "Temperature", type: "float" },
  { key: "max_tokens", label: "Max tokens", type: "int" },
  { key: "timeout_seconds", label: "Timeout (seconds)", type: "int" },
  { key: "json_mode", label: "Request JSON mode", type: "bool", hint: "disable for servers without it" },
  { key: "max_candidates", label: "Max candidates sent to the model", type: "int" },
];

const networkSchema = [
  {
    key: "arr_timeout_seconds",
    label: "Read timeout (seconds)",
    type: "int",
    min: 5,
    max: 900,
    hint: "status, movie, episode, queue, history, grab \u2014 default 30",
  },
  {
    key: "arr_search_timeout_seconds",
    label: "Release search timeout (seconds)",
    type: "int",
    min: 5,
    max: 900,
    hint:
      "interactive searches and library listings \u2014 default 180; raise it if your indexers are slow",
  },
];

const automaticSchema = [
  { key: "enabled", label: "Automatic mode enabled", type: "bool" },
  { key: "grab", label: "Actually grab", type: "bool", hint: "off = dry run" },
  { key: "interval_seconds", label: "Interval (seconds)", type: "int", hint: "minimum 60" },
  { key: "search_missing", label: "Process missing items", type: "bool" },
  { key: "search_cutoff_unmet", label: "Process cutoff-unmet items", type: "bool" },
  { key: "max_items_per_run", label: "Max items per run", type: "int" },
  { key: "min_confidence", label: "Minimum AI confidence to grab", type: "float", min: 0, max: 1 },
  { key: "webhook_trigger", label: "React to webhooks", type: "bool" },
];

/* ------------------------------------------------------------------ */
/* dashboard                                                           */
/* ------------------------------------------------------------------ */

function renderStatus() {
  const s = state.status || {};
  const cards = [
    ["Version", s.version],
    ["Uptime", s.uptime_seconds !== undefined ? `${Math.round(s.uptime_seconds / 60)} min` : "—"],
    ["Instances", `${num(s.instances_enabled, 0)} enabled / ${num(s.instances, 0)}`],
    ["AI selection", s.llm_enabled ? `on (${s.llm_model})` : "off"],
    ["Automatic mode", s.automatic_enabled ? (s.automatic_grab ? "on" : "on (dry run)") : "off"],
    ["Data dir", s.data_dir],
  ];
  $("#status-cards").replaceChildren(
    ...cards.map(([k, v]) => el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, num(v))))
  );
}

function renderDashboardInstances() {
  const container = $("#dashboard-instances");
  const instances = (state.config && state.config.instances) || [];
  if (instances.length === 0) {
    container.replaceChildren(
      el("p", { class: "hint" }, "No instance configured yet. Add one on the Instances tab.")
    );
    return;
  }
  container.replaceChildren(
    ...instances.map((i) => {
      const result = el("span", { class: "result" });
      return el(
        "div",
        { class: "panel" },
        el(
          "div",
          {},
          el("strong", {}, i.name),
          " ",
          el("span", { class: "badge" }, i.app),
          " ",
          el("span", { class: "badge " + (i.enabled ? "ok" : "") }, i.enabled ? "enabled" : "disabled"),
          i.automatic ? el("span", { class: "badge warn" }, " automatic") : null
        ),
        el("div", { class: "hint" }, i.url),
        el(
          "p",
          {},
          el(
            "button",
            {
              class: "small",
              onclick: async () => {
                result.textContent = "testing…";
                result.className = "result";
                try {
                  const r = await api(`/api/instances/${encodeURIComponent(i.id)}/test`, { method: "POST" });
                  result.textContent = `${r.app_name} ${r.version} (${r.instance_name})`;
                  result.className = "result ok";
                } catch (e) {
                  result.textContent = e.message;
                  result.className = "result bad";
                }
              },
            },
            "Test connection"
          ),
          result
        )
      );
    })
  );
}

function renderAutomaticStatus() {
  const a = state.automatic || {};
  const container = $("#automatic-status");
  const rows = [
    ["Enabled", a.enabled ? "yes" : "no"],
    ["Grabbing", a.grab ? "yes" : "no (dry run)"],
    ["Interval", a.interval_seconds ? `${a.interval_seconds}s` : "—"],
    ["Instances", (a.instances || []).join(", ") || "none"],
    ["Runs", num(a.runs, 0)],
    ["Last run", num(a.last_run_at)],
    ["Next run", num(a.next_run_at)],
    ["Last error", num(a.last_error, "none")],
  ];
  container.replaceChildren(
    el(
      "div",
      { class: "cards" },
      ...rows.map(([k, v]) => el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, v)))
    )
  );
  renderAutomaticResults(a.last_results || []);
}

/* Draws into [target] (default: the dashboard's last-pass table) and
   returns it, so the job drawer can reuse it. */
function renderAutomaticResults(results, target) {
  const container = target || $("#automatic-results");
  if (!results.length) {
    container.replaceChildren();
    return container;
  }
  container.replaceChildren(
    el("h3", {}, "Last pass"),
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el("tr", {}, ["Instance", "Media", "Outcome", "Method", "Grabbed"].map((h) => el("th", {}, h)))
      ),
      el(
        "tbody",
        {},
        ...results.map((r) =>
          el(
            "tr",
            {},
            el("td", {}, num(r.instance)),
            el("td", {}, num(r.media)),
            el("td", {}, r.error || r.skipped || r.selected || r.reason || "—"),
            el("td", {}, num(r.method, "—")),
            el("td", {}, r.grabbed === undefined ? "—" : r.grabbed ? "yes" : "no")
          )
        )
      )
    )
  );
  return container;
}

/* ------------------------------------------------------------------ */
/* select                                                             */
/* ------------------------------------------------------------------ */

function renderInstanceOptions() {
  const select = $("#select-instance");
  const previous = select.value;
  const instances = ((state.config && state.config.instances) || []).filter((i) => i.enabled);
  select.replaceChildren(
    ...instances.map((i) => el("option", { value: i.id }, `${i.name} (${i.app})`))
  );
  if (previous) select.value = previous;
}

/* Errors from api() carry the HTTP status; show it, because "not found" means
   something very different for a media id than for an unreachable instance. */
function describeApiError(e) {
  return e.status ? `HTTP ${e.status} · ${e.message}` : e.message;
}

/* The instance of the Search page's last result, so its per-candidate Grab
   buttons know where to grab. */
let selectTarget = null;

/* A rendered selection carries everything its Grab buttons need: which
   instance to talk to, which media the candidates belong to, where to write
   the status, and how to redraw itself after a grab. The Select page and the
   Requests tab pass different ones, which is why the renderers take it. */
function selectPageContext() {
  return {
    instanceId: selectTarget && selectTarget.instanceId,
    statusNode: $("#select-status"),
    setStatus: (message, ok) => setResult("#select-status", message, ok),
  };
}

function instanceById(id) {
  const instances = (state.config && state.config.instances) || [];
  return instances.find((i) => i.id === id) || null;
}

/* A movie id on Radarr, an episode id on Sonarr. */
function mediaTarget(instanceId, mediaId) {
  const inst = instanceById(instanceId);
  return { kind: inst && inst.app === "radarr" ? "movie" : "episode", media_id: mediaId };
}

/* The target a release from a result card belongs to. A season pack has no
   media id of its own, so it is named by series id and season number. */
function releaseTarget(media, instanceId) {
  const m = media || {};
  if (m.media_kind === "season")
    return {
      kind: "season",
      series_id: m.series_id === undefined || m.series_id === null ? m.media_id : m.series_id,
      season_number: m.season_number,
    };
  if (m.media_kind === "movie" || m.media_kind === "episode")
    return { kind: m.media_kind, media_id: m.media_id };
  if (m.app === "radarr") return { kind: "movie", media_id: m.media_id };
  if (m.app === "sonarr") return { kind: "episode", media_id: m.media_id };
  return mediaTarget(instanceId, m.media_id);
}

function searchJobParams(instanceId, target) {
  const params = {
    instance_id: instanceId,
    target: target,
    use_ai: !!($("#select-use-ai") && $("#select-use-ai").checked),
  };
  const instruction = (($("#select-instruction") && $("#select-instruction").value) || "").trim();
  if (instruction) params.instruction = instruction;
  return params;
}

function describeSearchDone(result, job) {
  if (result && result.summary && result.seasons) {
    const s = result.summary;
    return `done: ${s.seasons || 0} season(s), ${s.grabbed || 0} grabbed`;
  }
  const took = ` in ${fmtDuration(job.duration_ms)}`;
  if (job.kind === "grab_best")
    return result.grabbed
      ? `grabbed${took}`
      : `searched${took}, not grabbed${result.grab_error ? `: ${result.grab_error}` : ""}`;
  return `done${took}`;
}

/* Search (grab=false) or search-and-grab (grab=true) one target from the
   Search page. The work runs as a queued job; its status shows next to the
   buttons and its result is drawn below when it finishes — unless another
   search was started from this page in the meantime. */
function runSearchPageJob(grab, target, button) {
  const instanceId = $("#select-instance").value;
  if (!instanceId) return toast("No enabled instance: add one on the Instances tab first", true);
  const params = searchJobParams(instanceId, target);
  return runJob(grab ? "grab_best" : "search", params, {
    button,
    statusNode: $("#select-status"),
    waitHint: SEARCH_WAIT_HINT,
    describeDone: describeSearchDone,
    isSuccess: (result, job) => job.kind !== "grab_best" || !!result.grabbed || !!result.summary,
    onStart: (job) => {
      state.selectJobId = job.id;
      $("#select-result").replaceChildren();
    },
    isCurrent: (job) => state.selectJobId === job.id,
    onResult: (result) => {
      state.lastResult = result;
      selectTarget = {
        instanceId,
        mediaId: target.media_id !== undefined ? target.media_id : target.series_id,
      };
      if (target.kind === "series") renderSeriesResult(result, null, selectPageContext());
      else renderSelectionResult(result, null, selectPageContext());
      if (grab) loadHistory();
    },
  });
}

/* Search (and optionally grab) one movie or episode. The media id comes from
   the picked library item, a picked episode or a wanted row — never from a
   field the user has to fill in by hand. */
function runSelection(grab, mediaId, button) {
  const instanceId = $("#select-instance").value;
  if (!instanceId)
    return toast("No enabled instance: add one on the Instances tab first", true);
  if (!Number.isInteger(mediaId) || mediaId < 1)
    return toast("Pick a movie or an episode first", true);
  return runSearchPageJob(grab, mediaTarget(instanceId, mediaId), button);
}

/* Grab one release from a search result: the winner ("Grab selected") or any
   other candidate ("Grab this"). It is queued as a grab_release job; guid and
   indexer_id identify the release even if its id changed since the search,
   and the server still only grabs a release that passes the hard rules. When
   the job finishes, the card it came from is redrawn with the outcome. */
async function grabCandidate(release, button, ctx) {
  if (!ctx || !ctx.instanceId || !ctx.media) return toast("Search first", true);
  if (!confirm(`Grab this release now?\n\n${release.title}`)) return null;
  const params = {
    instance_id: ctx.instanceId,
    target: releaseTarget(ctx.media, ctx.instanceId),
    release_id: release.id,
  };
  if (release.guid) params.guid = release.guid;
  if (release.indexer_id) params.indexer_id = release.indexer_id;
  return runJob("grab_release", params, {
    button,
    statusNode: ctx.statusNode || null,
    setStatus: ctx.setStatus,
    waitHint: GRAB_WAIT_HINT,
    describeDone: (result) =>
      result.grabbed
        ? "grabbed" +
          (result.grab_notes && result.grab_notes.length ? ` · ${result.grab_notes.join(" · ")}` : "")
        : `not grabbed: ${result.grab_error || "unknown reason"}`,
    isSuccess: (result) => !!result.grabbed,
    onResult: (result) => {
      state.lastResult = result;
      /* Redraw the card the release came from, unless that area shows
         something else by now. */
      if (!ctx.stillShowing || ctx.stillShowing()) ctx.rerender(result);
      loadHistory();
    },
  });
}

function releaseRow(scored, isWinner, ctx) {
  const r = scored.release;
  const button = el(
    "button",
    { class: "small", title: "Grab this release" },
    isWinner && ctx && ctx.grabbed ? "Grab again" : "Grab this"
  );
  button.addEventListener("click", () => grabCandidate(r, button, ctx));
  return el(
    "tr",
    { class: isWinner ? "winner" : "" },
    el("td", {}, scored.score.toFixed(1)),
    el("td", {}, r.title),
    el("td", {}, fmtGiB(r.size_bytes)),
    el("td", {}, num(r.quality, "—")),
    el("td", {}, num(r.source, "—")),
    el("td", {}, num(r.codec, "—")),
    el("td", {}, num(r.release_group, "—")),
    el("td", {}, num(r.seeders, "—")),
    el("td", {}, num(r.custom_format_score, "—")),
    el("td", {}, num(r.indexer, "—")),
    el("td", {}, button)
  );
}

function renderSelectionResult(result, target, ctx) {
  const container = target || $("#select-result");
  const base = ctx || selectPageContext();
  const children = [];
  const method = result.method || {};
  const media = result.media || {};
  /* Per-result context: the candidates below belong to this media, and a
     grab redraws this very container. */
  /* Each render stamps its container, so a grab that finishes after the
     area was redrawn with another result does not overwrite it. */
  container._renderSeq = (container._renderSeq || 0) + 1;
  const seq = container._renderSeq;
  const rowContext = {
    instanceId: base.instanceId,
    media: media,
    grabbed: !!result.grabbed,
    statusNode: base.statusNode === undefined ? $("#select-status") : base.statusNode,
    setStatus: base.setStatus || ((m, ok) => setResult("#select-status", m, ok)),
    stillShowing: () => container._renderSeq === seq,
    rerender: (updated) => renderSelectionResult(updated, container, base),
  };

  children.push(
    el(
      "div",
      { class: "panel" },
      el("strong", {}, media.title || "unknown"),
      media.year ? ` (${media.year})` : "",
      media.season_number !== null && media.season_number !== undefined
        ? ` S${String(media.season_number).padStart(2, "0")}E${String(media.episode_number).padStart(2, "0")}`
        : "",
      el("div", { class: "hint" }, `${result.candidates.length} candidate(s), ${result.rejected.length} rejected`),
      el("div", {}, ...openInLinks(media.links, media.app)),
      el(
        "div",
        {},
        el("span", { class: "badge" }, "decided by: " + (method.kind || "?")),
        " ",
        result.llm ? el("span", { class: "badge" }, `confidence ${(result.llm.confidence * 100).toFixed(0)}%`) : null,
        " ",
        el(
          "span",
          { class: "badge " + (result.grabbed ? "ok" : "") },
          result.grabbed ? "grabbed" : result.grab_error ? "not grabbed" : "not grabbed yet"
        )
      ),
      method.llm_error ? el("div", { class: "conflicts" }, "AI unavailable, used deterministic scoring: " + method.llm_error) : null,
      result.grab_error ? el("div", { class: "conflicts" }, "Grab failed: " + result.grab_error) : null,
      result.grab_notes && result.grab_notes.length
        ? el("div", { class: "hint" }, "Grab: " + result.grab_notes.join(" · "))
        : null
    )
  );

  if (result.selected) {
    const sel = result.selected;
    /* A search leaves the winner ungrabbed on purpose, so the result card
       carries the grab action itself. */
    const grabSelected = el(
      "button",
      { class: "primary", title: "Grab the release Pickarr picked" },
      result.grabbed ? "Grab again" : "Grab selected"
    );
    grabSelected.addEventListener("click", () =>
      grabCandidate(sel.release, grabSelected, rowContext)
    );
    children.push(
      el(
        "div",
        { class: "selected-card" },
        el("h3", {}, "Selected"),
        el("div", { class: "title" }, sel.release.title),
        el(
          "div",
          { class: "hint" },
          `${fmtGiB(sel.release.size_bytes)} · score ${sel.score.toFixed(1)} · ${num(sel.release.indexer, "unknown indexer")}`
        ),
        el("p", { class: "grab-actions" }, grabSelected),
        el("h3", {}, "Why"),
        el(
          "ul",
          { class: "why" },
          ...(result.explanation.length ? result.explanation : [result.reason]).map((line) => el("li", {}, line))
        ),
        result.conflicts && result.conflicts.length
          ? el(
              "div",
              { class: "conflicts" },
              el("strong", {}, "Could not follow every preference"),
              el("ul", { class: "why" }, ...result.conflicts.map((c) => el("li", {}, c)))
            )
          : null,
        el(
          "details",
          {},
          el("summary", {}, "Score breakdown"),
          el(
            "table",
            {},
            el("thead", {}, el("tr", {}, ["Component", "Points", "Detail"].map((h) => el("th", {}, h)))),
            el(
              "tbody",
              {},
              ...sel.components.map((c) =>
                el("tr", {}, el("td", {}, c.component), el("td", {}, c.points.toFixed(1)), el("td", {}, c.detail))
              )
            )
          )
        )
      )
    );
  } else {
    children.push(el("div", { class: "conflicts" }, "No release could be selected: " + result.reason));
  }

  const selectedId = result.selected ? result.selected.release.id : null;
  children.push(
    el("h3", {}, `Candidates (${result.candidates.length})`),
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el(
          "tr",
          {},
          [
            "Score",
            "Title",
            "Size",
            "Quality",
            "Source",
            "Codec",
            "Group",
            "Seeders",
            "CF",
            "Indexer",
            "",
          ].map((h) => el("th", {}, h))
        )
      ),
      el(
        "tbody",
        {},
        ...result.candidates.map((c) => releaseRow(c, c.release.id === selectedId, rowContext))
      )
    )
  );

  if (result.rejected.length) {
    children.push(
      el("h3", {}, `Rejected (${result.rejected.length})`),
      el(
        "table",
        {},
        el("thead", {}, el("tr", {}, ["Title", "Size", "Rejected because", "Stage"].map((h) => el("th", {}, h)))),
        el(
          "tbody",
          {},
          ...result.rejected.map((r) =>
            el(
              "tr",
              {},
              el("td", {}, r.release.title),
              el("td", {}, fmtGiB(r.release.size_bytes)),
              el("td", {}, r.reasons.map((x) => x.message).join("; ")),
              el("td", {}, [...new Set(r.reasons.map((x) => x.stage))].join(", "))
            )
          )
        )
      )
    );
  }

  if (result.llm && result.llm.ranking && result.llm.ranking.length) {
    children.push(
      el(
        "details",
        {},
        el("summary", {}, "AI ranking"),
        el(
          "table",
          {},
          el("thead", {}, el("tr", {}, ["Score", "Release", "Reason"].map((h) => el("th", {}, h)))),
          el(
            "tbody",
            {},
            ...result.llm.ranking.map((entry) => {
              const match = result.candidates.find((c) => c.release.id === entry.id);
              return el(
                "tr",
                {},
                el("td", {}, entry.score),
                el("td", {}, match ? match.release.title : entry.id),
                el("td", {}, entry.reason)
              );
            })
          )
        )
      )
    );
  }

  container.replaceChildren(...children.filter(Boolean));
}

/* ------------------------------------------------------------------ */
/* library browsing: find an item, pick it, then search it             */
/* ------------------------------------------------------------------ */

/* What the Search / Grab buttons act on. One of:
     {kind:"movie",   mediaId}
     {kind:"episode", mediaId, label}
     {kind:"season",  seriesId, seasonNumber}
     {kind:"series",  seriesId, seasons:[n]}   (seasons empty = all)  */
let picked = null;

function selectedInstance() {
  const id = $("#select-instance").value;
  const instances = (state.config && state.config.instances) || [];
  return instances.find((i) => i.id === id) || null;
}

/* "Open in Sonarr" / "Open in Seerr" for anything that carries a links
   object. Returns an empty array when nothing is linkable, so callers can
   splat it straight into el(). */
function openInLinks(links, app) {
  if (!links) return [];
  const out = [];
  const arrName = app === "radarr" ? "Radarr" : app === "sonarr" ? "Sonarr" : "the *arr";
  if (links.arr)
    out.push(
      el(
        "a",
        { class: "linkbtn", href: links.arr, target: "_blank", rel: "noreferrer noopener" },
        `Open in ${arrName}`
      )
    );
  if (links.seerr)
    out.push(
      el(
        "a",
        { class: "linkbtn", href: links.seerr, target: "_blank", rel: "noreferrer noopener" },
        "Open in Seerr"
      )
    );
  return out;
}

function describePicked() {
  if (!picked) return "nothing picked yet";
  switch (picked.kind) {
    case "movie":
      return `picked: ${picked.label}`;
    case "episode":
      return `picked: ${picked.label}`;
    case "season":
      return `picked: ${picked.label}`;
    case "series":
      return picked.seasons && picked.seasons.length
        ? `picked: ${picked.label}, season(s) ${picked.seasons.join(", ")}`
        : `picked: ${picked.label}, all seasons`;
    default:
      return "nothing picked yet";
  }
}

function setPicked(next) {
  picked = next;
  const target = $("#select-target");
  if (target) target.textContent = describePicked();
}

async function searchLibrary() {
  const instanceId = $("#select-instance").value;
  if (!instanceId)
    return toast("No enabled instance: add one on the Instances tab first", true);
  const q = $("#library-q").value.trim();
  setResult("#library-status", "searching your library…", true);
  $("#library-results").replaceChildren();
  try {
    const data = await api(
      `/api/library/${encodeURIComponent(instanceId)}/search?q=${encodeURIComponent(q)}`
    );
    const found = (data.results || []).length;
    setResult(
      "#library-status",
      found
        ? `${found}${data.truncated ? "+" : ""} of ${data.total} item(s)`
        : `nothing in this library matches "${q}"`,
      found > 0
    );
    renderLibraryResults(data);
  } catch (e) {
    setResult("#library-status", describeApiError(e), false);
    toast(describeApiError(e), true);
  }
}

function libraryItemSummary(item) {
  if (item.kind === "movie")
    return item.has_file ? "on disk" : item.monitored ? "missing" : "not monitored";
  const seasons = item.season_count === null ? "?" : item.season_count;
  const missing = item.missing_count === null ? "?" : item.missing_count;
  return `${seasons} season(s), ${missing} episode(s) missing`;
}

function renderLibraryResults(data) {
  const container = $("#library-results");
  const items = data.results || [];
  if (!items.length) {
    container.replaceChildren();
    return;
  }
  container.replaceChildren(
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el("tr", {}, ["Title", "Kind", "Status", "Links", ""].map((h) => el("th", {}, h)))
      ),
      el(
        "tbody",
        {},
        ...items.map((item) =>
          el(
            "tr",
            {},
            el("td", {}, item.title + (item.year ? ` (${item.year})` : "")),
            el("td", {}, item.kind),
            el("td", {}, libraryItemSummary(item)),
            el("td", {}, ...openInLinks(item.links, data.app)),
            el(
              "td",
              {},
              el(
                "button",
                { class: "small primary", onclick: () => pickLibraryItem(data, item) },
                "Pick"
              )
            )
          )
        )
      )
    )
  );
}

/* Picking loads the detail the buttons need: a movie card, or the season
   table of a series. */
async function pickLibraryItem(data, item) {
  const instanceId = data.instance_id;
  const container = $("#library-picked");
  container.replaceChildren(el("p", { class: "hint" }, "Loading…"));
  $("#select-result").replaceChildren();
  setResult("#select-status", "", true);
  try {
    if (item.kind === "movie") {
      const detail = await api(
        `/api/library/${encodeURIComponent(instanceId)}/movie/${item.id}`
      );
      renderPickedMovie(instanceId, detail, item);
    } else {
      const detail = await api(
        `/api/library/${encodeURIComponent(instanceId)}/series/${item.id}`
      );
      renderPickedSeries(instanceId, detail, item);
    }
  } catch (e) {
    container.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
    toast(describeApiError(e), true);
  }
}

function renderPickedMovie(instanceId, detail, item) {
  const movie = detail.movie || {};
  const label = movie.title + (movie.year ? ` (${movie.year})` : "");
  setPicked({ kind: "movie", instanceId, mediaId: movie.media_id, label });
  $("#library-picked").replaceChildren(
    el(
      "div",
      { class: "panel picked" },
      el("strong", {}, label),
      el(
        "div",
        { class: "hint" },
        movie.has_file
          ? `on disk${movie.existing_quality ? ` (${movie.existing_quality})` : ""}`
          : "no file yet",
        movie.monitored ? "" : " · not monitored"
      ),
      el("div", {}, ...openInLinks(movie.links, "radarr")),
      el(
        "div",
        {},
        actionButton("Search", "small", (b) => runSelection(false, movie.media_id, b)),
        " ",
        actionButton("Grab", "small primary", (b) => {
          if (confirm(`Search and grab the best release for ${label}?`))
            runSelection(true, movie.media_id, b);
        })
      )
    )
  );
}

/* One season row: a checkbox for "search selected seasons", the per-season
   pack buttons, and an expander that loads the episodes on demand. */
function seasonRow(instanceId, seriesId, seriesLabel, s) {
  const label = s.season_number === 0 ? "Specials" : `Season ${s.season_number}`;
  const checkbox = el("input", { type: "checkbox", value: String(s.season_number) });
  checkbox.className = "season-pick";
  const episodes = el("div", {});
  const expander = el(
    "details",
    {},
    el("summary", {}, "Episodes"),
    episodes
  );
  expander.addEventListener("toggle", async () => {
    if (!expander.open || expander.dataset.loaded) return;
    expander.dataset.loaded = "1";
    episodes.replaceChildren(el("p", { class: "hint" }, "Loading…"));
    try {
      const data = await api(
        `/api/library/${encodeURIComponent(instanceId)}/series/${seriesId}/season/${s.season_number}`
      );
      renderSeasonEpisodes(episodes, instanceId, seriesId, seriesLabel, data);
    } catch (e) {
      expander.dataset.loaded = "";
      episodes.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
    }
  });
  const pickSeason = () =>
    setPicked({
      kind: "season",
      instanceId,
      seriesId,
      seasonNumber: s.season_number,
      label: `${seriesLabel} ${label}`,
    });
  return el(
    "tr",
    {},
    el("td", {}, checkbox),
    el("td", {}, label),
    el("td", {}, `${s.missing_episodes} / ${s.total_episodes}`),
    el("td", {}, s.existing_quality || "—"),
    el("td", {}, s.monitored ? "yes" : "no"),
    el(
      "td",
      {},
      actionButton(
        "Search",
        "small",
        (b) => {
          pickSeason();
          runSeasonSelection(false, seriesId, s.season_number, b);
        },
        "Search for a season pack"
      ),
      " ",
      actionButton("Grab", "small primary", (b) => {
        if (!confirm(`Search and grab the best pack for ${label} now?`)) return;
        pickSeason();
        runSeasonSelection(true, seriesId, s.season_number, b);
      }),
      expander
    )
  );
}

function renderSeasonEpisodes(container, instanceId, seriesId, seriesLabel, data) {
  const episodes = data.episodes || [];
  if (!episodes.length) {
    container.replaceChildren(el("p", { class: "hint" }, "No episodes in this season."));
    return;
  }
  container.replaceChildren(
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el("tr", {}, ["#", "Title", "Aired", "On disk", ""].map((h) => el("th", {}, h)))
      ),
      el(
        "tbody",
        {},
        ...episodes.map((ep) => {
          const label = `${seriesLabel} S${String(ep.season_number).padStart(2, "0")}E${String(
            ep.episode_number
          ).padStart(2, "0")}`;
          const pick = () =>
            setPicked({ kind: "episode", instanceId, mediaId: ep.id, label });
          return el(
            "tr",
            {},
            el("td", {}, ep.episode_number),
            el("td", {}, ep.title || "—"),
            el("td", {}, (ep.air_date || "—").slice(0, 10)),
            el("td", {}, ep.has_file ? ep.existing_quality || "yes" : "no"),
            el(
              "td",
              {},
              actionButton("Search", "small", (b) => {
                pick();
                runSelection(false, ep.id, b);
              }),
              " ",
              actionButton("Grab", "small primary", (b) => {
                if (!confirm(`Search and grab the best release for ${label}?`)) return;
                pick();
                runSelection(true, ep.id, b);
              })
            )
          );
        })
      )
    )
  );
}

/* The season checkboxes only exist while a series is picked; an empty list
   means "the whole series". */
function checkedSeasons() {
  const panel = $("#library-picked");
  if (!panel || !panel.querySelectorAll) return [];
  return Array.from(panel.querySelectorAll("input.season-pick"))
    .filter((box) => box.checked)
    .map((box) => parseInt(box.value, 10))
    .filter((n) => !Number.isNaN(n));
}

function renderPickedSeries(instanceId, detail, item) {
  const series = detail.series || {};
  const seasons = detail.seasons || [];
  const label = series.title + (series.year ? ` (${series.year})` : "");
  setPicked({ kind: "series", instanceId, seriesId: series.media_id, seasons: [], label });
  const container = $("#library-picked");
  if (!seasons.length) {
    container.replaceChildren(
      el(
        "div",
        { class: "panel picked" },
        el("strong", {}, label),
        el("div", {}, ...openInLinks(series.links, "sonarr")),
        el("p", { class: "hint" }, "This series has no seasons Sonarr knows about.")
      )
    );
    return;
  }
  const wholeSeries = (grab, button) => {
    const chosen = checkedSeasons();
    setPicked({
      kind: "series",
      instanceId,
      seriesId: series.media_id,
      seasons: chosen,
      label,
    });
    runSeriesSelection(grab, series.media_id, chosen, button);
  };
  container.replaceChildren(
    el(
      "div",
      { class: "panel picked" },
      el("strong", {}, label),
      el(
        "div",
        { class: "hint" },
        `${detail.missing_episodes ?? "?"} of ${detail.total_episodes ?? "?"} episode(s) missing`
      ),
      el("div", {}, ...openInLinks(series.links, "sonarr")),
      el(
        "table",
        {},
        el(
          "thead",
          {},
          el(
            "tr",
            {},
            ["", "Season", "Missing", "On disk", "Monitored", ""].map((h) => el("th", {}, h))
          )
        ),
        el(
          "tbody",
          {},
          ...seasons.map((s) => seasonRow(instanceId, series.media_id, series.title, s))
        )
      ),
      el(
        "div",
        {},
        actionButton("Search selected seasons", "small", (b) => wholeSeries(false, b)),
        " ",
        actionButton("Grab selected seasons", "small primary", (b) => {
          const chosen = checkedSeasons();
          const what = chosen.length ? `season(s) ${chosen.join(", ")}` : "every season";
          if (!confirm(`Search and grab ${what} of ${label}?`)) return;
          wholeSeries(true, b);
        }),
        el(
          "span",
          { class: "hint-inline" },
          " no season ticked = the whole series"
        )
      )
    )
  );
}

/* Search (and optionally grab) a season pack. Called from a season row, so
   the series id and season number are always known. */
function runSeasonSelection(grab, seriesId, season, button) {
  const instanceId = $("#select-instance").value;
  if (!instanceId) return toast("Configure an instance first", true);
  if (!seriesId || seriesId < 1) return toast("Pick a series first", true);
  if (!Number.isInteger(season) || season < 0) return toast("Pick a season first", true);
  return runSearchPageJob(
    grab,
    { kind: "season", series_id: seriesId, season_number: season },
    button
  );
}

/* Search (and optionally grab) a whole series, or just the ticked seasons. */
function runSeriesSelection(grab, seriesId, seasons, button) {
  const instanceId = $("#select-instance").value;
  if (!instanceId) return toast("Configure an instance first", true);
  if (!seriesId || seriesId < 1) return toast("Pick a series first", true);
  const target = { kind: "series", series_id: seriesId };
  if (seasons && seasons.length) target.seasons = seasons;
  return runSearchPageJob(grab, target, button);
}

function renderSeriesResult(result, target, ctx) {
  const container = target || $("#select-result");
  const base = ctx || selectPageContext();
  const series = result.series || {};
  const summary = result.summary || {};
  const children = [
    el(
      "div",
      { class: "panel" },
      el("strong", {}, series.title || "unknown"),
      series.year ? ` (${series.year})` : "",
      el(
        "div",
        { class: "hint" },
        `${summary.seasons || 0} season(s) considered · ${summary.selections || 0} search(es) · ` +
          `${summary.selected || 0} with a winner · ${summary.grabbed || 0} grabbed`
      ),
      el("div", {}, ...openInLinks(series.links, series.app))
    ),
  ];

  for (const season of result.seasons || []) {
    const label = season.season_number === 0 ? "Specials" : `Season ${season.season_number}`;
    const head = el(
      "div",
      {},
      el("strong", {}, label),
      el("span", { class: "hint-inline" }, ` ${season.missing} of ${season.total} missing`)
    );
    const outcome = season.outcome || {};
    const body = el("div", {});
    if (outcome.kind === "pack") {
      head.appendChild(el("span", { class: "badge" }, "season pack"));
      renderSelectionResult(outcome.selection, body, base);
    } else if (outcome.kind === "episodes") {
      head.appendChild(
        el("span", { class: "badge" }, `${(outcome.selections || []).length} episode search(es)`)
      );
      for (const selection of outcome.selections || []) {
        const card = el("div", {});
        renderSelectionResult(selection, card, base);
        body.appendChild(el("details", {}, el("summary", {}, selectionLabel(selection)), card));
      }
    } else {
      head.appendChild(el("span", { class: "badge" }, "skipped"));
      body.appendChild(el("div", { class: "hint" }, outcome.reason || "skipped"));
    }
    children.push(el("div", { class: "panel" }, head, body));
  }

  container.replaceChildren(...children);
}

function selectionLabel(selection) {
  const media = selection.media || {};
  const episode =
    media.season_number !== null && media.episode_number !== null && media.episode_number !== undefined
      ? ` S${String(media.season_number).padStart(2, "0")}E${String(media.episode_number).padStart(2, "0")}`
      : "";
  const title = selection.selected ? selection.selected.release.title : "nothing selected";
  return `${media.title || ""}${episode} — ${title}${selection.grabbed ? " (grabbed)" : ""}`;
}

/* The page's Search / Grab buttons act on whatever was picked last: a movie,
   an episode, a season pack, or the series. */
function runCurrentSelection(grab, button) {
  if (!picked) return toast("Search your library and pick an item first", true);
  switch (picked.kind) {
    case "season":
      return runSeasonSelection(grab, picked.seriesId, picked.seasonNumber, button);
    case "series":
      return runSeriesSelection(grab, picked.seriesId, checkedSeasons(), button);
    default:
      return runSelection(grab, picked.mediaId, button);
  }
}

async function loadWanted() {
  const instanceId = $("#select-instance").value;
  if (!instanceId) return toast("Configure an instance first", true);
  const kind = $("#wanted-kind").value;
  const container = $("#wanted-list");
  container.replaceChildren(el("p", { class: "hint" }, "Loading…"));
  try {
    const data = await api(`/api/wanted/${encodeURIComponent(instanceId)}?kind=${kind}&page_size=50`);
    if (!data.items.length) {
      container.replaceChildren(el("p", { class: "hint" }, "Nothing wanted."));
      return;
    }
    container.replaceChildren(
      el("p", { class: "hint" }, `${data.total_records} wanted item(s); showing ${data.items.length}`),
      el(
        "table",
        {},
        el("thead", {}, el("tr", {}, ["Id", "Item", "Kind", ""].map((h) => el("th", {}, h)))),
        el(
          "tbody",
          {},
          ...data.items.map((item) =>
            el(
              "tr",
              {},
              el("td", {}, item.media_id),
              el("td", {}, item.label),
              el("td", {}, item.kind),
              el(
                "td",
                {},
                el(
                  "button",
                  {
                    class: "small",
                    onclick: () => {
                      setPicked({
                        kind: item.kind === "movie" ? "movie" : "episode",
                        instanceId: instanceId,
                        mediaId: item.media_id,
                        label: item.label,
                      });
                      $("#library-picked").replaceChildren(
                        el(
                          "div",
                          { class: "panel picked" },
                          el("strong", {}, item.label),
                          el("div", { class: "hint" }, `${item.kind}, id ${item.media_id}`),
                          el(
                            "div",
                            {},
                            actionButton("Search", "small", (b) =>
                              runSelection(false, item.media_id, b)
                            ),
                            " ",
                            actionButton("Grab", "small primary", (b) => {
                              if (confirm(`Search and grab the best release for ${item.label}?`))
                                runSelection(true, item.media_id, b);
                            })
                          )
                        )
                      );
                      toast(`Picked ${item.label}`);
                    },
                  },
                  "Pick"
                )
              )
            )
          )
        )
      )
    );
  } catch (e) {
    container.replaceChildren(el("p", { class: "result bad" }, e.message));
  }
}

/* ------------------------------------------------------------------ */
/* rules & preferences                                                */
/* ------------------------------------------------------------------ */

function renderRules() {
  const c = state.config;
  if (!c) return;
  $("#nl-preferences").value = c.nl_preferences || "";
  buildForm($("#hard-rules-form"), hardRulesSchema, c.hard_rules);
  buildForm($("#preferences-form"), preferencesSchema, c.preferences);
  buildForm($("#weights-form"), weightsSchema, c.weights);
}

async function saveConfigPatch(patch, statusSelector) {
  setResult(statusSelector, "saving…", true);
  try {
    const updated = await api("/api/config", { method: "PUT", body: JSON.stringify(patch) });
    state.config = updated;
    setResult(statusSelector, "saved", true);
    renderInstanceOptions();
    renderDashboardInstances();
    renderGetStarted();
    loadStatus();
    return true;
  } catch (e) {
    setResult(statusSelector, e.message, false);
    toast(e.message, true);
    return false;
  }
}

function renderProposal(proposal) {
  const container = $("#proposal");
  state.proposal = proposal;
  if (!proposal) {
    container.replaceChildren();
    return;
  }
  const summary = proposal.summary || [];
  container.replaceChildren(
    el(
      "div",
      { class: "panel" },
      el("h3", {}, "Proposed structured rules"),
      el(
        "p",
        { class: "hint" },
        "Nothing has been saved. Review the proposal and apply it explicitly if you agree."
      ),
      ...(summary.length
        ? summary.map((line) => el("div", { class: "proposal-item" }, line))
        : [el("p", { class: "hint" }, "The model proposed no changes.")]),
      el("details", {}, el("summary", {}, "Raw patch"), el("pre", {}, JSON.stringify(proposal.patch, null, 2))),
      el(
        "p",
        {},
        el(
          "button",
          {
            class: "primary",
            onclick: async () => {
              try {
                const response = await api("/api/rules/apply", {
                  method: "POST",
                  body: JSON.stringify({ patch: proposal.patch }),
                });
                state.config = response.config;
                renderRules();
                renderProposal(null);
                toast("Structured rules updated");
              } catch (e) {
                toast(e.message, true);
              }
            },
          },
          "Apply selected"
        ),
        " ",
        el("button", { onclick: () => renderProposal(null) }, "Discard")
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* instances editor                                                   */
/* ------------------------------------------------------------------ */

let instanceDraft = [];

function slugify(text) {
  return (
    text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/(^-|-$)/g, "") || "instance"
  );
}

function renderInstancesEditor() {
  const container = $("#instances-editor");
  if (!instanceDraft.length) {
    container.replaceChildren(el("p", { class: "hint" }, "No instances. Add a Sonarr or Radarr instance below."));
    return;
  }
  container.replaceChildren(
    ...instanceDraft.map((inst, index) => {
      const update = (key) => (event) => {
        instanceDraft[index][key] =
          event.target.type === "checkbox" ? event.target.checked : event.target.value;
      };
      return el(
        "div",
        { class: "instance-card" },
        el(
          "header",
          {},
          el("strong", {}, `${inst.name || "(unnamed)"} — ${inst.app}`),
          el(
            "button",
            {
              class: "small danger",
              onclick: () => {
                instanceDraft.splice(index, 1);
                renderInstancesEditor();
              },
            },
            "Remove"
          )
        ),
        el(
          "div",
          { class: "row" },
          el("label", {}, "Name", el("input", { type: "text", value: inst.name || "", oninput: update("name") })),
          el("label", {}, "URL", el("input", { type: "text", value: inst.url || "", placeholder: "http://sonarr:8989", oninput: update("url") })),
          el(
            "label",
            {},
            "API key ",
            el("span", { class: "hint-inline" }, "Sonarr/Radarr → Settings → General"),
            el(
              "span",
              { class: "with-toggle" },
              (() => {
                const field = el("input", {
                  type: "password",
                  value: inst.api_key || "",
                  placeholder: "32 hex characters",
                  oninput: update("api_key"),
                });
                const toggle = el(
                  "button",
                  {
                    class: "small",
                    type: "button",
                    onclick: () => {
                      field.type = field.type === "password" ? "text" : "password";
                      toggle.textContent = field.type === "password" ? "Show" : "Hide";
                    },
                  },
                  "Show"
                );
                return [field, toggle];
              })()
            )
          )
        ),
        el(
          "p",
          {},
          el("label", { class: "inline" }, el("input", { type: "checkbox", checked: inst.enabled ? "checked" : false, onchange: update("enabled") }), " Enabled"),
          el(
            "label",
            { class: "inline" },
            el("input", { type: "checkbox", checked: inst.automatic ? "checked" : false, onchange: update("automatic") }),
            " Automatic mode for this instance"
          )
        ),
        (() => {
          const result = el("span", { class: "result" });
          return el(
            "p",
            {},
            el(
              "button",
              {
                class: "small",
                onclick: async () => {
                  if (!inst.id) {
                    result.textContent = "save the instance first";
                    result.className = "result bad";
                    return;
                  }
                  result.textContent = "testing…";
                  result.className = "result";
                  try {
                    const r = await api(`/api/instances/${encodeURIComponent(inst.id)}/test`, { method: "POST" });
                    result.textContent = `${r.app_name} ${r.version} (${r.instance_name})`;
                    result.className = "result ok";
                  } catch (e) {
                    result.textContent = e.message;
                    result.className = "result bad";
                  }
                },
              },
              "Test"
            ),
            result,
            el("span", { class: "hint-inline" }, " tests the saved settings")
          );
        })(),
        el(
          "label",
          { class: "block" },
          "Natural language preferences for this instance",
          el("span", { class: "hint-inline" }, " appended to the global preferences"),
          el("textarea", {
            rows: 4,
            placeholder: "Quality matters much more than storage here. Prefer Remux.",
            oninput: update("nl_preferences"),
          }, inst.nl_preferences || "")
        )
      );
    })
  );
}

function addInstance(app) {
  instanceDraft.push({
    id: "",
    name: app === "sonarr" ? "Sonarr" : "Radarr",
    app: app,
    url: "",
    api_key: "",
    enabled: true,
    automatic: false,
    nl_preferences: "",
  });
  renderInstancesEditor();
}

async function saveInstances() {
  const instances = instanceDraft.map((i) => ({
    id: i.id || slugify(i.name),
    name: i.name,
    app: i.app,
    url: (i.url || "").trim(),
    api_key: i.api_key,
    enabled: !!i.enabled,
    automatic: !!i.automatic,
    nl_preferences: i.nl_preferences || "",
  }));
  const invalid = instances.find((i) => !i.url);
  if (invalid) return toast(`Instance "${invalid.name}" needs a URL`, true);
  if (await saveConfigPatch({ instances }, "#instances-status")) {
    instanceDraft = JSON.parse(JSON.stringify(state.config.instances));
    renderInstancesEditor();
  }
}

/* ------------------------------------------------------------------ */
/* history & logs                                                     */
/* ------------------------------------------------------------------ */

async function loadHistory() {
  const container = $("#history-list");
  try {
    const entries = await api("/api/history?limit=100");
    if (!entries.length) {
      container.replaceChildren(el("p", { class: "hint" }, "No searches yet."));
      return;
    }
    container.replaceChildren(
      el(
        "table",
        {},
        el(
          "thead",
          {},
          el(
            "tr",
            {},
            ["When", "Instance", "Item", "Selected", "Size", "Method", "Grabbed", "Links"].map(
              (h) => el("th", {}, h)
            )
          )
        ),
        el(
          "tbody",
          {},
          ...entries.map((e) =>
            el(
              "tr",
              {},
              el("td", {}, e.timestamp),
              el("td", {}, e.instance_id),
              el("td", {}, e.media_label),
              el(
                "td",
                {},
                e.selected_title || el("span", { class: "hint" }, e.reason || "nothing selected"),
                e.explanation && e.explanation.length
                  ? el(
                      "details",
                      {},
                      el("summary", {}, "why"),
                      el("ul", { class: "why" }, ...e.explanation.map((l) => el("li", {}, l)))
                    )
                  : null
              ),
              el("td", {}, e.selected_size_gib ? e.selected_size_gib + " GiB" : "—"),
              el("td", {}, e.method + (e.confidence !== null && e.confidence !== undefined ? ` (${(e.confidence * 100).toFixed(0)}%)` : "")),
              el("td", {}, e.grabbed ? "yes" : e.grab_error ? "failed" : "no"),
              /* Entries written before links existed simply have none. */
              el("td", {}, ...openInLinks(e.links, e.app))
            )
          )
        )
      )
    );
  } catch (e) {
    container.replaceChildren(el("p", { class: "result bad" }, e.message));
  }
}

async function loadLogs() {
  try {
    const entries = await api("/api/logs?limit=300");
    $("#logs-output").textContent = entries
      .map((e) => `${e.at}  ${e.level.toUpperCase().padEnd(7)} ${e.message}`)
      .join("\n");
  } catch (e) {
    $("#logs-output").textContent = e.message;
  }
}


/* ------------------------------------------------------------------ */
/* security                                                            */
/* ------------------------------------------------------------------ */

function renderSecurity() {
  const a = state.security || {};
  $("#auth-summary").textContent = a.credentials_from_env
    ? "Credentials come from PICKARR_USERNAME / PICKARR_PASSWORD and cannot be changed here."
    : a.account_configured
      ? `Signed in as "${a.username}". Forms authentication is ${a.auth_required ? "enabled" : "disabled"}.`
      : "No account exists yet.";
  $("#auth-username").value = a.username || "";
  $("#auth-username").disabled = !!a.credentials_from_env;
  $("#auth-new-password").disabled = !!a.credentials_from_env;
  $("#auth-current-password").disabled = !!a.credentials_from_env;
  $("#auth-save").disabled = !!a.credentials_from_env;
  $("#api-key").value = a.api_key || "";
  $("#auth-required").checked = a.auth_required !== false;
  const host = location.host || "pickarr:8484";
  $("#webhook-example").textContent =
    `${location.protocol}//${host}/api/webhook/<instance_id>?apikey=${a.api_key || "<key>"}`;
}

async function loadSecurity() {
  try {
    state.security = await api("/api/security");
    renderSecurity();
  } catch (e) {
    $("#auth-summary").textContent = e.message;
  }
}

/* ------------------------------------------------------------------ */
/* first run                                                           */
/* ------------------------------------------------------------------ */

function renderGetStarted() {
  const container = $("#get-started");
  const instances = (state.config && state.config.instances) || [];
  const llm = (state.config && state.config.llm) || {};
  if (instances.length > 0 && llm.enabled) {
    container.hidden = true;
    container.replaceChildren();
    return;
  }
  const steps = [];
  if (instances.length === 0) {
    steps.push([
      "Connect Sonarr or Radarr",
      "Add the URL and API key of each instance (Settings \u2192 General in Sonarr/Radarr), then press Test.",
      "instances",
      "Add an instance",
    ]);
  }
  if (!llm.enabled) {
    steps.push([
      "Enable AI selection (optional)",
      "Point Pickarr at any OpenAI-compatible server, set the model, then press Test AI connection. Without it Pickarr uses deterministic scoring only.",
      "llm",
      "Configure AI",
    ]);
  }
  steps.push([
    "Describe what you like",
    "Write your preferences in plain English on the Rules & Preferences page \u2014 no scoring weights needed.",
    "rules",
    "Write preferences",
  ]);
  steps.push([
    "Search for a release",
    "Pick an instance and a movie or episode, search, then grab the winner \u2014 or any candidate you prefer.",
    "select",
    "Try it",
  ]);
  container.hidden = false;
  container.replaceChildren(
    el("h2", {}, "Get started"),
    el("p", { class: "hint" }, "Pickarr needs a couple of minutes of setup before it can choose releases for you."),
    el(
      "ol",
      { class: "steps" },
      ...steps.map(([title, text, tab, label]) =>
        el(
          "li",
          {},
          el("strong", {}, title),
          el("div", { class: "hint" }, text),
          el("button", { class: "small", onclick: () => showTab(tab) }, label)
        )
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* loading                                                            */
/* ------------------------------------------------------------------ */

async function loadStatus() {
  try {
    state.status = await api("/api/status");
    renderStatus();
  } catch (e) {
    $("#status-cards").replaceChildren(el("p", { class: "result bad" }, e.message));
  }
}

async function loadConfig() {
  state.config = await api("/api/config");
  instanceDraft = JSON.parse(JSON.stringify(state.config.instances || []));
  renderRules();
  buildForm($("#llm-form"), llmSchema, state.config.llm);
  buildForm($("#automatic-form"), automaticSchema, state.config.automatic);
  buildForm($("#seasons-form"), seasonsSchema, seasonsToForm(state.config.seasons));
  buildForm($("#network-form"), networkSchema, state.config.network);
  buildForm($("#queue-form"), queueSchema, queueSettings());
  renderInstancesEditor();
  renderInstanceOptions();
  renderDashboardInstances();
  renderGetStarted();
}

async function loadAutomatic() {
  try {
    state.automatic = await api("/api/automatic/status");
    renderAutomaticStatus();
  } catch (e) {
    $("#automatic-status").replaceChildren(el("p", { class: "result bad" }, e.message));
  }
}

/* ------------------------------------------------------------------ */
/* jobs: every Search / Grab / pass runs as a job in the server queue  */
/* ------------------------------------------------------------------ */

/* How often an open status line asks about its job, and how often the
   badge, the Queue tab and a followed Events tab refresh. */
const JOB_POLL_MS = 1000;
const BADGE_POLL_MS = 3000;
const QUEUE_POLL_MS = 2000;
const EVENTS_POLL_MS = 2000;
const EVENTS_MAX_ROWS = 1000;

const FINISHED_STATUSES = new Set(["succeeded", "failed", "cancelled"]);

const JOB_KINDS = {
  search: { icon: "\u{1F50D}", label: "Search" },
  grab_best: { icon: "\u2B07", label: "Grab" },
  grab_release: { icon: "\u2B07", label: "Grab release" },
  seerr_select: { icon: "\u2709", label: "Seerr request" },
  seerr_fulfil: { icon: "\u2709", label: "Seerr fulfil" },
  automatic_pass: { icon: "\u27F3", label: "Automatic pass" },
  seerr_pass: { icon: "\u27F3", label: "Seerr pass" },
  seerr_webhook: { icon: "\u26A1", label: "Seerr webhook" },
};

function jobKindLabel(kind) {
  const k = JOB_KINDS[kind];
  return k ? `${k.icon} ${k.label}` : kind || "job";
}

/* A hint under the kind for the optional params some kinds take: "gate"
   (a webhook selection that only grabs above the automatic confidence
   gate) and "release_title" (the release a grab_release job asked for). */
function jobKindHint(job) {
  const p = job.params || {};
  if (p.gate === "automatic") return "automatic gate: grabs only if the automatic rules allow it";
  if (job.kind === "grab_release" && p.release_title) return p.release_title;
  return null;
}

/* The server stores job errors without the "[ddd] " HTTP status prefix
   (the status is in job.error_status); strip it anyway so an old job or an
   older server never shows "[502] ..." to the user. */
function stripStatusPrefix(message) {
  return typeof message === "string" ? message.replace(/^\[\d{3}\] /, "") : message;
}

function jobErrorText(job, fallback) {
  const e = stripStatusPrefix(job && job.error);
  return e || fallback || "";
}

/* "queued · position 2", "running", "failed"... */
function jobStatusText(job) {
  if (job.status === "queued" && job.position) return `queued · #${job.position} in line`;
  return job.status || "?";
}

function jobStatusPill(job) {
  return el("span", { class: `pill pill-${job.status || "unknown"}` }, jobStatusText(job));
}

/* Running jobs have no duration yet; show how long they have been at it. */
function jobDuration(job) {
  if (job.duration_ms !== null && job.duration_ms !== undefined) return fmtDuration(job.duration_ms);
  if (job.status === "running" && job.started_at) {
    const started = new Date(job.started_at).getTime();
    if (!Number.isNaN(started)) return fmtDuration(Math.max(0, Date.now() - started)) + "…";
  }
  return "—";
}

async function enqueueJob(kind, params) {
  const response = await api("/api/jobs", {
    method: "POST",
    body: JSON.stringify({ kind, params, source: "ui" }),
  });
  return response.job;
}

function toastJob(job, verb) {
  toast(`${verb || "Queued"} #${job.id} · ${job.label || jobKindLabel(job.kind)}`, false, {
    label: "View queue",
    onclick: () => showTab("queue"),
  });
}

/* --- watching single jobs ----------------------------------------- */

/* job id -> [{onUpdate, onFinish}], polled every JOB_POLL_MS while any
   status line is waiting. */
const jobWatchers = new Map();
let jobWatchTimer = null;
let jobWatchBusy = false;

function watchJob(id, handlers) {
  if (!jobWatchers.has(id)) jobWatchers.set(id, []);
  jobWatchers.get(id).push(handlers);
  scheduleJobWatch();
}

function scheduleJobWatch() {
  if (jobWatchTimer !== null || jobWatchers.size === 0) return;
  jobWatchTimer = setTimeout(() => {
    jobWatchTimer = null;
    tickJobWatchers().finally(scheduleJobWatch);
  }, JOB_POLL_MS);
}

function callSafely(fn, arg) {
  if (!fn) return;
  try {
    fn(arg);
  } catch (e) {
    /* A rendering bug must not stop the other watchers, and must not be
       silent either. */
    console.error(e);
    toast("UI error: " + e.message, true);
  }
}

/* One round of polling: every watched job is fetched once; finished jobs
   are handed to their onFinish and forgotten. Exported for the tests, which
   cannot rely on timers. */
async function tickJobWatchers() {
  if (jobWatchBusy) return;
  jobWatchBusy = true;
  try {
    for (const id of Array.from(jobWatchers.keys())) {
      let job;
      try {
        job = (await api(`/api/jobs/${id}`)).job;
      } catch (e) {
        if (e.status !== 404) continue; // a network blip: ask again next round
        job = { id, status: "failed", error: "the job no longer exists (cleared?)" };
      }
      const handlers = jobWatchers.get(id) || [];
      if (FINISHED_STATUSES.has(job.status)) {
        jobWatchers.delete(id);
        for (const h of handlers) callSafely(h.onFinish, job);
      } else {
        for (const h of handlers) callSafely(h.onUpdate, job);
      }
    }
  } finally {
    jobWatchBusy = false;
  }
}

/* --- the inline status line of the panel that started a job ---------- */

function setButtonBusy(button, text) {
  if (!button) return;
  if (button._idleLabel === undefined) button._idleLabel = button.textContent;
  button.disabled = true;
  button.textContent = text;
}

function setButtonIdle(button) {
  if (!button || button._idleLabel === undefined) return;
  button.disabled = false;
  button.textContent = button._idleLabel;
  button._idleLabel = undefined;
}

/* Write a job's state into [node] (a span.result): "#12 queued (position
   2)…", "#12 running: searching Radarr…", "#12 done in 4.2 s", or the error
   with a Retry button. Falls back to opts.setStatus when there is no node. */
function renderJobLine(node, job, opts) {
  const o = opts || {};
  let text;
  let ok = true;
  switch (job.status) {
    case "queued":
      text = `#${job.id} queued${job.position ? ` (position ${job.position})` : ""}…`;
      break;
    case "running":
      text = job.progress ? `#${job.id} ${job.progress}` : `#${job.id} running…${o.waitHint || ""}`;
      break;
    case "succeeded":
      text =
        o.describeDone && job.result
          ? `#${job.id} ${o.describeDone(job.result, job)}`
          : `#${job.id} done in ${fmtDuration(job.duration_ms)}`;
      if (o.isSuccess && job.result) ok = o.isSuccess(job.result, job);
      break;
    case "cancelled":
      text = `#${job.id} cancelled`;
      ok = false;
      break;
    default:
      text = `#${job.id} failed: ${jobErrorText(job, "unknown error")}`;
      ok = false;
  }
  if (!node) {
    if (o.setStatus) o.setStatus(text, ok);
    return;
  }
  const parts = [el("span", {}, text)];
  parts.push(
    el("button", { class: "small linklike", onclick: () => openJobDrawer(job.id) }, "view")
  );
  if ((job.status === "failed" || job.status === "cancelled") && o.retry)
    parts.push(actionButton("Retry", "small", (b) => o.retry(job, b)));
  node.className = "result" + (ok ? " ok" : " bad");
  node.replaceChildren(...parts);
}

/* uiJobKeys: kind+params -> job id while this page waits for that job, so a
   double click does not queue the same thing twice (the server dedupes
   too, this just avoids the round trip). 0 = the POST is in flight. */
const uiJobKeys = new Map();

function jobKey(kind, params) {
  return kind + ":" + JSON.stringify(params);
}

/* Queue a job and follow it from the panel that asked for it.
   opts: {button, statusNode, setStatus, waitHint, describeDone, isSuccess,
          onStart(job), isCurrent(job), onResult(result, job)}
   isCurrent lets a panel ignore a job it has since replaced (an older
   search finishing after a newer one was started). */
async function runJob(kind, params, opts) {
  const o = opts || {};
  const key = jobKey(kind, params);
  if (uiJobKeys.has(key)) {
    const id = uiJobKeys.get(key);
    toast(id ? `Already queued as #${id}` : "Already queueing…", false, {
      label: "View queue",
      onclick: () => showTab("queue"),
    });
    return null;
  }
  uiJobKeys.set(key, 0);
  setButtonBusy(o.button, "queueing…");
  let job;
  try {
    job = await enqueueJob(kind, params);
  } catch (e) {
    uiJobKeys.delete(key);
    setButtonIdle(o.button);
    const message = describeApiError(e);
    if (o.statusNode) {
      o.statusNode.className = "result bad";
      o.statusNode.replaceChildren(el("span", {}, `not queued: ${message}`));
    } else if (o.setStatus) o.setStatus(`not queued: ${message}`, false);
    toast(message, true);
    return null;
  }
  toastJob(job);
  followJob(job, o, key);
  pollQueueBadge();
  return job;
}

/* Everything after the job exists: shared by runJob and the inline Retry. */
function followJob(job, o, key) {
  if (key) uiJobKeys.set(key, job.id);
  if (o.onStart) callSafely(o.onStart, job);
  const current = (j) => !o.isCurrent || o.isCurrent(j);
  const lineOpts = Object.assign({}, o, {
    retry: async (failed, button) => {
      setButtonBusy(button, "queueing…");
      try {
        const response = await api(`/api/jobs/${failed.id}/retry`, { method: "POST" });
        toastJob(response.job, "Retrying as");
        followJob(response.job, o, jobKey(response.job.kind, response.job.params || {}));
        pollQueueBadge();
      } catch (e) {
        setButtonIdle(button);
        toast(describeApiError(e), true);
      }
    },
  });
  const update = (j) => {
    setButtonBusy(o.button, j.status === "running" ? "running…" : "queued…");
    if (current(j)) renderJobLine(o.statusNode, j, lineOpts);
  };
  const finish = (j) => {
    if (key && uiJobKeys.get(key) === j.id) uiJobKeys.delete(key);
    setButtonIdle(o.button);
    if (!current(j)) return;
    renderJobLine(o.statusNode, j, lineOpts);
    if (j.status === "succeeded" && o.onResult) o.onResult(j.result || {}, j);
    if (j.status !== "succeeded") toast(`#${j.id} ${j.status}: ${jobErrorText(j, j.label || "")}`, true);
  };
  if (FINISHED_STATUSES.has(job.status)) {
    finish(job);
    return;
  }
  update(job);
  watchJob(job.id, { onUpdate: update, onFinish: finish });
}

/* --- queue badge (visible from every tab) --------------------------- */

function renderQueueBadge(counts) {
  const badge = $("#queue-badge");
  if (!badge) return;
  const c = counts || {};
  const running = c.running || 0;
  const queued = c.queued || 0;
  const parts = [];
  if (running) parts.push(`${running} running`);
  if (queued) parts.push(`${queued} queued`);
  badge.textContent = parts.join(" · ");
  badge.hidden = parts.length === 0;
  badge.className = "nav-badge" + (running ? " busy" : "");
}

async function pollQueueBadge() {
  try {
    const data = await api("/api/jobs?status=queued,running&limit=100");
    const counts = Object.assign({}, data.counts || {});
    /* Count from the list too, in case counts only cover some statuses. */
    const jobs = data.jobs || [];
    if (counts.running === undefined) counts.running = jobs.filter((j) => j.status === "running").length;
    if (counts.queued === undefined) counts.queued = jobs.filter((j) => j.status === "queued").length;
    state.queueCounts = Object.assign({}, state.queueCounts || {}, {
      running: counts.running,
      queued: counts.queued,
    });
    renderQueueBadge(state.queueCounts);
  } catch (_) {
    /* the badge is best effort */
  }
}

/* --- Queue tab ------------------------------------------------------- */

const QUEUE_FILTERS = [
  { key: "all", label: "All", statuses: null },
  { key: "active", label: "Active", statuses: "queued,running" },
  { key: "succeeded", label: "Succeeded", statuses: "succeeded" },
  { key: "failed", label: "Failed", statuses: "failed,cancelled" },
];

const queueView = { filter: "all", jobs: [], counts: {} };

function queueFilterCount(key, counts) {
  const c = counts || {};
  switch (key) {
    case "all":
      return ["queued", "running", "succeeded", "failed", "cancelled"].reduce(
        (sum, k) => sum + (c[k] || 0),
        0
      );
    case "active":
      return (c.queued || 0) + (c.running || 0);
    case "succeeded":
      return c.succeeded || 0;
    case "failed":
      return (c.failed || 0) + (c.cancelled || 0);
    default:
      return 0;
  }
}

function renderQueueFilters() {
  const container = $("#queue-filters");
  if (!container) return;
  container.replaceChildren(
    ...QUEUE_FILTERS.map((f) =>
      el(
        "button",
        {
          class: "chip" + (queueView.filter === f.key ? " active" : ""),
          onclick: () => setQueueFilter(f.key),
        },
        `${f.label} (${queueFilterCount(f.key, queueView.counts)})`
      )
    )
  );
}

function setQueueFilter(key) {
  queueView.filter = key;
  renderQueueFilters();
  return loadQueue();
}

async function loadQueue() {
  const filter = QUEUE_FILTERS.find((f) => f.key === queueView.filter) || QUEUE_FILTERS[0];
  const path =
    "/api/jobs?limit=200" + (filter.statuses ? `&status=${encodeURIComponent(filter.statuses)}` : "");
  try {
    const data = await api(path);
    queueView.jobs = (data.jobs || []).slice().sort((a, b) => b.id - a.id);
    queueView.counts = data.counts || {};
    if (filter.key === "all" || filter.key === "active") {
      state.queueCounts = Object.assign({}, state.queueCounts || {}, queueView.counts);
      renderQueueBadge(state.queueCounts);
    }
    renderQueueFilters();
    renderQueue();
  } catch (e) {
    const list = $("#queue-list");
    if (list) list.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
  }
}

async function cancelJob(id, button) {
  setButtonBusy(button, "cancelling…");
  try {
    const response = await api(`/api/jobs/${id}/cancel`, { method: "POST" });
    toast(`#${id} ${response.job ? response.job.status : "cancelled"}`);
  } catch (e) {
    toast(describeApiError(e), true);
  } finally {
    setButtonIdle(button);
    if (drawerJobId === id) openJobDrawer(id);
    loadQueue();
    pollQueueBadge();
  }
}

async function retryJob(id, button) {
  setButtonBusy(button, "queueing…");
  try {
    const response = await api(`/api/jobs/${id}/retry`, { method: "POST" });
    toastJob(response.job, "Retrying as");
    /* The drawer follows the retry rather than the job that failed. */
    if (drawerJobId === id) openJobDrawer(response.job.id);
  } catch (e) {
    toast(describeApiError(e), true);
  } finally {
    setButtonIdle(button);
    loadQueue();
    pollQueueBadge();
  }
}

async function clearFinishedJobs() {
  setResult("#queue-result", "clearing…", true);
  try {
    const response = await api("/api/jobs?status=finished", { method: "DELETE" });
    setResult("#queue-result", `cleared ${response.cleared} finished job(s)`, true);
  } catch (e) {
    setResult("#queue-result", describeApiError(e), false);
  }
  loadQueue();
}

function jobActions(job) {
  const actions = [actionButton("View", "small", () => openJobDrawer(job.id))];
  if (job.status === "queued" || job.status === "running")
    actions.push(actionButton("Cancel", "small danger", (b) => cancelJob(job.id, b)));
  if (job.status === "failed" || job.status === "cancelled")
    actions.push(actionButton("Retry", "small", (b) => retryJob(job.id, b)));
  return actions;
}

function queueRow(job) {
  return el(
    "tr",
    { class: `job-row job-${job.status}` },
    el("td", {}, `#${job.id}`),
    el("td", {}, jobStatusPill(job)),
    el(
      "td",
      {},
      el("span", { class: "nowrap" }, jobKindLabel(job.kind)),
      jobKindHint(job) ? el("div", { class: "hint" }, jobKindHint(job)) : null
    ),
    el(
      "td",
      {},
      job.label || "—",
      job.retry_of ? el("div", { class: "hint" }, `retry of #${job.retry_of}`) : null
    ),
    el("td", {}, num(job.source, "—")),
    el("td", {}, num(job.instance_id, "—")),
    el("td", { class: "nowrap" }, fmtTime(job.created_at)),
    el("td", { class: "nowrap" }, fmtTime(job.started_at)),
    el("td", { class: "nowrap" }, jobDuration(job)),
    el(
      "td",
      {},
      job.status === "failed" || job.status === "cancelled"
        ? el("span", { class: "job-error" }, jobErrorText(job, job.status))
        : num(job.progress, "")
    ),
    el("td", { class: "nowrap" }, ...jobActions(job))
  );
}

function renderQueue() {
  const container = $("#queue-list");
  if (!container) return;
  const jobs = queueView.jobs;
  if (!jobs.length) {
    container.replaceChildren(
      el(
        "p",
        { class: "hint" },
        queueView.filter === "all"
          ? "The queue is empty. Search or Grab something and it shows up here."
          : "No job matches this filter."
      )
    );
    return;
  }
  container.replaceChildren(
    el(
      "table",
      { class: "queue-table" },
      el(
        "thead",
        {},
        el(
          "tr",
          {},
          [
            "#",
            "Status",
            "Kind",
            "Job",
            "Source",
            "Instance",
            "Created",
            "Started",
            "Duration",
            "Progress / error",
            "",
          ].map((h) => el("th", {}, h))
        )
      ),
      el("tbody", {}, ...jobs.map(queueRow))
    )
  );
}

/* --- the job drawer -------------------------------------------------- */

let drawerJobId = null;

function closeJobDrawer() {
  drawerJobId = null;
  const drawer = $("#job-drawer");
  if (drawer) drawer.hidden = true;
}

async function openJobDrawer(id) {
  const drawer = $("#job-drawer");
  if (!drawer) return;
  drawerJobId = id;
  drawer.hidden = false;
  $("#job-drawer-title").textContent = `Job #${id}`;
  $("#job-drawer-meta").replaceChildren(el("p", { class: "hint" }, "Loading…"));
  $("#job-drawer-body").replaceChildren();
  setResult("#job-drawer-status", "", true);
  try {
    const response = await api(`/api/jobs/${id}`);
    if (drawerJobId !== id) return;
    renderJobDrawer(response.job);
    if (!FINISHED_STATUSES.has(response.job.status)) {
      const redraw = (job) => {
        if (drawerJobId === job.id) renderJobDrawer(job);
      };
      watchJob(id, { onUpdate: redraw, onFinish: redraw });
    }
  } catch (e) {
    $("#job-drawer-meta").replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
  }
}

function renderJobDrawer(job) {
  $("#job-drawer-title").textContent = `Job #${job.id} · ${job.label || jobKindLabel(job.kind)}`;
  const rows = [
    ["Status", jobStatusText(job)],
    ["Kind", jobKindLabel(job.kind) + (jobKindHint(job) ? ` · ${jobKindHint(job)}` : "")],
    ["Source", num(job.source)],
    ["Instance", num(job.instance_id)],
    ["Created", fmtTime(job.created_at)],
    ["Started", fmtTime(job.started_at)],
    ["Finished", fmtTime(job.finished_at)],
    ["Duration", jobDuration(job)],
    ["Attempt", num(job.attempt, 1)],
  ];
  if (job.retry_of) rows.push(["Retry of", `#${job.retry_of}`]);
  $("#job-drawer-meta").replaceChildren(
    el(
      "div",
      { class: "cards" },
      ...rows.map(([k, v]) =>
        el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, String(v)))
      )
    ),
    job.progress && !FINISHED_STATUSES.has(job.status)
      ? el("p", { class: "hint" }, job.progress)
      : null,
    job.error ? el("div", { class: "conflicts" }, jobErrorText(job)) : null,
    el("p", {}, ...jobActions(job).slice(1)),
    el(
      "details",
      {},
      el("summary", {}, "Parameters"),
      el("pre", {}, JSON.stringify(job.params || {}, null, 2))
    )
  );
  renderJobResult(job, $("#job-drawer-body"));
}

/* Draw a finished job's result with the renderers the originating page
   uses, so the drawer has the same ranking, links and Grab buttons. */
function renderJobResult(job, box) {
  if (!box) return;
  const result = job.result;
  if (!result) {
    box.replaceChildren(
      el(
        "p",
        { class: "hint" },
        FINISHED_STATUSES.has(job.status) ? "No result." : "The result appears here when the job finishes."
      )
    );
    return;
  }
  const params = job.params || {};
  const ctx = {
    instanceId: job.instance_id || params.instance_id || result.instance_id,
    statusNode: $("#job-drawer-status"),
    setStatus: (m, ok) => setResult("#job-drawer-status", m, ok),
  };
  const content = el("div", {});
  try {
    switch (job.kind) {
      case "search":
      case "grab_best":
      case "grab_release":
        if (result.candidates) renderSelectionResult(result, content, ctx);
        else if (result.series && result.seasons) renderSeriesResult(result, content, ctx);
        else content.appendChild(el("pre", {}, JSON.stringify(result, null, 2)));
        break;
      case "seerr_select":
        renderSeerrPayload(result, content, ctx);
        break;
      case "seerr_fulfil":
        renderSeerrFulfilResult(result, content);
        break;
      case "automatic_pass":
        content.appendChild(el("p", { class: "hint" }, automaticSummaryText(result)));
        content.appendChild(renderAutomaticResults(result.results || [], el("div", {})));
        break;
      case "seerr_pass":
        content.appendChild(el("p", { class: "hint" }, seerrPassSummaryText(result)));
        content.appendChild(renderSeerrResults(result.results || [], el("div", {})));
        break;
      default:
        /* Kinds this page does not know yet: still use the selection
           renderer when the result is a selection. */
        if (result.candidates) renderSelectionResult(result, content, ctx);
        else if (Array.isArray(result.results))
          content.appendChild(renderSeerrResults(result.results, el("div", {}), "Outcome"));
        else content.appendChild(el("pre", {}, JSON.stringify(result, null, 2)));
    }
  } catch (e) {
    content.replaceChildren(el("p", { class: "result bad" }, "Could not draw this result: " + e.message));
  }
  box.replaceChildren(
    content,
    el("details", {}, el("summary", {}, "Raw result"), el("pre", {}, JSON.stringify(result, null, 2)))
  );
}

/* A seerr_fulfil job (queued by Approve, or by the request endpoint
   /fulfil): {request_id, request: compact request, results: [per-request
   outcome]}. Shows the request, what happened to it, and opens it in the
   Requests panel for a manual search. */
function renderSeerrFulfilResult(result, content) {
  const request = result.request || {};
  const title =
    request.title
      ? `${request.title}${request.year ? ` (${request.year})` : ""}`
      : `Seerr request #${num(result.request_id, "?")}`;
  content.appendChild(
    el(
      "p",
      {},
      el("strong", {}, title),
      request.is4k ? el("span", { class: "badge" }, "4K") : null,
      request.status_label ? el("span", { class: "hint" }, ` · ${request.status_label}`) : null,
      " ",
      ...openInLinks(request.links, request.type === "movie" ? "radarr" : "sonarr")
    )
  );
  const results = Array.isArray(result.results) ? result.results : [];
  if (results.length) content.appendChild(renderSeerrResults(results, el("div", {}), "Outcome"));
  else content.appendChild(el("p", { class: "hint" }, "Nothing to do for this request."));
  if (request.id !== undefined && request.id !== null)
    content.appendChild(
      el(
        "p",
        {},
        el(
          "button",
          {
            class: "small",
            onclick: () => {
              closeJobDrawer();
              showTab("requests");
              openSeerrRequest(request);
            },
          },
          "Open in the Requests panel"
        )
      )
    );
}

function automaticSummaryText(summary) {
  return `${num(summary.instances, 0)} instance(s) in ${fmtDuration(summary.duration_ms)}${
    summary.dry_run ? " (dry run)" : ""
  }`;
}

function seerrPassSummaryText(summary) {
  return `${num(summary.approved, 0)} approved, ${num(summary.fulfilled, 0)} ${
    summary.dry_run ? "searched (dry run)" : "auto-grabbed"
  } in ${fmtDuration(summary.duration_ms)}`;
}

/* --- Events tab ------------------------------------------------------ */

const EVENT_TYPE_CHIPS = ["job", "search", "grab", "seerr", "automatic", "webhook", "auth", "config", "log"];

const eventsView = {
  events: [], // newest first
  lastId: 0,
  type: "",
  paused: false,
  pending: [], // newest first, held back while paused
  loaded: false,
};

function eventFilterQuery() {
  const parts = [];
  const level = ($("#events-level") && $("#events-level").value) || "info";
  if (level && level !== "info") parts.push(`level=${encodeURIComponent(level)}`);
  if (eventsView.type) parts.push(`type=${encodeURIComponent(eventsView.type)}`);
  const q = (($("#events-q") && $("#events-q").value) || "").trim();
  if (q) parts.push(`q=${encodeURIComponent(q)}`);
  return parts;
}

function renderEventTypeChips() {
  const container = $("#events-types");
  if (!container) return;
  container.replaceChildren(
    el(
      "button",
      { class: "chip" + (eventsView.type ? "" : " active"), onclick: () => setEventType("") },
      "all"
    ),
    ...EVENT_TYPE_CHIPS.map((t) =>
      el(
        "button",
        {
          class: "chip" + (eventsView.type === t ? " active" : ""),
          onclick: () => setEventType(eventsView.type === t ? "" : t),
        },
        t
      )
    )
  );
}

function setEventType(type) {
  eventsView.type = type;
  renderEventTypeChips();
  return loadEvents();
}

/* A full load with the current filters: the newest 200 matching events. */
async function loadEvents() {
  const query = ["limit=200", ...eventFilterQuery()].join("&");
  try {
    const data = await api(`/api/events?${query}`);
    const events = (data.events || []).slice().reverse();
    eventsView.events = events.slice(0, EVENTS_MAX_ROWS);
    eventsView.pending = [];
    eventsView.lastId = Math.max(data.last_id || 0, events.length ? events[0].id : 0);
    eventsView.loaded = true;
    renderEvents();
  } catch (e) {
    const list = $("#events-list");
    if (list) list.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
  }
}

/* Follow: only what is newer than the last event seen. */
async function pollEvents() {
  const follow = $("#events-follow");
  if (follow && follow.checked === false) return;
  if (!eventsView.loaded) return loadEvents();
  const limit = 500;
  const query = [`since_id=${eventsView.lastId}`, `limit=${limit}`, ...eventFilterQuery()].join("&");
  try {
    const data = await api(`/api/events?${query}`);
    const batch = data.events || [];
    const fresh = batch.filter((e) => e.id > eventsView.lastId).reverse();
    const newest = fresh.length ? fresh[0].id : 0;
    /* A full batch means more is waiting: continue from what arrived. Otherwise
       jump to the latest id overall, so filtered-out events are not asked for
       again. */
    eventsView.lastId =
      batch.length >= limit
        ? Math.max(eventsView.lastId, newest)
        : Math.max(eventsView.lastId, data.last_id || 0, newest);
    if (!fresh.length) return;
    if (eventsView.paused) {
      eventsView.pending = fresh.concat(eventsView.pending).slice(0, EVENTS_MAX_ROWS);
      renderEventsSummary();
      return;
    }
    eventsView.events = fresh.concat(eventsView.events).slice(0, EVENTS_MAX_ROWS);
    renderEvents();
  } catch (_) {
    /* try again on the next tick */
  }
}

function toggleEventsPause() {
  eventsView.paused = !eventsView.paused;
  if (!eventsView.paused && eventsView.pending.length) {
    eventsView.events = eventsView.pending.concat(eventsView.events).slice(0, EVENTS_MAX_ROWS);
    eventsView.pending = [];
    renderEvents();
  } else renderEventsSummary();
}

function renderEventsSummary() {
  const pause = $("#events-pause");
  if (pause)
    pause.textContent = eventsView.paused
      ? `Resume${eventsView.pending.length ? ` (${eventsView.pending.length} new)` : ""}`
      : "Pause";
  const follow = $("#events-follow");
  const summary = $("#events-summary");
  if (summary)
    summary.textContent =
      `${eventsView.events.length} event(s)` +
      (eventsView.paused ? " · paused" : follow && follow.checked === false ? "" : " · following");
}

function levelBadge(level) {
  const cls = level === "error" ? "badge bad" : level === "warn" ? "badge warn" : "badge";
  return el("span", { class: cls }, level || "info");
}

function eventRow(e, compact) {
  const jobLink =
    e.job_id !== null && e.job_id !== undefined
      ? el("button", { class: "small linklike", onclick: () => openJobDrawer(e.job_id) }, `#${e.job_id}`)
      : "";
  if (compact)
    return el(
      "tr",
      { class: `event-row event-${e.level || "info"}` },
      el("td", { class: "nowrap" }, fmtTime(e.ts)),
      el("td", {}, levelBadge(e.level)),
      el("td", {}, e.message || e.type),
      el("td", {}, jobLink)
    );
  return el(
    "tr",
    { class: `event-row event-${e.level || "info"}` },
    el("td", { class: "nowrap" }, fmtTime(e.ts)),
    el("td", {}, levelBadge(e.level)),
    el("td", { class: "nowrap" }, e.type || ""),
    el("td", {}, e.message || ""),
    el("td", {}, num(e.media, "")),
    el("td", {}, num(e.instance_id, "")),
    el("td", {}, jobLink)
  );
}

function renderEvents() {
  renderEventsSummary();
  const container = $("#events-list");
  if (!container) return;
  if (!eventsView.events.length) {
    container.replaceChildren(el("p", { class: "hint" }, "No event matches these filters yet."));
    return;
  }
  container.replaceChildren(
    el(
      "table",
      { class: "events-table" },
      el(
        "thead",
        {},
        el(
          "tr",
          {},
          ["Time", "Level", "Type", "Message", "Media", "Instance", "Job"].map((h) => el("th", {}, h))
        )
      ),
      el("tbody", {}, ...eventsView.events.slice(0, EVENTS_MAX_ROWS).map((e) => eventRow(e, false)))
    )
  );
}

/* --- dashboard: queue counts and recent activity --------------------- */

async function loadDashboardQueue() {
  const container = $("#dashboard-queue");
  if (!container) return;
  try {
    const data = await api("/api/jobs?limit=5");
    const c = data.counts || {};
    state.queueCounts = Object.assign({}, state.queueCounts || {}, c);
    renderQueueBadge(state.queueCounts);
    const cards = [
      ["Running", num(c.running, 0)],
      ["Queued", num(c.queued, 0)],
      ["Succeeded", num(c.succeeded, 0)],
      ["Failed", num(c.failed, 0)],
      ["Cancelled", num(c.cancelled, 0)],
    ];
    const jobs = data.jobs || [];
    container.replaceChildren(
      el(
        "div",
        { class: "cards" },
        ...cards.map(([k, v]) =>
          el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, String(v)))
        )
      ),
      jobs.length
        ? el(
            "table",
            { class: "queue-table compact" },
            el(
              "tbody",
              {},
              ...jobs.map((job) =>
                el(
                  "tr",
                  { class: `job-row job-${job.status}` },
                  el("td", {}, `#${job.id}`),
                  el("td", {}, jobStatusPill(job)),
                  el("td", {}, job.label || jobKindLabel(job.kind)),
                  el("td", { class: "nowrap" }, jobDuration(job)),
                  el("td", {}, actionButton("View", "small", () => openJobDrawer(job.id)))
                )
              )
            )
          )
        : null,
      el("p", {}, el("button", { class: "small", onclick: () => showTab("queue") }, "Open queue"))
    );
  } catch (e) {
    container.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
  }
}

async function loadDashboardActivity() {
  const container = $("#dashboard-activity");
  if (!container) return;
  try {
    const data = await api("/api/events?limit=10");
    const events = (data.events || []).slice().reverse();
    if (!events.length) {
      container.replaceChildren(el("p", { class: "hint" }, "Nothing has happened yet."));
      return;
    }
    container.replaceChildren(
      el("table", { class: "events-table compact" }, el("tbody", {}, ...events.map((e) => eventRow(e, true)))),
      el("p", {}, el("button", { class: "small", onclick: () => showTab("events") }, "All events"))
    );
  } catch (e) {
    container.replaceChildren(el("p", { class: "result bad" }, describeApiError(e)));
  }
}

/* --- queue settings -------------------------------------------------- */

const queueSchema = [
  {
    key: "workers",
    label: "Jobs running at once",
    type: "int",
    min: 1,
    max: 8,
    hint: "1–8, default 2",
  },
  {
    key: "per_instance",
    label: "Jobs at once per Sonarr/Radarr instance",
    type: "int",
    min: 1,
    max: 4,
    hint: "1–4, default 1; searches hit every indexer, so keep this low",
  },
  {
    key: "keep_finished",
    label: "Finished jobs to keep",
    type: "int",
    min: 50,
    max: 5000,
    hint: "50–5000, default 500; older ones are dropped",
  },
];

function queueSettings() {
  return Object.assign(
    { workers: 2, per_instance: 1, keep_finished: 500 },
    (state.config && state.config.queue) || {}
  );
}

function queueSettingsFromForm() {
  const v = readForm($("#queue-form"), queueSchema);
  const clamp = (x, lo, hi, d) => (Number.isFinite(x) ? Math.min(hi, Math.max(lo, x)) : d);
  return {
    workers: clamp(v.workers, 1, 8, 2),
    per_instance: clamp(v.per_instance, 1, 4, 1),
    keep_finished: clamp(v.keep_finished, 50, 5000, 500),
  };
}

/* --- background polling ---------------------------------------------- */

const pollLoops = {};

/* A setTimeout chain (not setInterval) so a slow answer never stacks up
   requests, and hidden browser tabs skip the work. */
function startLoop(name, ms, fn) {
  if (pollLoops[name]) return;
  pollLoops[name] = true;
  const tick = () => {
    const visible = typeof document.hidden === "undefined" || !document.hidden;
    Promise.resolve()
      .then(() => (visible ? fn() : null))
      .catch(() => {})
      .finally(() => setTimeout(tick, ms));
  };
  setTimeout(tick, ms);
}

function startBackgroundPolling() {
  pollQueueBadge();
  startLoop("badge", BADGE_POLL_MS, async () => {
    await pollQueueBadge();
    if (state.activeTab === "dashboard")
      await Promise.all([loadDashboardQueue(), loadDashboardActivity()]);
  });
  startLoop("queue", QUEUE_POLL_MS, async () => {
    if (state.activeTab === "queue") await loadQueue();
  });
  startLoop("events", EVENTS_POLL_MS, async () => {
    if (state.activeTab === "events") await pollEvents();
  });
}

function wireQueue() {
  const reload = $("#queue-reload");
  if (reload) reload.addEventListener("click", loadQueue);
  const clear = $("#queue-clear");
  if (clear) clear.addEventListener("click", clearFinishedJobs);
  const close = $("#job-drawer-close");
  if (close) close.addEventListener("click", closeJobDrawer);
  if (document.addEventListener)
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && drawerJobId !== null) closeJobDrawer();
    });

  const level = $("#events-level");
  if (level) level.addEventListener("change", loadEvents);
  const q = $("#events-q");
  if (q) {
    q.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        loadEvents();
      }
    });
    q.addEventListener("change", loadEvents);
  }
  const follow = $("#events-follow");
  if (follow) follow.addEventListener("change", renderEventsSummary);
  const pause = $("#events-pause");
  if (pause) pause.addEventListener("click", toggleEventsPause);
  const reloadEvents = $("#events-reload");
  if (reloadEvents) reloadEvents.addEventListener("click", loadEvents);

  const save = $("#save-queue");
  if (save)
    save.addEventListener("click", () =>
      saveConfigPatch({ queue: queueSettingsFromForm() }, "#queue-status").then((ok) => {
        if (ok) buildForm($("#queue-form"), queueSchema, queueSettings());
      })
    );

  renderQueueFilters();
  renderEventTypeChips();
}

/* ------------------------------------------------------------------ */
/* wiring                                                             */
/* ------------------------------------------------------------------ */

function showTab(name) {
  state.activeTab = name;
  for (const section of document.querySelectorAll(".tab")) {
    section.classList.toggle("active", section.id === "tab-" + name);
  }
  for (const button of document.querySelectorAll("#tabs button")) {
    button.classList.toggle("active", button.dataset.tab === name);
  }
  if (name === "history") loadHistory();
  if (name === "logs") loadLogs();
  if (name === "security") loadSecurity();
  if (name === "queue") loadQueue();
  if (name === "events") {
    if (eventsView.loaded) pollEvents();
    else loadEvents();
  }
  if (name === "dashboard") {
    loadStatus();
    loadAutomatic();
    renderGetStarted();
    loadDashboardQueue();
    loadDashboardActivity();
  }
}

function wire() {
  for (const button of document.querySelectorAll("#tabs button")) {
    button.addEventListener("click", () => showTab(button.dataset.tab));
  }

  $("#btn-search").addEventListener("click", () => runCurrentSelection(false, $("#btn-search")));
  $("#btn-grab").addEventListener("click", () => {
    if (confirm("Search and grab the best release now?"))
      runCurrentSelection(true, $("#btn-grab"));
  });
  $("#load-wanted").addEventListener("click", loadWanted);

  /* library browsing */
  $("#library-search").addEventListener("click", searchLibrary);
  $("#library-q").addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      searchLibrary();
    }
  });
  /* Items belong to one instance, so switching instance drops the pick. */
  $("#select-instance").addEventListener("change", () => {
    setPicked(null);
    $("#library-results").replaceChildren();
    $("#library-picked").replaceChildren();
    setResult("#library-status", "", true);
  });
  setPicked(null);

  $("#save-nl").addEventListener("click", () =>
    saveConfigPatch({ nl_preferences: $("#nl-preferences").value }, "#nl-status")
  );

  $("#propose-rules").addEventListener("click", async () => {
    setResult("#nl-status", "asking the model…", true);
    try {
      const proposal = await api("/api/rules/propose", {
        method: "POST",
        body: JSON.stringify({ text: $("#nl-preferences").value }),
      });
      setResult("#nl-status", "proposal ready — nothing saved yet", true);
      renderProposal(proposal);
    } catch (e) {
      setResult("#nl-status", e.message, false);
    }
  });

  $("#save-rules").addEventListener("click", () =>
    saveConfigPatch(
      {
        hard_rules: readForm($("#hard-rules-form"), hardRulesSchema),
        preferences: readForm($("#preferences-form"), preferencesSchema),
        weights: readForm($("#weights-form"), weightsSchema),
      },
      "#rules-status"
    ).then((ok) => {
      if (ok) renderRules();
    })
  );

  $("#save-llm").addEventListener("click", () =>
    saveConfigPatch(
      {
        llm: readForm($("#llm-form"), llmSchema),
        automatic: readForm($("#automatic-form"), automaticSchema),
        seasons: seasonsFromForm(),
      },
      "#llm-status"
    ).then((ok) => {
      if (ok) {
        buildForm($("#llm-form"), llmSchema, state.config.llm);
        buildForm($("#automatic-form"), automaticSchema, state.config.automatic);
        buildForm($("#seasons-form"), seasonsSchema, seasonsToForm(state.config.seasons));
        loadAutomatic();
      }
    })
  );

  $("#save-network").addEventListener("click", () =>
    saveConfigPatch(
      { network: readForm($("#network-form"), networkSchema) },
      "#network-status"
    ).then((ok) => {
      if (ok) buildForm($("#network-form"), networkSchema, state.config.network);
    })
  );

  $("#add-sonarr").addEventListener("click", () => addInstance("sonarr"));
  $("#add-radarr").addEventListener("click", () => addInstance("radarr"));
  $("#save-instances").addEventListener("click", saveInstances);

  $("#test-llm").addEventListener("click", async () => {
    setResult("#llm-test-result", "testing…", true);
    try {
      const r = await api("/api/llm/test", { method: "POST" });
      setResult("#llm-test-result", `${r.model} replied: ${r.reply}`, true);
    } catch (e) {
      setResult("#llm-test-result", e.message, false);
    }
  });

  /* A pass is a queued job like everything else; its summary is drawn
     when it finishes. */
  $("#run-automatic").addEventListener("click", () =>
    runJob(
      "automatic_pass",
      {},
      {
        button: $("#run-automatic"),
        statusNode: $("#automatic-run-result"),
        describeDone: (summary) => automaticSummaryText(summary),
        onResult: (summary) => {
          renderAutomaticResults(summary.results || []);
          loadAutomatic();
        },
      }
    )
  );

  $("#reload-history").addEventListener("click", loadHistory);
  $("#reload-logs").addEventListener("click", loadLogs);

  wireQueue();

  $("#auth-save").addEventListener("click", async () => {
    const password = $("#auth-new-password").value;
    if (!password) return setResult("#auth-status", "Enter a new password", false);
    const body = { password, username: $("#auth-username").value.trim() };
    const current = $("#auth-current-password").value;
    if (current) body.current_password = current;
    setResult("#auth-status", "saving…", true);
    try {
      state.security = await api("/api/security/credentials", {
        method: "POST",
        body: JSON.stringify(body),
      });
      $("#auth-new-password").value = "";
      $("#auth-current-password").value = "";
      renderSecurity();
      setResult("#auth-status", "account updated", true);
    } catch (e) {
      setResult("#auth-status", e.message, false);
    }
  });

  $("#auth-logout").addEventListener("click", async () => {
    try {
      await api("/logout", { method: "POST", headers: { Accept: "application/json" } });
    } finally {
      window.location.href = "/login";
    }
  });

  $("#api-key-copy").addEventListener("click", async () => {
    const key = $("#api-key").value;
    try {
      await navigator.clipboard.writeText(key);
      setResult("#api-key-status", "copied", true);
    } catch (_) {
      $("#api-key").select();
      setResult("#api-key-status", "press Ctrl+C to copy", true);
    }
  });

  $("#api-key-regenerate").addEventListener("click", async () => {
    if (!confirm("Regenerate the API key? Existing webhook URLs and scripts will stop working.")) return;
    setResult("#api-key-status", "regenerating…", true);
    try {
      state.security = await api("/api/security/apikey", { method: "POST" });
      renderSecurity();
      setResult("#api-key-status", "regenerated — update your webhook URLs", true);
    } catch (e) {
      setResult("#api-key-status", e.message, false);
    }
  });

  $("#auth-required").addEventListener("change", async (event) => {
    const value = event.target.checked;
    if (!value && !confirm("Disable authentication? Anyone who can reach this port will have full access.")) {
      event.target.checked = true;
      return;
    }
    setResult("#auth-required-status", "saving…", true);
    try {
      state.security = await api("/api/security/auth-required", {
        method: "POST",
        body: JSON.stringify({ auth_required: value }),
      });
      renderSecurity();
      setResult("#auth-required-status", value ? "authentication required" : "authentication disabled", true);
    } catch (e) {
      setResult("#auth-required-status", e.message, false);
      renderSecurity();
    }
  });
}

async function main() {
  state.activeTab = "dashboard";
  wire();
  await loadStatus();
  try {
    await loadConfig();
  } catch (e) {
    toast("Could not load configuration: " + e.message, true);
    return;
  }
  loadSecurity();
  loadAutomatic();
  loadDashboardQueue();
  loadDashboardActivity();
  startBackgroundPolling();
}

main();

/* ------------------------------------------------------------------ */
/* Seerr / Overseerr / Jellyseerr requests                            */
/* ------------------------------------------------------------------ */

const seerrSchema = [
  { key: "enabled", label: "Seerr integration enabled", type: "bool" },
  { key: "url", label: "Seerr URL", type: "text", placeholder: "http://seerr:5055" },
  {
    key: "api_key",
    label: "Seerr API key",
    type: "text",
    password: true,
    hint: "admin key (Settings → General); leave ******** to keep",
  },
  { key: "poll_interval_seconds", label: "Poll interval (seconds)", type: "int", hint: "minimum 30" },
  { key: "auto_approve", label: "Approve pending requests", type: "bool", hint: "off = you approve in Seerr" },
  { key: "process_approved", label: "Fulfil approved requests", type: "bool" },
  { key: "grab", label: "Actually grab", type: "bool", hint: "off = dry run" },
  { key: "max_requests_per_run", label: "Max requests per run", type: "int" },
];

function seerrRequestLabel(r) {
  const title = r.title || `${r.type || "request"} #${r.id}`;
  const year = r.year ? ` (${r.year})` : "";
  const seasons = (r.seasons || []).length ? ` — season ${r.seasons.join(", ")}` : "";
  return `${title}${year}${seasons}${r.is4k ? " [4K]" : ""}`;
}

function renderSeerrDashboard() {
  const container = $("#seerr-dashboard");
  if (!container) return;
  const s = state.seerr;
  if (!s) {
    container.replaceChildren(el("p", { class: "hint" }, "Loading…"));
    return;
  }
  if (!s.enabled) {
    container.replaceChildren(
      el(
        "p",
        { class: "hint" },
        "Off. Configure it on the Requests tab to search and grab Seerr requests."
      )
    );
    return;
  }
  const rows = [
    ["Seerr", s.configured ? s.url : s.detail],
    ["Pending", num(state.seerrCounts && state.seerrCounts.pending, "—")],
    ["Waiting for a release", num(state.seerrCounts && state.seerrCounts.processing, "—")],
    ["Approving", s.auto_approve ? "automatic" : "manual"],
    ["Grabbing", s.grab ? "yes" : "no (dry run)"],
    ["Last run", num(s.last_run_at)],
  ];
  container.replaceChildren(
    el(
      "div",
      { class: "cards" },
      ...rows.map(([k, v]) => el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, v)))
    )
  );
}

function renderSeerrPoller() {
  const container = $("#seerr-poller");
  if (!container) return;
  const s = state.seerr || {};
  const rows = [
    ["Enabled", s.enabled ? "yes" : "no"],
    ["Connection", s.configured ? "configured" : s.detail || "—"],
    ["Interval", s.interval_seconds ? `${s.interval_seconds}s` : "—"],
    ["Approving", s.auto_approve ? "automatic" : "manual"],
    ["Searching approved requests", s.process_approved ? "yes" : "no"],
    ["Grabbing", s.grab ? "yes" : "no (dry run)"],
    ["Runs", num(s.runs, 0)],
    ["Last run", num(s.last_run_at)],
    ["Next run", num(s.next_run_at)],
    ["Last error", num(s.last_error, "none")],
  ];
  container.replaceChildren(
    el(
      "div",
      { class: "cards" },
      ...rows.map(([k, v]) => el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, v)))
    )
  );
  renderSeerrResults((s.last_results || []).slice(0, 25));
}

/* One line per season of a TV request the poller worked on: what Pickarr did
   with it.  The shape comes from Fulfil.season_to_compact. */
function seasonOutcomeLine(s) {
  const season = `S${String(s.season_number).padStart(2, "0")}`;
  if (s.kind === "skipped") return `${season}: skipped (${s.reason || "nothing to do"})`;
  if (s.kind === "episodes")
    return `${season}: ${s.episodes} episode(s), ${s.grabbed} grabbed (${s.missing}/${s.total} missing)`;
  const what = s.selected || "no usable release";
  const state = s.grab_error ? `grab failed: ${s.grab_error}` : s.grabbed ? "grabbed" : "not grabbed";
  return `${season}: pack — ${what} (${state})`;
}

/* Draws into [target] (default: the Requests tab's last-pass table) and
   returns it, so the job drawer can reuse it. */
function renderSeerrResults(results, target, heading) {
  const container = target || $("#seerr-results");
  if (!container) return container;
  if (!results.length) {
    container.replaceChildren();
    return container;
  }
  container.replaceChildren(
    el("h4", {}, heading || "Last pass"),
    el(
      "table",
      {},
      el("thead", {}, el("tr", {}, ["Item", "Outcome", "Grabbed"].map((h) => el("th", {}, h)))),
      el(
        "tbody",
        {},
        ...results.map((r) =>
          el(
            "tr",
            {},
            el("td", {}, num(r.request || r.media || r.instance, "—")),
            el(
              "td",
              {},
              r.error || r.skipped || r.action || r.selected || r.reason || "—",
              Array.isArray(r.seasons) && r.seasons.length
                ? el(
                    "div",
                    { class: "hint" },
                    ...r.seasons.map((s) => el("div", {}, seasonOutcomeLine(s)))
                  )
                : null
            ),
            el("td", {}, r.grabbed === undefined ? "—" : r.grabbed ? "yes" : "no")
          )
        )
      )
    )
  );
  return container;
}

/* [statusNode] is the per-row <span> the outcome is written into. */
async function seerrAction(requestId, action, statusNode) {
  const say = (message, ok) => {
    if (!statusNode) return;
    statusNode.textContent = message || "";
    statusNode.className = "result" + (message ? (ok ? " ok" : " bad") : "");
  };
  say(`${action}…`, true);
  try {
    const r = await api(`/api/seerr/requests/${requestId}/${action}`, { method: "POST" });
    say(r.action || "done", true);
    loadSeerrStatus();
    if (r.job_id !== null && r.job_id !== undefined) {
      /* Approving queues the fulfilment (search + grab) as a job: show it
         like every other queued job and refresh the lists when it is done. */
      let job;
      try {
        job = (await api(`/api/jobs/${r.job_id}`)).job;
      } catch (e) {
        job = { id: r.job_id, kind: "seerr_fulfil", status: "queued", label: `Seerr request #${requestId}` };
      }
      toastJob(job);
      followJob(job, {
        statusNode: statusNode,
        describeDone: (result) => {
          const outcome = (result.results || [])[0] || {};
          return `${r.action || "approved"}: ${outcome.error || outcome.skipped || outcome.action || outcome.selected || "done"}`;
        },
        onResult: () => {
          loadSeerrRequests();
          loadSeerrStatus();
        },
      });
      pollQueueBadge();
      return;
    }
    /* Nothing was queued (declined): refresh the lists. */
    setTimeout(() => {
      loadSeerrRequests();
      loadSeerrStatus();
    }, 1000);
  } catch (e) {
    say(e.message, false);
    toast(e.message, true);
  }
}

function renderSeerrRequests(containerSelector, payload, kind) {
  const container = $(containerSelector);
  if (!container) return;
  if (payload && payload.error) {
    container.replaceChildren(el("p", { class: "result bad" }, payload.error));
    return;
  }
  const items = (payload && payload.results) || [];
  if (!items.length) {
    container.replaceChildren(el("p", { class: "hint" }, "Nothing here."));
    return;
  }
  container.replaceChildren(
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el(
          "tr",
          {},
          ["Item", "Requested by", "Media", "In the *arr", "Links", "Actions"].map((h) =>
            el("th", {}, h)
          )
        )
      ),
      el(
        "tbody",
        {},
        ...items.map((r) => {
          const status = el("span", { class: "result" });
          /* Search and Grab open the panel below and work the request like the
             Search page. Pickarr refuses to search a request that is still
             pending, so a pending row offers Approve (approve and nothing
             else) and Approve & grab instead. */
          const buttons =
            kind === "pending"
              ? [
                  el(
                    "button",
                    { class: "small", onclick: () => seerrAction(r.id, "approve", status) },
                    "Approve"
                  ),
                  el(
                    "button",
                    { class: "small primary", onclick: () => openSeerrRequest(r, { grab: true }) },
                    "Approve & grab"
                  ),
                  el(
                    "button",
                    {
                      class: "small danger",
                      onclick: () => {
                        if (confirm(`Decline "${seerrRequestLabel(r)}" in Seerr?`))
                          seerrAction(r.id, "decline", status);
                      },
                    },
                    "Decline"
                  ),
                ]
              : [
                  el("button", { class: "small", onclick: () => openSeerrRequest(r) }, "Search"),
                  el(
                    "button",
                    {
                      class: "small primary",
                      onclick: () => {
                        if (confirm("Search and grab the best release now?"))
                          openSeerrRequest(r, { grab: true });
                      },
                    },
                    "Grab"
                  ),
                ];
          return el(
            "tr",
            {},
            el("td", {}, seerrRequestLabel(r)),
            el("td", {}, num(r.requested_by, "—")),
            el("td", {}, num(r.media_status_label, "—")),
            el("td", {}, r.pushed_to_arr ? "yes" : "not yet"),
            el("td", {}, ...openInLinks(r.links)),
            el("td", {}, ...buttons, status)
          );
        })
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* one request, worked like the Select page                            */
/* ------------------------------------------------------------------ */

/* The request currently open in the panel: which one, what it resolved to,
   and which instance the next search or grab applies to. Only one request is
   open at a time. */
let seerrPanel = null;

function seerrPanelStatus(message, ok) {
  setResult("#seerr-select-status", message, ok);
}

function closeSeerrPanel() {
  seerrPanel = null;
  const panel = $("#seerr-request-panel");
  if (panel) panel.hidden = true;
}

/* The params of a seerr_select job (the body POST
   /api/seerr/requests/:id/select used to take). A pending request carries
   approve:true, because the server refuses to select one otherwise. */
function seerrSelectionBody(grab) {
  const pending = !!(seerrPanel && seerrPanel.request && seerrPanel.request.status === 1);
  const body = { grab: !!grab, use_ai: !!$("#seerr-use-ai").checked, approve: pending };
  const instruction = ($("#seerr-instruction").value || "").trim();
  if (instruction) body.instruction = instruction;
  if (seerrPanel && seerrPanel.instanceId) body.instance_id = seerrPanel.instanceId;
  return body;
}

function renderSeerrPanelHeader(request, detail) {
  const head = $("#seerr-panel-header");
  const title = $("#seerr-panel-title");
  if (title) title.textContent = seerrRequestLabel(request);
  if (!head) return;
  const rows = [
    ["Type", request.type || "—"],
    ["Request", request.status_label || "—"],
    ["Media", request.media_status_label || "—"],
    ["Requested by", request.requested_by || "—"],
    ["Seasons", (request.seasons || []).length ? request.seasons.join(", ") : "all"],
    ["In the *arr", request.pushed_to_arr ? "yes" : "not yet"],
  ];
  head.replaceChildren(
    el(
      "div",
      { class: "cards" },
      ...rows.map(([k, v]) =>
        el("div", { class: "card" }, el("div", { class: "k" }, k), el("div", { class: "v" }, v))
      )
    ),
    el("div", {}, ...openInLinks(request.links)),
    detail ? el("p", { class: "hint" }, detail) : null
  );
}

/* What the request maps to in Sonarr/Radarr, with per-season buttons for a
   TV request so one season can be worked on its own. */
function renderSeerrTargets(payload) {
  const container = $("#seerr-panel-targets");
  if (!container) return;
  const targets = payload.targets || [];
  if (!targets.length) {
    container.replaceChildren(el("p", { class: "hint" }, payload.detail || "Nothing to select yet."));
    return;
  }
  container.replaceChildren(
    ...targets.map((t) => {
      const head = el(
        "div",
        {},
        el("strong", {}, t.instance_name || t.instance_id),
        el("span", { class: "hint-inline" }, ` ${t.app || ""} `),
        ...openInLinks(t.links, t.app)
      );
      const body = el("div", {});
      if (t.kind === "movie") {
        body.appendChild(el("div", { class: "hint" }, `movie id ${t.media_id}`));
      } else if (t.kind === "episodes") {
        body.appendChild(
          el("div", { class: "hint" }, `${(t.media_ids || []).length} missing episode(s)`)
        );
      } else if (t.kind === "series") {
        body.appendChild(el("div", { class: "hint" }, `series id ${t.series_id}`));
        body.appendChild(
          el(
            "table",
            {},
            el("thead", {}, el("tr", {}, ["Season", "Missing", ""].map((h) => el("th", {}, h)))),
            el(
              "tbody",
              {},
              ...(t.seasons || []).map((s) =>
                el(
                  "tr",
                  {},
                  el("td", {}, s.season_number === 0 ? "Specials" : `Season ${s.season_number}`),
                  el("td", {}, s.total === undefined ? "—" : `${s.missing} / ${s.total}`),
                  el(
                    "td",
                    {},
                    actionButton("Search", "small", (b) =>
                      runSeerrSelection(
                        false,
                        { instanceId: t.instance_id, seasonNumber: s.season_number },
                        b
                      )
                    ),
                    " ",
                    actionButton("Grab", "small primary", (b) => {
                      if (!confirm(`Search and grab the best pack for season ${s.season_number} now?`))
                        return;
                      runSeerrSelection(
                        true,
                        { instanceId: t.instance_id, seasonNumber: s.season_number },
                        b
                      );
                    })
                  )
                )
              )
            )
          )
        );
      } else {
        body.appendChild(el("div", { class: "hint" }, t.reason || "nothing to select yet"));
      }
      return el("div", { class: "panel" }, head, body);
    })
  );
}

/* Draw a select response with the very components the Select page uses, so a
   request shows the same ranking, explanation and per-candidate Grab
   buttons. [box] and [ctx] default to the request panel; the job drawer
   passes its own. */
function renderSeerrPayload(payload, box, ctx) {
  if (!box) return;
  const c = ctx || {
    instanceId: payload.instance_id,
    statusNode: $("#seerr-select-status"),
    setStatus: seerrPanelStatus,
  };
  if (!c.instanceId) c.instanceId = payload.instance_id;
  if (payload.series) {
    renderSeriesResult(payload.series, box, c);
  } else if (payload.selection) {
    renderSelectionResult(payload.selection, box, c);
  } else if (payload.selections) {
    box.replaceChildren(
      ...payload.selections.map((selection) => {
        const card = el("div", {});
        renderSelectionResult(selection, card, c);
        return el("details", {}, el("summary", {}, selectionLabel(selection)), card);
      })
    );
  } else {
    box.replaceChildren(el("p", { class: "hint" }, "Nothing was selected."));
  }
}

function renderSeerrSelection(payload) {
  renderSeerrPayload(payload, $("#seerr-request-result"));
}

/* Search (grab=false) or grab the open request, as a queued seerr_select
   job. [overrides] picks the instance and, for TV, one season; [button] is
   the button that asked, which shows the job's busy state. */
function runSeerrSelection(grab, overrides, button) {
  if (!seerrPanel) return null;
  const opts = overrides || {};
  if (opts.instanceId) seerrPanel.instanceId = opts.instanceId;
  const params = Object.assign({ request_id: seerrPanel.id }, seerrSelectionBody(grab));
  if (opts.seasonNumber !== undefined) params.season_number = opts.seasonNumber;
  const panelId = seerrPanel.id;
  return runJob("seerr_select", params, {
    button: button || (grab ? $("#seerr-panel-grab") : $("#seerr-panel-search")),
    statusNode: $("#seerr-select-status"),
    waitHint: SEARCH_WAIT_HINT,
    describeDone: (payload) => `${payload.kind || "done"}: ${num(payload.grabbed, 0)} grabbed`,
    isSuccess: (payload) => !grab || (payload.grabbed || 0) > 0,
    onStart: (job) => {
      if (!seerrPanel || seerrPanel.id !== panelId) return;
      seerrPanel.jobId = job.id;
      $("#seerr-request-result").replaceChildren();
    },
    isCurrent: (job) => !!seerrPanel && seerrPanel.id === panelId && seerrPanel.jobId === job.id,
    onResult: (payload) => {
      if (!seerrPanel) return;
      seerrPanel.request = payload.request || seerrPanel.request;
      seerrPanel.instanceId = payload.instance_id || seerrPanel.instanceId;
      renderSeerrPanelHeader(seerrPanel.request);
      renderSeerrSelection(payload);
      if (grab) {
        loadHistory();
        loadSeerrRequests();
        loadSeerrStatus();
      }
    },
  });
}

/* Open the panel for one request: resolve it first (no search), then search
   (and grab) straight away when the user asked for it. */
async function openSeerrRequest(request, options) {
  const opts = options || {};
  const panel = $("#seerr-request-panel");
  if (!panel) return;
  seerrPanel = { id: request.id, request: request, instanceId: null };
  panel.hidden = false;
  renderSeerrPanelHeader(request);
  /* Working a pending request approves it in Seerr first, so say so on the
     buttons rather than letting "Search" approve silently. */
  const pending = request.status === 1;
  const searchButton = $("#seerr-panel-search");
  const grabButton = $("#seerr-panel-grab");
  if (searchButton) searchButton.textContent = pending ? "Approve & search" : "Search";
  if (grabButton) grabButton.textContent = pending ? "Approve & grab" : "Grab";
  $("#seerr-request-result").replaceChildren();
  const useAi = $("#seerr-use-ai");
  if (useAi && state.config && state.config.llm) useAi.checked = !!state.config.llm.enabled;
  $("#seerr-panel-targets").replaceChildren(el("p", { class: "hint" }, "Resolving…"));
  seerrPanelStatus("", true);
  panel.scrollIntoView({ block: "nearest" });
  try {
    const resolved = await api(`/api/seerr/requests/${request.id}/resolve`, { method: "POST" });
    if (!seerrPanel || seerrPanel.id !== request.id) return;
    seerrPanel.request = resolved.request || request;
    const first = (resolved.targets || []).find((t) => t.kind !== "nothing");
    seerrPanel.instanceId = first ? first.instance_id : null;
    renderSeerrPanelHeader(seerrPanel.request, resolved.detail);
    renderSeerrTargets(resolved);
  } catch (e) {
    $("#seerr-panel-targets").replaceChildren(
      el("p", { class: "result bad" }, describeApiError(e))
    );
  }
  if (opts.grab !== undefined) runSeerrSelection(opts.grab, {}, null);
}

async function loadSeerrStatus() {
  try {
    state.seerr = await api("/api/seerr/status");
    renderSeerrDashboard();
    renderSeerrPoller();
  } catch (e) {
    const poller = $("#seerr-poller");
    if (poller) poller.replaceChildren(el("p", { class: "result bad" }, e.message));
  }
}

async function loadSeerrRequests() {
  const fetchFilter = async (filter) => {
    try {
      return await api(`/api/seerr/requests?filter=${filter}&take=30`);
    } catch (e) {
      return { error: e.message };
    }
  };
  const [pending, processing] = await Promise.all([fetchFilter("pending"), fetchFilter("processing")]);
  state.seerrCounts = {
    pending: pending && pending.results ? pending.results.length : undefined,
    processing: processing && processing.results ? processing.results.length : undefined,
  };
  renderSeerrRequests("#seerr-pending", pending, "pending");
  renderSeerrRequests("#seerr-processing", processing, "processing");
  renderSeerrDashboard();
}

function renderSeerrForm() {
  if (state.config && state.config.seerr) buildForm($("#seerr-form"), seerrSchema, state.config.seerr);
}

async function loadSeerrTab() {
  renderSeerrForm();
  await loadSeerrStatus();
  if (state.seerr && state.seerr.configured) loadSeerrRequests();
  else {
    renderSeerrRequests("#seerr-pending", { results: [] }, "pending");
    renderSeerrRequests("#seerr-processing", { results: [] }, "processing");
  }
}

function wireSeerr() {
  const tabButton = document.querySelector('#tabs button[data-tab="requests"]');
  if (tabButton) tabButton.addEventListener("click", loadSeerrTab);

  const save = $("#seerr-save");
  if (save)
    save.addEventListener("click", async () => {
      const ok = await saveConfigPatch({ seerr: readForm($("#seerr-form"), seerrSchema) }, "#seerr-status-result");
      if (ok) {
        renderSeerrForm();
        loadSeerrStatus();
      }
    });

  const test = $("#seerr-test");
  if (test)
    test.addEventListener("click", async () => {
      setResult("#seerr-status-result", "testing…", true);
      try {
        const r = await api("/api/seerr/test", { method: "POST" });
        setResult(
          "#seerr-status-result",
          `Seerr ${r.version} — ${r.pending} pending, ${r.processing} waiting for a release`,
          true
        );
      } catch (e) {
        setResult("#seerr-status-result", e.message, false);
      }
    });

  const run = $("#seerr-run");
  if (run)
    run.addEventListener("click", () =>
      runJob(
        "seerr_pass",
        {},
        {
          button: run,
          statusNode: $("#seerr-run-result"),
          describeDone: (summary) => seerrPassSummaryText(summary),
          onResult: (summary) => {
            renderSeerrResults(summary.results || []);
            loadSeerrStatus();
            loadSeerrRequests();
          },
        }
      )
    );

  const reload = $("#seerr-reload");
  if (reload) reload.addEventListener("click", loadSeerrRequests);

  const close = $("#seerr-panel-close");
  if (close) close.addEventListener("click", closeSeerrPanel);

  const search = $("#seerr-panel-search");
  if (search) search.addEventListener("click", () => runSeerrSelection(false, {}, search));

  const grab = $("#seerr-panel-grab");
  if (grab)
    grab.addEventListener("click", () => {
      if (confirm("Search and grab the best release now?")) runSeerrSelection(true, {}, grab);
    });

  loadSeerrStatus();
}

wireSeerr();
