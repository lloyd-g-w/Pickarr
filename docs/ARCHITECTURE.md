# Pickarr architecture

Pickarr (repo name: Pickarr) is an OCaml sidecar that sits next to Sonarr,
Radarr, Prowlarr and qBittorrent. It talks **only** to Sonarr/Radarr (and an
OpenAI-compatible LLM). Sonarr/Radarr keep owning indexers, download clients
and imports; Pickarr owns *which release gets grabbed*.

```
                 ┌──────────────┐        ┌──────────────┐
   Prowlarr ───► │   Sonarr     │ ◄───── │  Pickarr   │ ───► OpenAI-compatible LLM
                 │   Radarr     │  API   │  (OCaml)     │
   qBittorrent ◄─│              │        └──────────────┘
                 └──────────────┘
```

## Stack

* OCaml 5.2, Dune 3, opam
* Dream (HTTP server) · Lwt (async) · Yojson (JSON) · Cohttp-lwt-unix (HTTP client)
* Alcotest (tests) · Docker (deployment)

## Source layout and ownership

```
bin/main.ml                 executable entry point -> Pickarr_server.Server.main
lib/core/   pickarr_core  pure domain: types, config, title parsing, hard filter,
                            scoring, prompt building, LLM response validation,
                            explainability, pipeline orchestration
lib/arr/    pickarr_arr   typed Sonarr v4 / Radarr v3 API clients + mapping to core types
lib/llm/    pickarr_llm   OpenAI-compatible chat-completions client
lib/server/ pickarr_server Dream routes, JSON config store, UI, automatic mode, webhooks,
                            library browsing and the "open in ..." links (library.ml)
static/                     UI assets served by Dream
test/core, test/arr, test/llm   Alcotest suites (one dune per directory)
docs/API_RESEARCH.md        verified API reference (do not guess endpoints)
vendor/                     upstream OpenAPI specs + C# sources used for verification
```

## Module contracts

These signatures are the contract between the work streams. Implementations
must match them exactly so the pieces link together without changes.

### `Pickarr_core.Types` (done) and `Pickarr_core.Config` (done)

See `lib/core/types.ml` and `lib/core/config.ml`. `Types.release` is the
internal candidate; `Types.media` the item being evaluated;
`Types.selection_result` the pipeline output. `Config.t` is the full persisted
configuration (instances, llm, hard_rules, preferences, weights,
nl_preferences, automatic).

### `Pickarr_core.Title_parser` (owner: arr stream)

```ocaml
type parsed = {
  source : string option;        (* "WEB-DL" | "WEBRip" | "Bluray" | "Remux" | "HDTV" | "DVD" | "CAM" ... *)
  codec : string option;         (* "x264" | "x265" | "AV1" | "VC-1" | "MPEG-2" | "XviD" ...; H.264->"x264", HEVC/H.265->"x265" *)
  audio : string option;         (* "Atmos" | "TrueHD" | "DTS-HD MA" | "DTS-X" | "DTS" | "DDP" | "DD" | "AAC" | "FLAC" | "Opus" *)
  audio_channels : string option;(* "7.1" | "5.1" | "2.0" *)
  hdr : string list;             (* subset of ["HDR10"; "HDR10+"; "HLG"; "HDR"] *)
  dolby_vision : bool;
  dv_profile : string option;    (* "P5" | "P7" | "P8" *)
  resolution : int option;       (* 480 | 576 | 720 | 1080 | 2160 *)
  release_group : string option; (* best-effort, trailing "-GROUP" *)
  is_repack : bool; is_proper : bool;
  languages : string list;       (* "MULTi", "DUAL", "GERMAN", "FRENCH" ... from title only *)
  bit_depth : int option;        (* 8 | 10 *)
}
val parse : string -> parsed
val normalise_codec : string -> string   (* "hevc"/"h265"/"h.265"/"x265" -> "x265"; "h264"/"avc" -> "x264"; "av1" -> "AV1" *)
val normalise_source : string -> string  (* "webdl"/"web-dl"/"web" -> "WEB-DL"; "webrip" -> "WEBRip"; "bluray"/"bdrip"/"brrip"-> "Bluray"; "remux" -> "Remux" *)
```

### `Pickarr_arr` (owner: arr stream)

```ocaml
(* lib/arr/http.ml *)
module Http : sig
  type error =
    | Connection of string              (* DNS / refused / timeout *)
    | Http_status of int * string       (* non-2xx with body *)
    | Json of string                    (* body not JSON / decode failure *)
  val error_to_string : error -> string
  (* [kind] only shapes the timeout message: `Search names
     network.arr_search_timeout_seconds, `Quick names network.arr_timeout_seconds.
     [timeout] defaults to !timeout_seconds (the quick value, kept in step with
     the config by Client.set_timeouts). *)
  type kind = [ `Quick | `Search ]
  val timeout_seconds : float ref
  val get  : base_url:string -> api_key:string -> ?query:(string * string) list -> ?timeout:float -> ?kind:kind -> string -> (Yojson.Safe.t, error) result Lwt.t
  val post : base_url:string -> api_key:string -> ?timeout:float -> ?kind:kind -> string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result Lwt.t
  val put  : base_url:string -> api_key:string -> ?timeout:float -> ?kind:kind -> string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result Lwt.t
end

(* lib/arr/sonarr.ml and lib/arr/radarr.ml: typed resources mirroring the
   OpenAPI schemas (release_resource, episode_resource, series_resource,
   movie_resource, quality_profile_resource, queue_resource, history_resource,
   system_status, ...) with *_of_yojson decoders, and thin endpoint functions
   (see docs/API_RESEARCH.md). *)

(* lib/arr/client.ml: app-agnostic facade used by the server *)
module Client : sig
  type t
  type error = Http.error
  val error_to_string : error -> string
  type timeouts = { quick_seconds : float; search_seconds : float }
  val timeouts_of_network : Pickarr_core.Config.network -> timeouts
  (* App_state.client builds clients from the stored network config and calls
     set_timeouts when it changes, so a raised search timeout applies to the
     next search without a restart. *)
  val create : ?timeouts:timeouts -> Pickarr_core.Config.instance -> t
  val timeouts : t -> timeouts
  val set_timeouts : t -> timeouts -> unit
  val instance : t -> Pickarr_core.Config.instance
  val app : t -> Pickarr_core.Types.app

  (** GET /api/v3/system/status -> (appName, version, instanceName) *)
  val test_connection : t -> (string * string * string, error) result Lwt.t

  (** Sonarr: episodeId (fetches episode + series). Radarr: movieId. *)
  val fetch_media : t -> int -> (Pickarr_core.Types.media, error) result Lwt.t

  (** GET /api/v3/release?episodeId= | ?movieId= mapped to core releases.
      Never filters anything out; rejected releases are returned with
      arr_rejected=true and arr_rejection_reasons populated. *)
  (* Uses timeouts.search_seconds: the interactive search waits for every
     indexer and routinely takes 30-120s. *)
  val search_releases : t -> Pickarr_core.Types.media -> (Pickarr_core.Types.release list, error) result Lwt.t

  (** POST /api/v3/release {guid, indexerId, (+ seriesId/episodeIds or movieId)} *)
  val grab : t -> Pickarr_core.Types.media -> Pickarr_core.Types.release -> (unit, error) result Lwt.t

  (** wanted/missing or wanted/cutoff -> media items (monitored only) *)
  val wanted : t -> kind:[ `Missing | `Cutoff ] -> page:int -> page_size:int
              -> (Pickarr_core.Types.media list * int (* totalRecords *), error) result Lwt.t

  (** media ids (episodeId / movieId) currently in the download queue *)
  val queue_media_ids : t -> (int list, error) result Lwt.t

  (** media ids with a "grabbed" history event in the last [since_hours] *)
  val recently_grabbed_media_ids : t -> since_hours:float -> (int list, error) result Lwt.t

  (** Parse an incoming *arr webhook body into (eventType, media ids). *)
  val parse_webhook : Pickarr_core.Types.app -> Yojson.Safe.t -> (string * int list, string) result
end
```

### `Pickarr_llm` (owner: arr stream)

```ocaml
module Client : sig
  type error =
    | Disabled                          (* llm_enabled=false or no model *)
    | Connection of string
    | Http_status of int * string
    | Bad_response of string            (* not JSON / no choices *)
    | Timeout
  val error_to_string : error -> string

  (** POST {base_url}/chat/completions. Returns the assistant message content
      parsed as JSON (strips ```json fences, tolerates leading/trailing prose
      by extracting the outermost {...}). Honours llm_json_mode, temperature,
      max_tokens, timeout. *)
  val chat_json : Pickarr_core.Config.llm -> system:string -> user:string
                  -> (Yojson.Safe.t, error) result Lwt.t

  (** Free text completion (used by "test LLM connection"). *)
  val chat_text : Pickarr_core.Config.llm -> system:string -> user:string
                  -> (string, error) result Lwt.t
end
```

### `Pickarr_core` pipeline modules (owner: core stream)

```ocaml
(* lib/core/filter.ml — Stage 2: deterministic hard rules, pure *)
module Filter : sig
  val check : Config.hard_rules -> Types.release -> Types.rejection list   (* [] = passes *)
  val partition : Config.hard_rules -> Types.release list
                  -> Types.release list * Types.rejected_release list
end

(* lib/core/scoring.ml — Stage 3: deterministic scoring, pure *)
module Scoring : sig
  val score : Config.preferences -> Config.weights -> Types.media -> Types.release -> Types.scored_release
  val rank  : Config.preferences -> Config.weights -> Types.media -> Types.release list -> Types.scored_release list  (* best first *)
end

(* lib/core/prompt.ml — Stage 4 input, pure *)
module Prompt : sig
  val system_prompt : string
  (** Builds the JSON user message with keys exactly (in this order):
      media, hard_constraints, structured_preferences,
      natural_language_preferences, temporary_instruction, candidates.
      Candidates are sent with SHORT ids "r1".."rN" (never guids, magnet
      links, URLs or info hashes, which small models mangle); the returned
      association list maps short id -> real release id. *)
  val build_with_ids : config:Config.t -> instance:Config.instance option -> media:Types.media
              -> ?instruction:string -> Types.scored_release list -> string * (string * string) list
  val build : config:Config.t -> instance:Config.instance option -> media:Types.media
              -> ?instruction:string -> Types.scored_release list -> string
end

(* lib/core/llm_response.ml — Stage 4 validation, pure *)
module Llm_response : sig
  (** Validate {selected_id, confidence, reason, ranking[{id,score,reason}], influences?, conflicts?}.
      selected_id must resolve to a candidate (tolerant of case/quotes/"#3"/
      "candidate 3"/exact title via [aliases]); otherwise Error (=> fallback).
      Ranking entries with unknown ids are dropped, duplicates keep the first,
      scores/confidence are clamped — each repair is reported as a warning
      that the pipeline surfaces as "AI response note: ...". Never raises. *)
  val parse_with_warnings : candidate_ids:string list -> ?aliases:(string * string) list
                            -> Yojson.Safe.t -> (Types.llm_decision * string list, string) result
  val parse : candidate_ids:string list -> Yojson.Safe.t -> (Types.llm_decision, string) result
end

(* lib/core/explain.ml — explainability, pure *)
module Explain : sig
  (** Bullet list: which structured / NL preferences the pick matches,
      plus conflicts ("You said you prefer AV1, but AV1 is blocked by a hard codec rule"). *)
  val explain : config:Config.t -> instance:Config.instance option -> media:Types.media
                -> selected:Types.scored_release -> candidates:Types.scored_release list
                -> rejected:Types.rejected_release list -> llm:Types.llm_decision option
                -> string list * string list   (* explanation, conflicts *)
end

(* lib/core/pipeline.ml — orchestration; the only Lwt-aware core module *)
module Pipeline : sig
  type llm_fn = system:string -> user:string -> (Yojson.Safe.t, string) result Lwt.t
  val run :
    config:Config.t -> instance:Config.instance option -> media:Types.media
    -> releases:Types.release list -> ?instruction:string -> ?llm:llm_fn
    -> ?use_ai:bool (* override config.llm.llm_enabled for this request *)
    -> unit -> Types.selection_result Lwt.t
end

(* lib/core/rules_proposal.ml — "Convert to structured rules" (never auto-applied) *)
module Rules_proposal : sig
  val system_prompt : string
  val build_prompt : Config.t -> string -> string          (* NL text -> user message *)
  (** Parse {proposals:[{field, value, rationale}]} into a JSON patch for
      Config.preferences / Config.hard_rules plus a human summary. *)
  val parse : Yojson.Safe.t -> (Yojson.Safe.t * string list, string) result
end
```

### `Pickarr_server` (owner: server stream)

Routes (all JSON unless noted):

```
GET  /                                   UI (HTML)
GET  /health                             {"status":"ok"}
GET  /api/config                         redacted config
PUT  /api/config                         full/partial config update (Config.patch)
GET  /api/instances                      instances + connection status
POST /api/instances/:id/test             test connection
POST /api/llm/test                       test LLM
POST /api/select/radarr/movie/:id        select for default Radarr instance   body: {grab?, instruction?, use_ai?}
POST /api/select/sonarr/episode/:id      select for default Sonarr instance
POST /api/select/:instance_id/:media_id  select for a specific instance
POST /api/grab/:instance_id/:media_id    grab one named candidate {release_id}
POST /api/grab/:instance_id/season/:series_id/:season_number
                                         grab one named season pack {release_id}
GET  /api/history                        recent selection results
GET  /api/wanted/:instance_id            wanted (missing/cutoff) items
POST /api/rules/propose                  {text} -> proposed structured rules (not saved)
POST /api/rules/apply                    {patch} -> apply proposals after explicit approval
GET  /api/library/:instance_id/search    Search the library by title or id (cached listing)
GET  /api/library/:instance_id/series/:series_id           Picked series: seasons
GET  /api/library/:instance_id/series/:series_id/season/:n Episodes of one season
GET  /api/library/:instance_id/movie/:movie_id             Picked movie
POST /api/webhook/:instance_id           Sonarr/Radarr webhook receiver
POST /api/webhook/seerr                  Seerr/Overseerr/Jellyseerr webhook (MEDIA_APPROVED / MEDIA_AUTO_APPROVED)
GET  /api/seerr/status                   Seerr poller status and last pass
POST /api/seerr/test                     test the saved Seerr connection
GET  /api/seerr/requests                 requests (?filter=pending|processing|..., ?take=)
POST /api/seerr/requests/:id/approve     approve in Seerr, then fulfil
POST /api/seerr/requests/:id/decline     decline in Seerr
POST /api/seerr/requests/:id/fulfil      search and grab for that request now (background; no UI button)
POST /api/seerr/requests/:id/resolve     what the request maps to in Sonarr/Radarr (no search)
POST /api/seerr/requests/:id/select      run the pipeline for the request, answering like /api/select
                                         body: {grab?, instruction?, use_ai?, instance_id?, season_number?, approve?}
POST /api/seerr/run                      run a Seerr pass now
GET  /api/automatic/status               scheduler status
POST /api/automatic/run                  trigger a scheduler pass now
POST   /api/jobs                         queue a job {kind, params, source?} -> 202 {"job"}
GET    /api/jobs                         ?status=queued,running|active|finished&kind=&limit=100&include=result
GET    /api/jobs/:id                     one job incl. result
POST   /api/jobs/:id/cancel              cancel queued/running (409 when finished)
POST   /api/jobs/:id/retry               new job for a failed/cancelled one (409 otherwise)
DELETE /api/jobs?status=finished         clear finished jobs -> {"cleared":n}
GET    /api/events                       ?since_id=&limit=&type=<prefix>&level=&job_id=&q= -> {"events","last_id"}
```

Persistence: `DATA_DIR` (default `/data`, fallback `./data`) with
`config.json`, `history.jsonl`, `jobs.json` and `events.jsonl` (+
`events.1.jsonl`). Environment variables override the stored config on
startup (`Config.apply_env`).

### UI wording

The route names keep the word *select*, but the UI says what the buttons do,
because "preview"/"select" read as jargon:

| UI | What it calls |
|----|---------------|
| the **Search** tab and its **Search** button | `POST /api/select/...` with `grab:false` |
| **Grab** (searches and grabs in one press) | `POST /api/select/...` with `grab:true` |
| **Grab selected** on a result card, **Grab this** on a candidate row | `POST /api/grab/...` with that release id |
| **Approve** on a pending Seerr request | `POST /api/seerr/requests/:id/approve` |
| **Approve & grab** / **Approve & search** | `POST /api/seerr/requests/:id/select` with `approve:true` |

There is no *Fulfil now* button: it did what **Grab** does, so the UI offers
only Grab. `POST /api/seerr/requests/:id/fulfil` still exists for scripts.
A search result badge reads *not grabbed yet* until something is grabbed.

## Selection pipeline

1. **Retrieve** — `Client.search_releases` (GET /api/v3/release).
2. **Hard filter** — `Filter.partition` (deterministic; LLM can never override).
   Sonarr/Radarr rejections are recorded with stage `Arr_rejection`.
3. **Score** — `Scoring.rank` (pure, weights configurable).
4. **AI** — if enabled, `Prompt.build` -> `Llm.Client.chat_json` ->
   `Llm_response.parse`. Any failure => deterministic fallback
   (`By_deterministic_fallback reason`).
5. **Grab** — `Client.grab` (POST /api/v3/release) only when requested
   (`grab:true`) or in automatic mode with `auto_grab`.

Priority order (highest first):

1. Sonarr/Radarr hard rejection
2. Pickarr hard rules
3. explicit structured preferences
4. natural-language preferences
5. deterministic scoring
6. general default AI preferences

## Library browsing and links

`Client.library` lists a whole instance (`GET /api/v3/series` or
`GET /api/v3/movie`) and caches it per instance for 60 seconds, so the Search
page's one text box can match locally on title, sort title, alternate titles
or any id. `lib/server/library.ml` holds that matching (pure, capped at 25
results) and the link shapes, verified against the upstream front ends:

```text
Sonarr  {instance url}/series/{titleSlug}   frontend/src/App/AppRoutes.tsx
Radarr  {instance url}/movie/{titleSlug}    frontend/src/App/AppRoutes.tsx,
                                            Movie/MovieTitleLink.tsx
Seerr   {seerr url}/movie/{tmdbId}          server/lib/notifications/agents/discord.ts
Seerr   {seerr url}/tv/{tmdbId}             (same: `${url}/${mediaType}/${tmdbId}`)
```

Radarr addresses a movie by `titleSlug`, not by TMDB id: `MovieDetailsPage`
looks the movie up by slug and shows "Movie cannot be found" for anything
else. `Library.decorate` adds a `links` object to every media object in a
response with one traversal at the response boundary, which keeps
`Types.media` free of presentation concerns; history entries store the links
they were written with.

## Automatic mode

See `docs/API_RESEARCH.md` §6 for the verified options. Design: Pickarr
polls `wanted/missing` (and optionally `wanted/cutoff`) per instance on an
interval, skips items already in the queue or grabbed recently, runs the
pipeline and grabs when `auto_grab` is on. Sonarr/Radarr's own automatic
search/RSS must be disabled by the user (or via a Prowlarr sync profile) for
Pickarr to be the decision-maker; Pickarr never uses the
`EpisodeSearch`/`MoviesSearch` commands because those make Sonarr/Radarr grab
on their own. Webhooks (SeriesAdd/MovieAdded/EpisodeFileDelete/MovieFileDelete) trigger an
immediate pass for the affected item. A Seerr webhook resolves the approved
request by TMDB/TVDB id (retrying while Sonarr/Radarr are still adding it)
and selects the monitored, missing movie or season right away, through the
same `Fulfil` module the poller uses.

## Seerr request integration

`lib/arr/seerr.ml` is the typed client for Seerr's `/api/v1` (status,
requests, approve/decline, counts, movie/tv titles) and
`lib/server/seerr_sync.ml` the poller. A pass optionally approves the pending
requests, then for every approved-but-unavailable request picks the instances
(`movie` -> Radarr, `tv` -> Sonarr; 4K requests prefer instances named "4k"),
hands each one to `lib/server/fulfil.ml` with `seerr.grab` deciding whether
anything is grabbed. Requests are retried at most once every six hours. The
decision helpers (`choose_instances`, `skip_reason`, `plan`) are pure and
unit tested.

`lib/server/fulfil.ml` is the one place that turns a request into selections,
shared by the poller and the webhook path in `automatic.ml` (which is why it
must not depend on `Automatic`: `Automatic` depends on it):

* `resolve` maps a request onto one instance as a `target` —
  `Movies ids` (Radarr, by TMDB id, with Seerr's `externalServiceId` as a last
  resort), `Series {series_id; seasons}` (Sonarr, by TheTVDB id through
  `Client.series_id_by_tvdb_id`, keeping only the requested seasons that still
  miss episodes), `Episodes ids` (fallback when the series cannot be resolved),
  or `Nothing` — which is what makes the callers wait and retry while Seerr is
  still pushing to the *arr.
* `run` executes it: `Selection.run` per movie/episode, or
  `Selection.run_series` for a `Series` target, so a requested season is
  satisfied by one season pack under the usual `Config.seasons` policy.
* `seasons_to_compact` renders the per-season outcome (pack / episodes /
  skipped) that the Requests tab displays.

The Requests tab can also work a request by hand, the way the Search page
works a media id. `Seerr_sync.resolve_request` answers what the request maps
to on each instance without searching (movie id, or series id plus the
requested seasons with their missing/total counts), and
`Seerr_sync.select_for_request` runs the pipeline for it and answers with the
same payload the select routes return (`selection`, `series` or `selections`,
plus the request and the instance used). A pending request is refused unless
the body carries `approve: true`, in which case it is approved first and the
*arr is given up to ~90s to add the item. Only a grab records the cooldown
attempt, so searching never starves the poller. The pure parts
(`select_body_of_json`, `pending_decision`, `nothing_reason`) are unit
tested.

## Job queue and event log

Every action that talks to Sonarr/Radarr/Seerr runs as a **job** in one
server-side queue (`lib/server/jobs.ml`), and everything that happens is
recorded as a structured **event** (`lib/server/events.ml`). The UI lists
jobs live and shows the event log.

### Jobs

* A job kind is registered with `Jobs.register kind parse`, where `parse`
  synchronously validates the params (no I/O) and returns a `prepared`
  record: label, instance id, optional dedupe key and the `run` function.
  The real kinds (`search`, `grab_best`, `grab_release`, `seerr_select`,
  `seerr_fulfil`, `automatic_pass`, `seerr_pass`, `seerr_webhook`) live in
  `lib/server/job_kinds.ml` and are registered by `Job_kinds.register_all ()`
  **before** `Jobs.start`, because queued jobs restored after a restart are
  re-prepared through their kind.
* `Jobs.enqueue state ~source kind params` validates and queues; while a
  queued or running job has the same dedupe key, that job is returned
  instead of a duplicate.
* Scheduling is FIFO by id, read live from `config.queue`: at most
  `workers` (1..8, default 2) jobs run at once, at most `per_instance`
  (1..4, default 1) of them against one instance id. A job held back by its
  instance limit does not hold back later jobs for other instances. A
  dispatcher loop wakes on a condition (enqueue / finish / cancel) and once a
  second, so a config change applies without a restart.
* A running job gets a `ctx`: `progress` (also a `job.progress` event, at
  most one per second), `set_label`, and `event` (an `Events.emit` tagged
  with the job and instance id).
* Outcomes: `Ok result` → succeeded; `Error msg` or an exception → failed;
  `Jobs.cancel` on a running job cancels its promise *and* marks it
  cancelled at once, so a runner that ignores cancellation never leaves a
  job stuck "running". `Jobs.wait` resolves every waiter when the job
  finishes. Retry creates a new job (`attempt + 1`, `retry_of`).
* Errors and HTTP statuses: a runner (or a kind's parser) that stands for an
  HTTP status prefixes its message, `"[502] Radarr: …"`
  (`lib/server/status_error.ml`). When a job fails the queue splits the
  prefix off: the job JSON carries `error` (plain message, also in the
  `job.failed` event) and `error_status` (`502`, or `null`). The endpoints
  that wait for a job answer with `error_status` (`Responses.job_error_status`),
  `POST /api/jobs` and retry answer a parser's prefixed error with its
  status (404 unknown instance, else 400 / 409). Clients never see the
  prefix; the UI also strips it defensively.
* `DATA_DIR/jobs.json` is a debounced snapshot (≤ 1 write/s, temp file +
  rename). Results are kept for the newest 50 finished jobs only. On start,
  running jobs become failed ("interrupted by restart", `job.interrupted`),
  queued jobs are queued again, ids continue. Finished jobs beyond
  `keep_finished` (50..5000, default 500) are dropped oldest first.
* `QUEUE_WORKERS` / `QUEUE_PER_INSTANCE` override the stored limits.
* With `PICKARR_TEST_JOBS=1` a hidden `test_sleep` kind exists for
  `test/smoke/queue_core_e2e.sh`.

### Events

* `Events.emit ?level ?job_id ?instance_id ?media ?data type message` never
  raises or blocks. Events get monotonic ids that continue across restarts,
  are kept in memory (last 5000) and appended to `DATA_DIR/events.jsonl` by
  a single background writer (no interleaved lines), rotated to
  `events.1.jsonl` at 10 MB.
* `Events.init ~data_dir` runs first in `Server.main`; anything emitted
  before it is renumbered and written afterwards.
* `Log_buffer` mirrors every warning/error line as `log.warn` / `log.error`
  (Events itself never depends on Log_buffer).
* Types are dotted: `job.*`, `search.*`, `grab.*`, `seerr.*`,
  `automatic.*`, `webhook.received`, `config.updated`, `auth.*`,
  `instance.tested`, `llm.tested`, `log.*`.
* `GET /api/events?since_id=N` is the polling form: events with id > N,
  ascending; without `since_id` the most recent `limit` events.
