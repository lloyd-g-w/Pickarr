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
lib/server/ pickarr_server Dream routes, JSON config store, UI, automatic mode, webhooks
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
  val get  : base_url:string -> api_key:string -> ?query:(string * string) list -> string -> (Yojson.Safe.t, error) result Lwt.t
  val post : base_url:string -> api_key:string -> string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result Lwt.t
  val put  : base_url:string -> api_key:string -> string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result Lwt.t
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
  val create : Pickarr_core.Config.instance -> t
  val instance : t -> Pickarr_core.Config.instance
  val app : t -> Pickarr_core.Types.app

  (** GET /api/v3/system/status -> (appName, version, instanceName) *)
  val test_connection : t -> (string * string * string, error) result Lwt.t

  (** Sonarr: episodeId (fetches episode + series). Radarr: movieId. *)
  val fetch_media : t -> int -> (Pickarr_core.Types.media, error) result Lwt.t

  (** GET /api/v3/release?episodeId= | ?movieId= mapped to core releases.
      Never filters anything out; rejected releases are returned with
      arr_rejected=true and arr_rejection_reasons populated. *)
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
  (** Builds the JSON user message with keys exactly:
      hard_constraints, structured_preferences, natural_language_preferences,
      temporary_instruction, media, candidates (top-N scored, never rejected). *)
  val build : config:Config.t -> instance:Config.instance option -> media:Types.media
              -> ?instruction:string -> Types.scored_release list -> string
end

(* lib/core/llm_response.ml — Stage 4 validation, pure *)
module Llm_response : sig
  (** Validate {selected_id, confidence, reason, ranking[{id,score,reason}], influences?, conflicts?}.
      Errors: unknown selected_id, unknown ranking id, duplicate ids, score
      outside 0..100, confidence outside 0..1, missing fields. Never raises. *)
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
GET  /api/history                        recent selection results
GET  /api/wanted/:instance_id            wanted (missing/cutoff) items
POST /api/rules/propose                  {text} -> proposed structured rules (not saved)
POST /api/rules/apply                    {patch} -> apply proposals after explicit approval
POST /api/webhook/:instance_id           Sonarr/Radarr webhook receiver
POST /api/webhook/seerr                  Seerr/Overseerr/Jellyseerr webhook (MEDIA_APPROVED / MEDIA_AUTO_APPROVED)
GET  /api/seerr/status                   Seerr poller status and last pass
POST /api/seerr/test                     test the saved Seerr connection
GET  /api/seerr/requests                 requests (?filter=pending|processing|..., ?take=)
POST /api/seerr/requests/:id/approve     approve in Seerr, then fulfil
POST /api/seerr/requests/:id/decline     decline in Seerr
POST /api/seerr/requests/:id/fulfil      run a selection for that request now
POST /api/seerr/run                      run a Seerr pass now
GET  /api/automatic/status               scheduler status
POST /api/automatic/run                  trigger a scheduler pass now
```

Persistence: `DATA_DIR` (default `/data`, fallback `./data`) with
`config.json` and `history.jsonl`. Environment variables override the stored
config on startup (`Config.apply_env`).

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
and selects the monitored, missing movie/episodes right away.

## Seerr request integration

`lib/arr/seerr.ml` is the typed client for Seerr's `/api/v1` (status,
requests, approve/decline, counts, movie/tv titles) and
`lib/server/seerr_sync.ml` the poller. A pass optionally approves the pending
requests, then for every approved-but-unavailable request picks the instances
(`movie` -> Radarr, `tv` -> Sonarr; 4K requests prefer instances named "4k"),
resolves the media through `Client.resolve_external`, and runs
`Selection.run` per media id with `seerr.grab` deciding whether anything is
grabbed. Requests are retried at most once every six hours. The decision
helpers (`choose_instances`, `skip_reason`, `plan`) are pure and unit
tested.
