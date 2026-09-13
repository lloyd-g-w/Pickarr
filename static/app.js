/* Pickarr UI — vanilla JS, no build step, no external dependencies. */

"use strict";

const state = {
  security: null,
  config: null,
  status: null,
  automatic: null,
  lastResult: null,
  proposal: null,
};

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

function toast(message, isError) {
  const t = $("#toast");
  t.textContent = message;
  t.className = isError ? "bad" : "";
  t.hidden = false;
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => (t.hidden = true), isError ? 8000 : 3500);
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
    // The session expired: the server-rendered login page takes over.
    window.location.href = "/login";
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

function renderAutomaticResults(results) {
  const container = $("#automatic-results");
  if (!results.length) {
    container.replaceChildren();
    return;
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

/* The current Select-page target, so the per-candidate Grab buttons know what
   to re-search. */
let selectTarget = null;

async function runSelection(grab) {
  const instanceId = $("#select-instance").value;
  const mediaId = parseInt($("#select-media-id").value, 10);
  if (!instanceId)
    return toast("No enabled instance: add one on the Instances tab first", true);
  if (!Number.isInteger(mediaId) || mediaId < 1)
    return toast("Enter a media id (Radarr movie id, Sonarr episode id)", true);
  const body = {
    grab: grab,
    use_ai: $("#select-use-ai").checked,
  };
  const instruction = $("#select-instruction").value.trim();
  if (instruction) body.instruction = instruction;
  setResult(
    "#select-status",
    grab ? "searching indexers and grabbing…" : "searching indexers…",
    true
  );
  $("#select-result").replaceChildren();
  try {
    const result = await api(`/api/select/${encodeURIComponent(instanceId)}/${mediaId}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    state.lastResult = result;
    selectTarget = { instanceId, mediaId };
    setResult("#select-status", `done in ${result.duration_ms} ms`, true);
    renderSelectionResult(result);
    if (grab) loadHistory();
  } catch (e) {
    setResult("#select-status", describeApiError(e), false);
    toast(describeApiError(e), true);
  }
}

/* Grab a candidate the pipeline did not pick.  The server re-runs the search
   first, because Sonarr/Radarr only accept releases from the last search. */
async function grabCandidate(release, button) {
  if (!selectTarget) return toast("Run a selection first", true);
  if (!confirm(`Tell the instance to grab:\n\n${release.title}`)) return;
  const { instanceId, mediaId } = selectTarget;
  const previous = button.textContent;
  button.disabled = true;
  button.textContent = "grabbing…";
  setResult("#select-status", "re-searching, then grabbing…", true);
  try {
    const result = await api(`/api/grab/${encodeURIComponent(instanceId)}/${mediaId}`, {
      method: "POST",
      body: JSON.stringify({ release_id: release.id }),
    });
    state.lastResult = result;
    setResult(
      "#select-status",
      result.grabbed ? "grabbed" : `not grabbed: ${result.grab_error || "unknown reason"}`,
      result.grabbed
    );
    renderSelectionResult(result);
    loadHistory();
  } catch (e) {
    button.disabled = false;
    button.textContent = previous;
    setResult("#select-status", describeApiError(e), false);
    toast(describeApiError(e), true);
  }
}

function releaseRow(scored, isWinner) {
  const r = scored.release;
  const button = el(
    "button",
    { class: "small", title: "Grab this release instead of the selected one" },
    isWinner ? "Grab again" : "Grab"
  );
  button.addEventListener("click", () => grabCandidate(r, button));
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

function renderSelectionResult(result, target) {
  const container = target || $("#select-result");
  const children = [];
  const method = result.method || {};
  const media = result.media || {};

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
      el(
        "div",
        {},
        el("span", { class: "badge" }, "decided by: " + (method.kind || "?")),
        " ",
        result.llm ? el("span", { class: "badge" }, `confidence ${(result.llm.confidence * 100).toFixed(0)}%`) : null,
        " ",
        el("span", { class: "badge " + (result.grabbed ? "ok" : "") }, result.grabbed ? "grabbed" : "not grabbed")
      ),
      method.llm_error ? el("div", { class: "conflicts" }, "AI unavailable, used deterministic scoring: " + method.llm_error) : null,
      result.grab_error ? el("div", { class: "conflicts" }, "Grab failed: " + result.grab_error) : null
    )
  );

  if (result.selected) {
    const sel = result.selected;
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
      el("tbody", {}, ...result.candidates.map((c) => releaseRow(c, c.release.id === selectedId)))
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
/* seasons and whole series (Sonarr)                                   */
/* ------------------------------------------------------------------ */

function selectedInstance() {
  const id = $("#select-instance").value;
  const instances = (state.config && state.config.instances) || [];
  return instances.find((i) => i.id === id) || null;
}

function selectMode() {
  return $("#select-what").value;
}

/* Seasons only exist in Sonarr, so the extra modes are disabled for a
   Radarr instance. */
function updateSelectMode() {
  const instance = selectedInstance();
  const isSonarr = !instance || instance.app === "sonarr";
  for (const option of $("#select-what").options) {
    if (option.value !== "media") option.disabled = !isSonarr;
  }
  if (!isSonarr && selectMode() !== "media") $("#select-what").value = "media";

  const mode = selectMode();
  $("#select-media-row").hidden = mode !== "media";
  $("#select-series-block").hidden = mode === "media";
  $("#select-season-label").hidden = mode !== "season";
  $("#select-seasons-label").hidden = mode !== "series";
}

function selectionBody(grab) {
  const body = { grab: grab, use_ai: $("#select-use-ai").checked };
  const instruction = $("#select-instruction").value.trim();
  if (instruction) body.instruction = instruction;
  return body;
}

function parsedSeasonList() {
  return $("#select-seasons")
    .value.split(",")
    .map((s) => parseInt(s.trim(), 10))
    .filter((n) => !Number.isNaN(n));
}

async function loadSeasons() {
  const instanceId = $("#select-instance").value;
  const seriesId = parseInt($("#select-series-id").value, 10);
  if (!instanceId) return toast("Configure an instance first", true);
  if (!seriesId || seriesId < 1) return toast("Enter a series id", true);
  const container = $("#seasons-list");
  setResult("#seasons-status", "loading…", true);
  container.replaceChildren();
  try {
    const data = await api(`/api/series/${encodeURIComponent(instanceId)}/${seriesId}`);
    setResult("#seasons-status", "", true);
    renderSeasons(data);
  } catch (e) {
    setResult("#seasons-status", e.message, false);
    toast(e.message, true);
  }
}

function renderSeasons(data) {
  const container = $("#seasons-list");
  const series = data.series || {};
  const seasons = data.seasons || [];
  if (!seasons.length) {
    container.replaceChildren(el("p", { class: "hint" }, "This series has no seasons."));
    return;
  }
  container.replaceChildren(
    el(
      "div",
      { class: "panel" },
      el("strong", {}, series.title || "unknown"),
      series.year ? ` (${series.year})` : "",
      el(
        "div",
        { class: "hint" },
        `${data.missing_episodes ?? "?"} of ${data.total_episodes ?? "?"} episode(s) missing`
      )
    ),
    el(
      "table",
      {},
      el(
        "thead",
        {},
        el("tr", {}, ["Season", "Missing", "On disk", "Monitored", ""].map((h) => el("th", {}, h)))
      ),
      el(
        "tbody",
        {},
        ...seasons.map((s) =>
          el(
            "tr",
            {},
            el("td", {}, s.season_number === 0 ? "Specials" : `Season ${s.season_number}`),
            el("td", {}, `${s.missing_episodes} / ${s.total_episodes}`),
            el("td", {}, s.existing_quality || "—"),
            el("td", {}, s.monitored ? "yes" : "no"),
            el(
              "td",
              {},
              el(
                "button",
                {
                  class: "small",
                  onclick: () => {
                    $("#select-what").value = "season";
                    $("#select-season-number").value = s.season_number;
                    updateSelectMode();
                    runSeasonSelection(false);
                  },
                },
                "Select"
              ),
              " ",
              el(
                "button",
                {
                  class: "small danger",
                  onclick: () => {
                    if (!confirm(`Grab a pack for season ${s.season_number}?`)) return;
                    $("#select-what").value = "season";
                    $("#select-season-number").value = s.season_number;
                    updateSelectMode();
                    runSeasonSelection(true);
                  },
                },
                "Select & grab"
              )
            )
          )
        )
      )
    )
  );
}

async function runSeasonSelection(grab) {
  const instanceId = $("#select-instance").value;
  const seriesId = parseInt($("#select-series-id").value, 10);
  const season = parseInt($("#select-season-number").value, 10);
  if (!instanceId) return toast("Configure an instance first", true);
  if (!seriesId || seriesId < 1) return toast("Enter a series id", true);
  if (Number.isNaN(season) || season < 0) return toast("Enter a season number", true);
  setResult("#select-status", grab ? "selecting a pack and grabbing…" : "selecting a pack…", true);
  $("#select-result").replaceChildren();
  try {
    const result = await api(
      `/api/select/${encodeURIComponent(instanceId)}/season/${seriesId}/${season}`,
      { method: "POST", body: JSON.stringify(selectionBody(grab)) }
    );
    state.lastResult = result;
    setResult("#select-status", `done in ${result.duration_ms} ms`, true);
    renderSelectionResult(result);
    if (grab) loadHistory();
  } catch (e) {
    setResult("#select-status", e.message, false);
    toast(e.message, true);
  }
}

async function runSeriesSelection(grab) {
  const instanceId = $("#select-instance").value;
  const seriesId = parseInt($("#select-series-id").value, 10);
  if (!instanceId) return toast("Configure an instance first", true);
  if (!seriesId || seriesId < 1) return toast("Enter a series id", true);
  const body = selectionBody(grab);
  const seasons = parsedSeasonList();
  if (seasons.length) body.seasons = seasons;
  setResult("#select-status", grab ? "selecting the series and grabbing…" : "selecting the series…", true);
  $("#select-result").replaceChildren();
  try {
    const result = await api(`/api/select/${encodeURIComponent(instanceId)}/series/${seriesId}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    state.lastResult = result;
    const s = result.summary || {};
    setResult("#select-status", `${s.seasons || 0} season(s), ${s.grabbed || 0} grabbed`, true);
    renderSeriesResult(result);
  } catch (e) {
    setResult("#select-status", e.message, false);
    toast(e.message, true);
  }
}

function renderSeriesResult(result) {
  const container = $("#select-result");
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
        `${summary.seasons || 0} season(s) considered · ${summary.selections || 0} selection(s) · ` +
          `${summary.selected || 0} with a winner · ${summary.grabbed || 0} grabbed`
      )
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
      renderSelectionResult(outcome.selection, body);
    } else if (outcome.kind === "episodes") {
      head.appendChild(
        el("span", { class: "badge" }, `${(outcome.selections || []).length} episode selection(s)`)
      );
      for (const selection of outcome.selections || []) {
        const card = el("div", {});
        renderSelectionResult(selection, card);
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

/* The Preview / Select & grab buttons act on whatever mode is selected. */
function runCurrentSelection(grab) {
  switch (selectMode()) {
    case "season":
      return runSeasonSelection(grab);
    case "series":
      return runSeriesSelection(grab);
    default:
      return runSelection(grab);
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
                      $("#select-media-id").value = item.media_id;
                      toast(`Selected ${item.label}`);
                    },
                  },
                  "Use"
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
      container.replaceChildren(el("p", { class: "hint" }, "No selections yet."));
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
            ["When", "Instance", "Item", "Selected", "Size", "Method", "Grabbed"].map((h) => el("th", {}, h))
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
              el("td", {}, e.grabbed ? "yes" : e.grab_error ? "failed" : "no")
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
    "Run a selection",
    "Pick an instance and a movie or episode, preview the ranking, then grab the winner.",
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
/* wiring                                                             */
/* ------------------------------------------------------------------ */

function showTab(name) {
  for (const section of document.querySelectorAll(".tab")) {
    section.classList.toggle("active", section.id === "tab-" + name);
  }
  for (const button of document.querySelectorAll("#tabs button")) {
    button.classList.toggle("active", button.dataset.tab === name);
  }
  if (name === "history") loadHistory();
  if (name === "logs") loadLogs();
  if (name === "security") loadSecurity();
  if (name === "dashboard") {
    loadStatus();
    loadAutomatic();
    renderGetStarted();
  }
}

function wire() {
  for (const button of document.querySelectorAll("#tabs button")) {
    button.addEventListener("click", () => showTab(button.dataset.tab));
  }

  $("#btn-preview").addEventListener("click", () => runCurrentSelection(false));
  $("#btn-grab").addEventListener("click", () => {
    if (confirm("Tell the instance to grab the selected release?")) runCurrentSelection(true);
  });
  $("#load-wanted").addEventListener("click", loadWanted);

  /* seasons / whole series */
  $("#select-what").addEventListener("change", updateSelectMode);
  $("#select-instance").addEventListener("change", updateSelectMode);
  $("#load-seasons").addEventListener("click", loadSeasons);
  updateSelectMode();

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

  $("#run-automatic").addEventListener("click", async () => {
    setResult("#automatic-run-result", "running…", true);
    try {
      const summary = await api("/api/automatic/run", { method: "POST" });
      setResult(
        "#automatic-run-result",
        `${summary.instances} instance(s) in ${summary.duration_ms} ms${summary.dry_run ? " (dry run)" : ""}`,
        true
      );
      renderAutomaticResults(summary.results || []);
      loadAutomatic();
    } catch (e) {
      setResult("#automatic-run-result", e.message, false);
    }
  });

  $("#reload-history").addEventListener("click", loadHistory);
  $("#reload-logs").addEventListener("click", loadLogs);

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
      el("p", { class: "hint" }, "Off. Configure it on the Requests tab to fulfil Seerr requests.")
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
    ["Fulfilling", s.process_approved ? "yes" : "no"],
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

function renderSeerrResults(results) {
  const container = $("#seerr-results");
  if (!container) return;
  if (!results.length) {
    container.replaceChildren();
    return;
  }
  container.replaceChildren(
    el("h4", {}, "Last pass"),
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
            el("td", {}, r.error || r.skipped || r.action || r.selected || r.reason || "—"),
            el("td", {}, r.grabbed === undefined ? "—" : r.grabbed ? "yes" : "no")
          )
        )
      )
    )
  );
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
    /* Approving and fulfilling run the selection in the background, so the
       lists are refreshed a moment later as well. */
    loadSeerrStatus();
    setTimeout(() => {
      loadSeerrRequests();
      loadSeerrStatus();
    }, 4000);
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
        el("tr", {}, ["Item", "Requested by", "Media", "In the *arr", "Actions"].map((h) => el("th", {}, h)))
      ),
      el(
        "tbody",
        {},
        ...items.map((r) => {
          const status = el("span", { class: "result" });
          const buttons =
            kind === "pending"
              ? [
                  el(
                    "button",
                    { class: "small primary", onclick: () => seerrAction(r.id, "approve", status) },
                    "Approve"
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
                  el(
                    "button",
                    { class: "small", onclick: () => seerrAction(r.id, "fulfil", status) },
                    "Fulfil now"
                  ),
                ];
          return el(
            "tr",
            {},
            el("td", {}, seerrRequestLabel(r)),
            el("td", {}, num(r.requested_by, "—")),
            el("td", {}, num(r.media_status_label, "—")),
            el("td", {}, r.pushed_to_arr ? "yes" : "not yet"),
            el("td", {}, ...buttons, status)
          );
        })
      )
    )
  );
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
    run.addEventListener("click", async () => {
      setResult("#seerr-run-result", "running…", true);
      try {
        const summary = await api("/api/seerr/run", { method: "POST" });
        setResult(
          "#seerr-run-result",
          `${summary.approved} approved, ${summary.fulfilled} fulfilled in ${summary.duration_ms} ms${
            summary.dry_run ? " (dry run)" : ""
          }`,
          true
        );
        renderSeerrResults(summary.results || []);
        loadSeerrStatus();
        loadSeerrRequests();
      } catch (e) {
        setResult("#seerr-run-result", e.message, false);
      }
    });

  const reload = $("#seerr-reload");
  if (reload) reload.addEventListener("click", loadSeerrRequests);

  loadSeerrStatus();
}

wireSeerr();
