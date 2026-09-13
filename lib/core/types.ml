(* Shared domain types for Selectarr.

   This module is the contract between the Sonarr/Radarr clients, the
   selection pipeline, the LLM client and the HTTP server.  Keep it free of
   I/O: only plain data and pure helpers live here. *)

(** Which *arr application a request concerns. *)
type app = Sonarr | Radarr

let app_to_string = function Sonarr -> "sonarr" | Radarr -> "radarr"

let app_of_string = function
  | "sonarr" -> Some Sonarr
  | "radarr" -> Some Radarr
  | _ -> None

(** Download protocol as reported by Sonarr/Radarr. *)
type protocol = Torrent | Usenet | Unknown_protocol

let protocol_to_string = function
  | Torrent -> "torrent"
  | Usenet -> "usenet"
  | Unknown_protocol -> "unknown"

let protocol_of_string s =
  match String.lowercase_ascii s with
  | "torrent" -> Torrent
  | "usenet" -> Usenet
  | _ -> Unknown_protocol

(** A single named custom format attached to a release by Sonarr/Radarr. *)
type custom_format = { cf_id : int; cf_name : string }

(** Internal, app-agnostic representation of a candidate release.

    Fields that Sonarr/Radarr provide directly are copied verbatim.  Fields
    such as [codec], [audio], [hdr] and [dolby_vision] are NOT provided by the
    *arr APIs and are parsed from the release title by
    [Selectarr_core.Title_parser]. *)
type release = {
  id : string;
      (** Stable identifier used in API responses and LLM prompts.  It is the
          release [guid] when present, otherwise a hash of the title. *)
  guid : string option;
  indexer_id : int option;
  indexer : string option;
  title : string;
  size_bytes : int64;
  seeders : int option;
  leechers : int option;
  protocol : protocol;
  age_hours : float option;
  publish_date : string option;
  (* Quality model from Sonarr/Radarr *)
  quality : string option;  (** e.g. "WEBDL-1080p", "Bluray-2160p" *)
  quality_source : string option;
      (** Sonarr/Radarr QualitySource enum: unknown, television,
          televisionRaw, web, webRip, dvd, bluray, blurayRaw *)
  resolution : int option;  (** 480, 720, 1080, 2160 ... *)
  quality_modifier : string option;
      (** none, regional, screener, rawhd, brdisk, remux *)
  quality_weight : int option;
  is_repack : bool;
  is_proper : bool;
  (* Parsed / derived *)
  source : string option;
      (** Normalised source label: "WEB-DL", "WEBRip", "Bluray", "Remux",
          "HDTV", "DVD", ... *)
  codec : string option;  (** Normalised: "x264", "x265", "AV1", "VC-1", ... *)
  audio : string option;  (** Normalised: "Atmos", "TrueHD", "DTS-HD", "DDP", "AAC", ... *)
  hdr : string list;  (** e.g. ["HDR10"; "HDR10+"; "HLG"] *)
  dolby_vision : bool;
  dv_profile : string option;  (** "P5", "P7", "P8" when detectable *)
  release_group : string option;
  languages : string list;
  (* Custom formats *)
  custom_formats : custom_format list;
  custom_format_score : int option;
  (* Sonarr/Radarr's own opinion *)
  arr_approved : bool;
  arr_rejected : bool;
  arr_temporarily_rejected : bool;
  arr_rejection_reasons : string list;
  download_allowed : bool;
  (* Sonarr specifics *)
  full_season : bool;
  season_number : int option;
  mapped_episode_ids : int list;
  (* Raw JSON as returned by Sonarr/Radarr, retained for debugging and for
     passing back on grab if ever needed. *)
  raw : Yojson.Safe.t;
}

(** Metadata about the media item being evaluated.  Passed to the LLM so it
    can apply context-specific natural-language preferences ("for anime",
    "for 4K", "for older movies", ...). *)
type media = {
  app : app;
  media_id : int;  (** episodeId (Sonarr) or movieId (Radarr) *)
  title : string;  (** Series title or movie title *)
  year : int option;
  media_kind : string;
      (** "movie" | "episode" | "season".  For Sonarr series types see
          [series_type]. *)
  series_type : string option;  (** Sonarr: "standard" | "daily" | "anime" *)
  season_number : int option;
  episode_number : int option;
  episode_title : string option;
  genres : string list;
  runtime_minutes : int option;
  quality_profile_id : int option;
  quality_profile_name : string option;
  tags : string list;
  overview : string option;
  original_language : string option;
  has_file : bool;
  existing_quality : string option;
      (** Quality of the file currently on disk if any (upgrade context). *)
  monitored : bool;
  path : string option;
  extra : (string * Yojson.Safe.t) list;
      (** Any further useful key/values (imdbId, tmdbId, tvdbId, network,
          studio, certification ...) *)
}

(** A structured reason for a hard rejection. *)
type rejection = {
  rule : string;  (** Machine-readable rule id, e.g. "max_size", "blocked_group" *)
  message : string;  (** Human-readable explanation *)
  stage : rejection_stage;
}

and rejection_stage =
  | Arr_rejection  (** Sonarr/Radarr itself rejected the release *)
  | Hard_rule  (** A Selectarr hard rule rejected the release *)

type rejected_release = { release : release; reasons : rejection list }

(** One component of the deterministic score, for explainability. *)
type score_component = { component : string; points : float; detail : string }

type scored_release = {
  scored : release;
  score : float;
  components : score_component list;
}

(** Result of asking the LLM to rank candidates. *)
type llm_ranking_entry = {
  rank_id : string;
  rank_score : int;  (** 0-100 *)
  rank_reason : string;
}

type llm_decision = {
  selected_id : string;
  confidence : float;  (** 0.0-1.0 *)
  llm_reason : string;
  ranking : llm_ranking_entry list;
  influences : string list;
      (** Which user preferences influenced the choice, in plain English. *)
  conflicts : string list;
      (** Natural-language preferences that could not be followed because a
          hard rule prevented it. *)
}

(** How the final pick was made. *)
type decision_method =
  | By_llm
  | By_deterministic
  | By_deterministic_fallback of string
      (** LLM was enabled but failed; carries the failure reason. *)

type selection_result = {
  media : media;
  selected : scored_release option;
  candidates : scored_release list;  (** Sorted best-first by final rank *)
  rejected : rejected_release list;
  reason : string;
  explanation : string list;  (** Bullet points shown to the user *)
  conflicts : string list;
  method_ : decision_method;
  llm : llm_decision option;
  grabbed : bool;
  grab_error : string option;
  duration_ms : int;
}

(* ------------------------------------------------------------------------ *)
(* Small pure helpers                                                        *)
(* ------------------------------------------------------------------------ *)

let gib_of_bytes (b : int64) : float =
  Int64.to_float b /. (1024. *. 1024. *. 1024.)

let bytes_of_gib (g : float) : int64 =
  Int64.of_float (g *. 1024. *. 1024. *. 1024.)

let opt_str = function None -> `Null | Some s -> `String s
let opt_int = function None -> `Null | Some i -> `Int i
let opt_float = function None -> `Null | Some f -> `Float f
let str_list l = `List (List.map (fun s -> `String s) l)

let custom_format_to_yojson (c : custom_format) : Yojson.Safe.t =
  `Assoc [ ("id", `Int c.cf_id); ("name", `String c.cf_name) ]

(** JSON encoding used by the HTTP API and in LLM prompts.  [include_raw]
    controls whether the raw *arr payload is embedded. *)
let release_to_yojson ?(include_raw = false) (r : release) : Yojson.Safe.t =
  let base =
    [
      ("id", `String r.id);
      ("guid", opt_str r.guid);
      ("indexer_id", opt_int r.indexer_id);
      ("indexer", opt_str r.indexer);
      ("title", `String r.title);
      ("size_bytes", `Intlit (Int64.to_string r.size_bytes));
      ("size_gib", `Float (Float.round (gib_of_bytes r.size_bytes *. 100.) /. 100.));
      ("seeders", opt_int r.seeders);
      ("leechers", opt_int r.leechers);
      ("protocol", `String (protocol_to_string r.protocol));
      ("age_hours", opt_float r.age_hours);
      ("publish_date", opt_str r.publish_date);
      ("quality", opt_str r.quality);
      ("quality_source", opt_str r.quality_source);
      ("resolution", opt_int r.resolution);
      ("quality_modifier", opt_str r.quality_modifier);
      ("quality_weight", opt_int r.quality_weight);
      ("is_repack", `Bool r.is_repack);
      ("is_proper", `Bool r.is_proper);
      ("source", opt_str r.source);
      ("codec", opt_str r.codec);
      ("audio", opt_str r.audio);
      ("hdr", str_list r.hdr);
      ("dolby_vision", `Bool r.dolby_vision);
      ("dv_profile", opt_str r.dv_profile);
      ("release_group", opt_str r.release_group);
      ("languages", str_list r.languages);
      ("custom_formats", `List (List.map custom_format_to_yojson r.custom_formats));
      ("custom_format_score", opt_int r.custom_format_score);
      ("arr_approved", `Bool r.arr_approved);
      ("arr_rejected", `Bool r.arr_rejected);
      ("arr_temporarily_rejected", `Bool r.arr_temporarily_rejected);
      ("arr_rejection_reasons", str_list r.arr_rejection_reasons);
      ("download_allowed", `Bool r.download_allowed);
      ("full_season", `Bool r.full_season);
      ("season_number", opt_int r.season_number);
      ("mapped_episode_ids", `List (List.map (fun i -> `Int i) r.mapped_episode_ids));
    ]
  in
  `Assoc (if include_raw then base @ [ ("raw", r.raw) ] else base)

let media_to_yojson (m : media) : Yojson.Safe.t =
  `Assoc
    ([
       ("app", `String (app_to_string m.app));
       ("media_id", `Int m.media_id);
       ("title", `String m.title);
       ("year", opt_int m.year);
       ("media_kind", `String m.media_kind);
       ("series_type", opt_str m.series_type);
       ("season_number", opt_int m.season_number);
       ("episode_number", opt_int m.episode_number);
       ("episode_title", opt_str m.episode_title);
       ("genres", str_list m.genres);
       ("runtime_minutes", opt_int m.runtime_minutes);
       ("quality_profile_id", opt_int m.quality_profile_id);
       ("quality_profile_name", opt_str m.quality_profile_name);
       ("tags", str_list m.tags);
       ("overview", opt_str m.overview);
       ("original_language", opt_str m.original_language);
       ("has_file", `Bool m.has_file);
       ("existing_quality", opt_str m.existing_quality);
       ("monitored", `Bool m.monitored);
       ("path", opt_str m.path);
     ]
    @ m.extra)

let rejection_stage_to_string = function
  | Arr_rejection -> "arr"
  | Hard_rule -> "hard_rule"

let rejection_to_yojson (r : rejection) : Yojson.Safe.t =
  `Assoc
    [
      ("rule", `String r.rule);
      ("message", `String r.message);
      ("stage", `String (rejection_stage_to_string r.stage));
    ]

let rejected_release_to_yojson (r : rejected_release) : Yojson.Safe.t =
  `Assoc
    [
      ("release", release_to_yojson r.release);
      ("reasons", `List (List.map rejection_to_yojson r.reasons));
    ]

let score_component_to_yojson (c : score_component) : Yojson.Safe.t =
  `Assoc
    [
      ("component", `String c.component);
      ("points", `Float c.points);
      ("detail", `String c.detail);
    ]

let scored_release_to_yojson (s : scored_release) : Yojson.Safe.t =
  `Assoc
    [
      ("release", release_to_yojson s.scored);
      ("score", `Float s.score);
      ("components", `List (List.map score_component_to_yojson s.components));
    ]

let llm_ranking_entry_to_yojson (e : llm_ranking_entry) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String e.rank_id);
      ("score", `Int e.rank_score);
      ("reason", `String e.rank_reason);
    ]

let llm_decision_to_yojson (d : llm_decision) : Yojson.Safe.t =
  `Assoc
    [
      ("selected_id", `String d.selected_id);
      ("confidence", `Float d.confidence);
      ("reason", `String d.llm_reason);
      ("ranking", `List (List.map llm_ranking_entry_to_yojson d.ranking));
      ("influences", str_list d.influences);
      ("conflicts", str_list d.conflicts);
    ]

let decision_method_to_yojson = function
  | By_llm -> `Assoc [ ("kind", `String "llm") ]
  | By_deterministic -> `Assoc [ ("kind", `String "deterministic") ]
  | By_deterministic_fallback why ->
      `Assoc [ ("kind", `String "deterministic_fallback"); ("llm_error", `String why) ]

let selection_result_to_yojson (r : selection_result) : Yojson.Safe.t =
  `Assoc
    [
      ("media", media_to_yojson r.media);
      ( "selected",
        match r.selected with
        | None -> `Null
        | Some s -> scored_release_to_yojson s );
      ("candidates", `List (List.map scored_release_to_yojson r.candidates));
      ("rejected", `List (List.map rejected_release_to_yojson r.rejected));
      ("reason", `String r.reason);
      ("explanation", str_list r.explanation);
      ("conflicts", str_list r.conflicts);
      ("method", decision_method_to_yojson r.method_);
      ("llm", match r.llm with None -> `Null | Some d -> llm_decision_to_yojson d);
      ("grabbed", `Bool r.grabbed);
      ("grab_error", opt_str r.grab_error);
      ("duration_ms", `Int r.duration_ms);
    ]
