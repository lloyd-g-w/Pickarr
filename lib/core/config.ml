(* Pickarr configuration.

   The configuration is persisted as JSON (see [to_yojson] / [of_yojson]) and
   may be seeded/overridden from environment variables (see
   [apply_env]).  Pure module: no I/O. *)

module J = Yojson.Safe
module U = Yojson.Safe.Util

(* ------------------------------------------------------------------------ *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------ *)

(** A connection to one Sonarr or Radarr instance.  Multiple instances of
    each app are supported (e.g. "4K Radarr", "Anime Sonarr"). *)
type instance = {
  inst_id : string;  (** Slug, unique across all instances, e.g. "radarr-4k" *)
  inst_name : string;  (** Display name *)
  inst_app : Types.app;
  inst_url : string;  (** e.g. http://radarr:7878 (no trailing slash) *)
  inst_api_key : string;
  inst_enabled : bool;
  inst_nl_preferences : string;
      (** Optional per-instance natural-language preferences.  Combined
          with the global preferences at prompt time. *)
  inst_automatic : bool;
      (** Whether automatic (polling) mode is active for this instance. *)
}

type llm = {
  llm_enabled : bool;  (** Whether AI selection is enabled at all. *)
  llm_provider : string;  (** "openai" | "openai-compatible" | "ollama" ... *)
  llm_base_url : string;  (** e.g. https://api.openai.com/v1 *)
  llm_api_key : string;
  llm_model : string;
  llm_temperature : float;
  llm_max_tokens : int;
  llm_timeout_seconds : int;
  llm_json_mode : bool;
      (** Send response_format={type:"json_object"}; disable for servers
          that do not support it. *)
  llm_max_candidates : int;
      (** Only the top-N deterministically scored candidates are sent to
          the LLM to keep prompts bounded. *)
}

(** Hard rules: deterministic, never overridable by the LLM or by
    natural-language preferences. *)
type hard_rules = {
  max_size_gib : float option;  (** Reject releases larger than this. *)
  min_size_gib : float option;
  min_seeders : int option;  (** Applies to torrents only. *)
  blocked_groups : string list;  (** Case-insensitive. *)
  blocked_codecs : string list;  (** e.g. ["AV1"; "XviD"] *)
  allowed_codecs : string list;
      (** If non-empty, only these codecs are allowed (unknown codec passes
          unless [reject_unknown_codec]). *)
  reject_unknown_codec : bool;
  blocked_languages : string list;
  required_languages : string list;
      (** If non-empty, release must contain at least one of these. *)
  allow_remux : bool;
  allow_dolby_vision : bool;
  require_hdr10_fallback_for_dv : bool;
      (** Reject DV releases that have no HDR10 fallback (DV profile 5 /
          DV-only).  Only enforceable when the profile is detectable. *)
  allow_hdr : bool;
  blocked_hdr_formats : string list;  (** e.g. ["HDR10+"] *)
  allowed_resolutions : int list;  (** If non-empty, only these resolutions. *)
  allowed_protocols : Types.protocol list;  (** If empty, all protocols. *)
  respect_arr_rejections : bool;
      (** [true] (default): releases rejected by Sonarr/Radarr are hard
          rejected.  [false]: their rejections become soft — the release is
          scored with the [w_arr_rejected] penalty, the reasons are shown to
          the user and the LLM, and it may be grabbed (POST /api/v3/release
          does not check them).  Rejections that would make the grab fail
          anyway (unknown series/movie, unparseable release, blocklisted)
          stay hard regardless. *)
  blocked_title_patterns : string list;
      (** Case-insensitive substrings / regexes that reject a release. *)
}

(** Structured (soft) preferences that influence deterministic scoring. *)
type preferences = {
  preferred_codecs : string list;  (** Ordered, first is best. *)
  disliked_codecs : string list;
  preferred_sources : string list;  (** e.g. ["WEB-DL"; "Bluray"; "Remux"] *)
  preferred_groups : string list;
  disliked_groups : string list;
  preferred_languages : string list;
  preferred_resolutions : int list;  (** e.g. [1080; 2160] *)
  preferred_audio : string list;  (** e.g. ["Atmos"; "TrueHD"] *)
  hdr_preference : string;  (** "prefer" | "neutral" | "avoid" *)
  dolby_vision_preference : string;  (** "prefer" | "neutral" | "avoid" *)
  prefer_remux : bool;
  prefer_repacks : bool;
  ideal_size_gib : float option;
      (** Sweet spot; sizes further away lose points. *)
  size_tolerance_gib : float;
      (** How far from ideal before penalties kick in. *)
}

(** Weights used by [Scoring].  All configurable. *)
type weights = {
  w_custom_format : float;  (** Multiplier applied to *arr custom format score *)
  w_quality_weight : float;  (** Multiplier applied to *arr qualityWeight *)
  w_web_dl_over_webrip : float;
  w_bluray_over_web : float;
  w_remux : float;
  w_preferred_codec : float;
  w_disliked_codec : float;
  w_preferred_source : float;
  w_preferred_group : float;
  w_disliked_group : float;
  w_preferred_language : float;
  w_preferred_resolution : float;
  w_preferred_audio : float;
  w_hdr : float;
  w_dolby_vision : float;
  w_repack : float;
  w_seeders : float;  (** Points per log2(seeders+1) *)
  w_seeders_cap : float;  (** Maximum points from seeders *)
  w_size_penalty_per_gib : float;
      (** Points lost per GiB outside the size tolerance window. *)
  w_arr_approved : float;
  w_arr_rejected : float;
      (** Penalty (negative) applied when Sonarr/Radarr rejected the release
          but [respect_arr_rejections] is off. *)
  w_age_penalty_per_day : float;
  w_age_penalty_cap : float;
}

type automatic = {
  auto_enabled : bool;
  auto_interval_seconds : int;
  auto_grab : bool;
      (** If false, automatic mode only logs what it would grab (dry-run). *)
  auto_search_missing : bool;
  auto_search_cutoff_unmet : bool;
  auto_max_items_per_run : int;
  auto_min_confidence : float;
      (** Skip grabbing when the LLM confidence is below this (deterministic
          fallback is still used if the LLM fails). *)
  auto_webhook_trigger : bool;
      (** Run selection immediately when a webhook event arrives. *)
}

type t = {
  instances : instance list;
  llm : llm;
  hard_rules : hard_rules;
  preferences : preferences;
  weights : weights;
  nl_preferences : string;  (** Global natural-language preferences *)
  automatic : automatic;
  log_level : string;
}

(* ------------------------------------------------------------------------ *)
(* Defaults                                                                  *)
(* ------------------------------------------------------------------------ *)

let default_llm =
  {
    llm_enabled = false;
    llm_provider = "openai-compatible";
    llm_base_url = "https://api.openai.com/v1";
    llm_api_key = "";
    llm_model = "gpt-4o-mini";
    llm_temperature = 0.2;
    llm_max_tokens = 2048;
    llm_timeout_seconds = 60;
    llm_json_mode = true;
    llm_max_candidates = 25;
  }

let default_hard_rules =
  {
    max_size_gib = None;
    min_size_gib = None;
    min_seeders = Some 1;
    blocked_groups = [];
    blocked_codecs = [];
    allowed_codecs = [];
    reject_unknown_codec = false;
    blocked_languages = [];
    required_languages = [];
    allow_remux = true;
    allow_dolby_vision = true;
    require_hdr10_fallback_for_dv = false;
    allow_hdr = true;
    blocked_hdr_formats = [];
    allowed_resolutions = [];
    allowed_protocols = [];
    respect_arr_rejections = true;
    blocked_title_patterns = [];
  }

let default_preferences =
  {
    preferred_codecs = [];
    disliked_codecs = [];
    preferred_sources = [];
    preferred_groups = [];
    disliked_groups = [];
    preferred_languages = [];
    preferred_resolutions = [];
    preferred_audio = [];
    hdr_preference = "neutral";
    dolby_vision_preference = "neutral";
    prefer_remux = false;
    prefer_repacks = true;
    ideal_size_gib = None;
    size_tolerance_gib = 2.0;
  }

let default_weights =
  {
    w_custom_format = 1.0;
    w_quality_weight = 0.0;
    w_web_dl_over_webrip = 15.0;
    w_bluray_over_web = 10.0;
    w_remux = 20.0;
    w_preferred_codec = 15.0;
    w_disliked_codec = -15.0;
    w_preferred_source = 10.0;
    w_preferred_group = 20.0;
    w_disliked_group = -20.0;
    w_preferred_language = 10.0;
    w_preferred_resolution = 15.0;
    w_preferred_audio = 5.0;
    w_hdr = 10.0;
    w_dolby_vision = 10.0;
    w_repack = 5.0;
    w_seeders = 3.0;
    w_seeders_cap = 20.0;
    w_size_penalty_per_gib = 2.0;
    w_arr_approved = 10.0;
    w_arr_rejected = -25.0;
    w_age_penalty_per_day = 0.0;
    w_age_penalty_cap = 0.0;
  }

let default_automatic =
  {
    auto_enabled = false;
    auto_interval_seconds = 900;
    auto_grab = false;
    auto_search_missing = true;
    auto_search_cutoff_unmet = false;
    auto_max_items_per_run = 5;
    auto_min_confidence = 0.5;
    auto_webhook_trigger = true;
  }

let default =
  {
    instances = [];
    llm = default_llm;
    hard_rules = default_hard_rules;
    preferences = default_preferences;
    weights = default_weights;
    nl_preferences = "";
    automatic = default_automatic;
    log_level = "info";
  }

(* ------------------------------------------------------------------------ *)
(* JSON helpers (lenient: missing keys fall back to defaults)                *)
(* ------------------------------------------------------------------------ *)

let member_opt k j =
  match j with
  | `Assoc l -> ( match List.assoc_opt k l with Some `Null -> None | v -> v)
  | _ -> None

let get_str k d j = match member_opt k j with Some (`String s) -> s | _ -> d
let get_bool k d j = match member_opt k j with Some (`Bool b) -> b | _ -> d

let get_int k d j =
  match member_opt k j with
  | Some (`Int i) -> i
  | Some (`Float f) -> int_of_float f
  | Some (`Intlit s) -> ( try int_of_string s with _ -> d)
  | _ -> d

let get_float k d j =
  match member_opt k j with
  | Some (`Float f) -> f
  | Some (`Int i) -> float_of_int i
  | Some (`Intlit s) -> ( try float_of_string s with _ -> d)
  | _ -> d

let get_float_opt k d j =
  match member_opt k j with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some `Null | None -> d
  | _ -> d

let get_int_opt k d j =
  match member_opt k j with
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (int_of_float f)
  | Some `Null | None -> d
  | _ -> d

let get_str_list k d j =
  match member_opt k j with
  | Some (`List l) ->
      List.filter_map (function `String s -> Some s | _ -> None) l
  | Some (`String s) ->
      (* Accept a comma-separated string too, handy for env vars. *)
      String.split_on_char ',' s |> List.map String.trim
      |> List.filter (fun s -> s <> "")
  | _ -> d

let get_int_list k d j =
  match member_opt k j with
  | Some (`List l) ->
      List.filter_map
        (function
          | `Int i -> Some i
          | `Float f -> Some (int_of_float f)
          | `String s -> int_of_string_opt s
          | _ -> None)
        l
  | Some (`String s) ->
      String.split_on_char ',' s
      |> List.filter_map (fun s -> int_of_string_opt (String.trim s))
  | _ -> d

let opt_float_json = function None -> `Null | Some f -> `Float f
let opt_int_json = function None -> `Null | Some i -> `Int i
let str_list_json l = `List (List.map (fun s -> `String s) l)
let int_list_json l = `List (List.map (fun i -> `Int i) l)

(* ------------------------------------------------------------------------ *)
(* Codecs                                                                    *)
(* ------------------------------------------------------------------------ *)

let instance_to_yojson (i : instance) : J.t =
  `Assoc
    [
      ("id", `String i.inst_id);
      ("name", `String i.inst_name);
      ("app", `String (Types.app_to_string i.inst_app));
      ("url", `String i.inst_url);
      ("api_key", `String i.inst_api_key);
      ("enabled", `Bool i.inst_enabled);
      ("nl_preferences", `String i.inst_nl_preferences);
      ("automatic", `Bool i.inst_automatic);
    ]

let instance_of_yojson (j : J.t) : (instance, string) result =
  match Types.app_of_string (get_str "app" "" j) with
  | None -> Error "instance.app must be \"sonarr\" or \"radarr\""
  | Some app ->
      let url = get_str "url" "" j in
      let url =
        if String.length url > 0 && url.[String.length url - 1] = '/' then
          String.sub url 0 (String.length url - 1)
        else url
      in
      let name = get_str "name" (Types.app_to_string app) j in
      let id =
        get_str "id"
          (String.map
             (fun c ->
               match c with
               | 'a' .. 'z' | '0' .. '9' -> c
               | 'A' .. 'Z' -> Char.lowercase_ascii c
               | _ -> '-')
             name)
          j
      in
      Ok
        {
          inst_id = id;
          inst_name = name;
          inst_app = app;
          inst_url = url;
          inst_api_key = get_str "api_key" "" j;
          inst_enabled = get_bool "enabled" true j;
          inst_nl_preferences = get_str "nl_preferences" "" j;
          inst_automatic = get_bool "automatic" false j;
        }

let llm_to_yojson (l : llm) : J.t =
  `Assoc
    [
      ("enabled", `Bool l.llm_enabled);
      ("provider", `String l.llm_provider);
      ("base_url", `String l.llm_base_url);
      ("api_key", `String l.llm_api_key);
      ("model", `String l.llm_model);
      ("temperature", `Float l.llm_temperature);
      ("max_tokens", `Int l.llm_max_tokens);
      ("timeout_seconds", `Int l.llm_timeout_seconds);
      ("json_mode", `Bool l.llm_json_mode);
      ("max_candidates", `Int l.llm_max_candidates);
    ]

let llm_of_yojson ?(d = default_llm) (j : J.t) : llm =
  {
    llm_enabled = get_bool "enabled" d.llm_enabled j;
    llm_provider = get_str "provider" d.llm_provider j;
    llm_base_url = get_str "base_url" d.llm_base_url j;
    llm_api_key = get_str "api_key" d.llm_api_key j;
    llm_model = get_str "model" d.llm_model j;
    llm_temperature = get_float "temperature" d.llm_temperature j;
    llm_max_tokens = get_int "max_tokens" d.llm_max_tokens j;
    llm_timeout_seconds = get_int "timeout_seconds" d.llm_timeout_seconds j;
    llm_json_mode = get_bool "json_mode" d.llm_json_mode j;
    llm_max_candidates = get_int "max_candidates" d.llm_max_candidates j;
  }

let hard_rules_to_yojson (h : hard_rules) : J.t =
  `Assoc
    [
      ("max_size_gib", opt_float_json h.max_size_gib);
      ("min_size_gib", opt_float_json h.min_size_gib);
      ("min_seeders", opt_int_json h.min_seeders);
      ("blocked_groups", str_list_json h.blocked_groups);
      ("blocked_codecs", str_list_json h.blocked_codecs);
      ("allowed_codecs", str_list_json h.allowed_codecs);
      ("reject_unknown_codec", `Bool h.reject_unknown_codec);
      ("blocked_languages", str_list_json h.blocked_languages);
      ("required_languages", str_list_json h.required_languages);
      ("allow_remux", `Bool h.allow_remux);
      ("allow_dolby_vision", `Bool h.allow_dolby_vision);
      ("require_hdr10_fallback_for_dv", `Bool h.require_hdr10_fallback_for_dv);
      ("allow_hdr", `Bool h.allow_hdr);
      ("blocked_hdr_formats", str_list_json h.blocked_hdr_formats);
      ("allowed_resolutions", int_list_json h.allowed_resolutions);
      ( "allowed_protocols",
        str_list_json (List.map Types.protocol_to_string h.allowed_protocols) );
      ("respect_arr_rejections", `Bool h.respect_arr_rejections);
      ("blocked_title_patterns", str_list_json h.blocked_title_patterns);
    ]

let hard_rules_of_yojson ?(d = default_hard_rules) (j : J.t) : hard_rules =
  {
    max_size_gib = get_float_opt "max_size_gib" d.max_size_gib j;
    min_size_gib = get_float_opt "min_size_gib" d.min_size_gib j;
    min_seeders = get_int_opt "min_seeders" d.min_seeders j;
    blocked_groups = get_str_list "blocked_groups" d.blocked_groups j;
    blocked_codecs = get_str_list "blocked_codecs" d.blocked_codecs j;
    allowed_codecs = get_str_list "allowed_codecs" d.allowed_codecs j;
    reject_unknown_codec = get_bool "reject_unknown_codec" d.reject_unknown_codec j;
    blocked_languages = get_str_list "blocked_languages" d.blocked_languages j;
    required_languages = get_str_list "required_languages" d.required_languages j;
    allow_remux = get_bool "allow_remux" d.allow_remux j;
    allow_dolby_vision = get_bool "allow_dolby_vision" d.allow_dolby_vision j;
    require_hdr10_fallback_for_dv =
      get_bool "require_hdr10_fallback_for_dv" d.require_hdr10_fallback_for_dv j;
    allow_hdr = get_bool "allow_hdr" d.allow_hdr j;
    blocked_hdr_formats = get_str_list "blocked_hdr_formats" d.blocked_hdr_formats j;
    allowed_resolutions = get_int_list "allowed_resolutions" d.allowed_resolutions j;
    allowed_protocols =
      get_str_list "allowed_protocols"
        (List.map Types.protocol_to_string d.allowed_protocols)
        j
      |> List.map Types.protocol_of_string;
    respect_arr_rejections =
      get_bool "respect_arr_rejections" d.respect_arr_rejections j;
    blocked_title_patterns =
      get_str_list "blocked_title_patterns" d.blocked_title_patterns j;
  }

let preferences_to_yojson (p : preferences) : J.t =
  `Assoc
    [
      ("preferred_codecs", str_list_json p.preferred_codecs);
      ("disliked_codecs", str_list_json p.disliked_codecs);
      ("preferred_sources", str_list_json p.preferred_sources);
      ("preferred_groups", str_list_json p.preferred_groups);
      ("disliked_groups", str_list_json p.disliked_groups);
      ("preferred_languages", str_list_json p.preferred_languages);
      ("preferred_resolutions", int_list_json p.preferred_resolutions);
      ("preferred_audio", str_list_json p.preferred_audio);
      ("hdr_preference", `String p.hdr_preference);
      ("dolby_vision_preference", `String p.dolby_vision_preference);
      ("prefer_remux", `Bool p.prefer_remux);
      ("prefer_repacks", `Bool p.prefer_repacks);
      ("ideal_size_gib", opt_float_json p.ideal_size_gib);
      ("size_tolerance_gib", `Float p.size_tolerance_gib);
    ]

let preferences_of_yojson ?(d = default_preferences) (j : J.t) : preferences =
  {
    preferred_codecs = get_str_list "preferred_codecs" d.preferred_codecs j;
    disliked_codecs = get_str_list "disliked_codecs" d.disliked_codecs j;
    preferred_sources = get_str_list "preferred_sources" d.preferred_sources j;
    preferred_groups = get_str_list "preferred_groups" d.preferred_groups j;
    disliked_groups = get_str_list "disliked_groups" d.disliked_groups j;
    preferred_languages = get_str_list "preferred_languages" d.preferred_languages j;
    preferred_resolutions = get_int_list "preferred_resolutions" d.preferred_resolutions j;
    preferred_audio = get_str_list "preferred_audio" d.preferred_audio j;
    hdr_preference = get_str "hdr_preference" d.hdr_preference j;
    dolby_vision_preference =
      get_str "dolby_vision_preference" d.dolby_vision_preference j;
    prefer_remux = get_bool "prefer_remux" d.prefer_remux j;
    prefer_repacks = get_bool "prefer_repacks" d.prefer_repacks j;
    ideal_size_gib = get_float_opt "ideal_size_gib" d.ideal_size_gib j;
    size_tolerance_gib = get_float "size_tolerance_gib" d.size_tolerance_gib j;
  }

let weights_to_yojson (w : weights) : J.t =
  `Assoc
    [
      ("custom_format", `Float w.w_custom_format);
      ("quality_weight", `Float w.w_quality_weight);
      ("web_dl_over_webrip", `Float w.w_web_dl_over_webrip);
      ("bluray_over_web", `Float w.w_bluray_over_web);
      ("remux", `Float w.w_remux);
      ("preferred_codec", `Float w.w_preferred_codec);
      ("disliked_codec", `Float w.w_disliked_codec);
      ("preferred_source", `Float w.w_preferred_source);
      ("preferred_group", `Float w.w_preferred_group);
      ("disliked_group", `Float w.w_disliked_group);
      ("preferred_language", `Float w.w_preferred_language);
      ("preferred_resolution", `Float w.w_preferred_resolution);
      ("preferred_audio", `Float w.w_preferred_audio);
      ("hdr", `Float w.w_hdr);
      ("dolby_vision", `Float w.w_dolby_vision);
      ("repack", `Float w.w_repack);
      ("seeders", `Float w.w_seeders);
      ("seeders_cap", `Float w.w_seeders_cap);
      ("size_penalty_per_gib", `Float w.w_size_penalty_per_gib);
      ("arr_approved", `Float w.w_arr_approved);
      ("arr_rejected", `Float w.w_arr_rejected);
      ("age_penalty_per_day", `Float w.w_age_penalty_per_day);
      ("age_penalty_cap", `Float w.w_age_penalty_cap);
    ]

let weights_of_yojson ?(d = default_weights) (j : J.t) : weights =
  {
    w_custom_format = get_float "custom_format" d.w_custom_format j;
    w_quality_weight = get_float "quality_weight" d.w_quality_weight j;
    w_web_dl_over_webrip = get_float "web_dl_over_webrip" d.w_web_dl_over_webrip j;
    w_bluray_over_web = get_float "bluray_over_web" d.w_bluray_over_web j;
    w_remux = get_float "remux" d.w_remux j;
    w_preferred_codec = get_float "preferred_codec" d.w_preferred_codec j;
    w_disliked_codec = get_float "disliked_codec" d.w_disliked_codec j;
    w_preferred_source = get_float "preferred_source" d.w_preferred_source j;
    w_preferred_group = get_float "preferred_group" d.w_preferred_group j;
    w_disliked_group = get_float "disliked_group" d.w_disliked_group j;
    w_preferred_language = get_float "preferred_language" d.w_preferred_language j;
    w_preferred_resolution =
      get_float "preferred_resolution" d.w_preferred_resolution j;
    w_preferred_audio = get_float "preferred_audio" d.w_preferred_audio j;
    w_hdr = get_float "hdr" d.w_hdr j;
    w_dolby_vision = get_float "dolby_vision" d.w_dolby_vision j;
    w_repack = get_float "repack" d.w_repack j;
    w_seeders = get_float "seeders" d.w_seeders j;
    w_seeders_cap = get_float "seeders_cap" d.w_seeders_cap j;
    w_size_penalty_per_gib = get_float "size_penalty_per_gib" d.w_size_penalty_per_gib j;
    w_arr_approved = get_float "arr_approved" d.w_arr_approved j;
    w_arr_rejected = get_float "arr_rejected" d.w_arr_rejected j;
    w_age_penalty_per_day = get_float "age_penalty_per_day" d.w_age_penalty_per_day j;
    w_age_penalty_cap = get_float "age_penalty_cap" d.w_age_penalty_cap j;
  }

let automatic_to_yojson (a : automatic) : J.t =
  `Assoc
    [
      ("enabled", `Bool a.auto_enabled);
      ("interval_seconds", `Int a.auto_interval_seconds);
      ("grab", `Bool a.auto_grab);
      ("search_missing", `Bool a.auto_search_missing);
      ("search_cutoff_unmet", `Bool a.auto_search_cutoff_unmet);
      ("max_items_per_run", `Int a.auto_max_items_per_run);
      ("min_confidence", `Float a.auto_min_confidence);
      ("webhook_trigger", `Bool a.auto_webhook_trigger);
    ]

let automatic_of_yojson ?(d = default_automatic) (j : J.t) : automatic =
  {
    auto_enabled = get_bool "enabled" d.auto_enabled j;
    auto_interval_seconds = get_int "interval_seconds" d.auto_interval_seconds j;
    auto_grab = get_bool "grab" d.auto_grab j;
    auto_search_missing = get_bool "search_missing" d.auto_search_missing j;
    auto_search_cutoff_unmet = get_bool "search_cutoff_unmet" d.auto_search_cutoff_unmet j;
    auto_max_items_per_run = get_int "max_items_per_run" d.auto_max_items_per_run j;
    auto_min_confidence = get_float "min_confidence" d.auto_min_confidence j;
    auto_webhook_trigger = get_bool "webhook_trigger" d.auto_webhook_trigger j;
  }

(** [redact] replaces secrets with "********" for API responses / logs. *)
let to_yojson ?(redact = false) (c : t) : J.t =
  let red s = if redact && s <> "" then "********" else s in
  `Assoc
    [
      ( "instances",
        `List
          (List.map
             (fun i -> instance_to_yojson { i with inst_api_key = red i.inst_api_key })
             c.instances) );
      ("llm", llm_to_yojson { c.llm with llm_api_key = red c.llm.llm_api_key });
      ("hard_rules", hard_rules_to_yojson c.hard_rules);
      ("preferences", preferences_to_yojson c.preferences);
      ("weights", weights_to_yojson c.weights);
      ("nl_preferences", `String c.nl_preferences);
      ("automatic", automatic_to_yojson c.automatic);
      ("log_level", `String c.log_level);
    ]

(** Decode a configuration.  Missing sections fall back to [d] (default:
    [default]).  Instances are validated; an invalid instance is an error. *)
let of_yojson ?(d = default) (j : J.t) : (t, string) result =
  let sub k = match member_opt k j with Some v -> v | None -> `Assoc [] in
  let instances =
    match member_opt "instances" j with
    | Some (`List l) -> List.map instance_of_yojson l
    | _ -> List.map (fun i -> Ok i) d.instances
  in
  match List.find_opt Result.is_error instances with
  | Some (Error e) -> Error e
  | _ ->
      let instances = List.filter_map Result.to_option instances in
      Ok
        {
          instances;
          llm = llm_of_yojson ~d:d.llm (sub "llm");
          hard_rules = hard_rules_of_yojson ~d:d.hard_rules (sub "hard_rules");
          preferences = preferences_of_yojson ~d:d.preferences (sub "preferences");
          weights = weights_of_yojson ~d:d.weights (sub "weights");
          nl_preferences = get_str "nl_preferences" d.nl_preferences j;
          automatic = automatic_of_yojson ~d:d.automatic (sub "automatic");
          log_level = get_str "log_level" d.log_level j;
        }

(** Merge a partial JSON patch into an existing config (used by PUT
    /api/config).  Secrets given as "********" keep their existing value. *)
let patch (existing : t) (j : J.t) : (t, string) result =
  match of_yojson ~d:existing j with
  | Error e -> Error e
  | Ok c ->
      let keep_secret old nw = if nw = "********" then old else nw in
      let instances =
        List.map
          (fun i ->
            match List.find_opt (fun o -> o.inst_id = i.inst_id) existing.instances with
            | Some o -> { i with inst_api_key = keep_secret o.inst_api_key i.inst_api_key }
            | None -> i)
          c.instances
      in
      Ok
        {
          c with
          instances;
          llm =
            {
              c.llm with
              llm_api_key = keep_secret existing.llm.llm_api_key c.llm.llm_api_key;
            };
        }

(* ------------------------------------------------------------------------ *)
(* Environment overrides                                                     *)
(* ------------------------------------------------------------------------ *)

(** Apply environment variables on top of a config.  Recognised variables:

    - SONARR_URL, SONARR_API_KEY      (creates/updates instance "sonarr")
    - RADARR_URL, RADARR_API_KEY      (creates/updates instance "radarr")
    - LLM_ENABLED, LLM_PROVIDER, LLM_BASE_URL, LLM_API_KEY, LLM_MODEL
    - AI_SELECTION_ENABLED (alias for LLM_ENABLED)
    - MAX_RELEASE_SIZE_GIB, MIN_SEEDERS
    - PREFERRED_CODECS, DISALLOWED_CODECS, PREFERRED_SOURCES,
      PREFERRED_RELEASE_GROUPS, BLOCKED_RELEASE_GROUPS, PREFERRED_LANGUAGES
      (comma separated)
    - HDR_PREFERENCE, DOLBY_VISION_PREFERENCE (prefer|neutral|avoid)
    - ALLOW_REMUX, PREFER_REMUX (true|false)
    - NL_PREFERENCES
    - AUTO_MODE_ENABLED, AUTO_MODE_GRAB, AUTO_MODE_INTERVAL_SECONDS
    - LOG_LEVEL

    [getenv] is injected for testability. *)
let apply_env ?(getenv = Sys.getenv_opt) (c : t) : t =
  let env k = match getenv k with Some "" | None -> None | Some v -> Some v in
  let bool_env k d =
    match env k with
    | Some v -> (
        match String.lowercase_ascii v with
        | "1" | "true" | "yes" | "on" -> true
        | "0" | "false" | "no" | "off" -> false
        | _ -> d)
    | None -> d
  in
  let str_env k d = Option.value (env k) ~default:d in
  let float_env_opt k d =
    match env k with Some v -> ( match float_of_string_opt v with Some f -> Some f | None -> d) | None -> d
  in
  let int_env_opt k d =
    match env k with Some v -> ( match int_of_string_opt v with Some i -> Some i | None -> d) | None -> d
  in
  let int_env k d = Option.value (int_env_opt k (Some d)) ~default:d in
  let list_env k d =
    match env k with
    | Some v ->
        String.split_on_char ',' v |> List.map String.trim
        |> List.filter (fun s -> s <> "")
    | None -> d
  in
  let upsert_instance app id name url_k key_k instances =
    match (env url_k, env key_k) with
    | Some url, Some key ->
        let url =
          if String.length url > 0 && url.[String.length url - 1] = '/' then
            String.sub url 0 (String.length url - 1)
          else url
        in
        let existing = List.find_opt (fun i -> i.inst_id = id) instances in
        let inst =
          match existing with
          | Some i -> { i with inst_url = url; inst_api_key = key; inst_enabled = true }
          | None ->
              {
                inst_id = id;
                inst_name = name;
                inst_app = app;
                inst_url = url;
                inst_api_key = key;
                inst_enabled = true;
                inst_nl_preferences = "";
                inst_automatic = false;
              }
        in
        inst :: List.filter (fun i -> i.inst_id <> id) instances
    | _ -> instances
  in
  let instances =
    c.instances
    |> upsert_instance Types.Sonarr "sonarr" "Sonarr" "SONARR_URL" "SONARR_API_KEY"
    |> upsert_instance Types.Radarr "radarr" "Radarr" "RADARR_URL" "RADARR_API_KEY"
    |> List.rev
  in
  let llm_enabled =
    bool_env "LLM_ENABLED" (bool_env "AI_SELECTION_ENABLED" c.llm.llm_enabled)
  in
  {
    c with
    instances;
    llm =
      {
        c.llm with
        llm_enabled;
        llm_provider = str_env "LLM_PROVIDER" c.llm.llm_provider;
        llm_base_url = str_env "LLM_BASE_URL" c.llm.llm_base_url;
        llm_api_key = str_env "LLM_API_KEY" c.llm.llm_api_key;
        llm_model = str_env "LLM_MODEL" c.llm.llm_model;
      };
    hard_rules =
      {
        c.hard_rules with
        max_size_gib = float_env_opt "MAX_RELEASE_SIZE_GIB" c.hard_rules.max_size_gib;
        min_seeders = int_env_opt "MIN_SEEDERS" c.hard_rules.min_seeders;
        blocked_codecs = list_env "DISALLOWED_CODECS" c.hard_rules.blocked_codecs;
        blocked_groups = list_env "BLOCKED_RELEASE_GROUPS" c.hard_rules.blocked_groups;
        allow_remux = bool_env "ALLOW_REMUX" c.hard_rules.allow_remux;
      };
    preferences =
      {
        c.preferences with
        preferred_codecs = list_env "PREFERRED_CODECS" c.preferences.preferred_codecs;
        preferred_sources = list_env "PREFERRED_SOURCES" c.preferences.preferred_sources;
        preferred_groups =
          list_env "PREFERRED_RELEASE_GROUPS" c.preferences.preferred_groups;
        preferred_languages =
          list_env "PREFERRED_LANGUAGES" c.preferences.preferred_languages;
        hdr_preference = str_env "HDR_PREFERENCE" c.preferences.hdr_preference;
        dolby_vision_preference =
          str_env "DOLBY_VISION_PREFERENCE" c.preferences.dolby_vision_preference;
        prefer_remux = bool_env "PREFER_REMUX" c.preferences.prefer_remux;
      };
    nl_preferences = str_env "NL_PREFERENCES" c.nl_preferences;
    automatic =
      {
        c.automatic with
        auto_enabled = bool_env "AUTO_MODE_ENABLED" c.automatic.auto_enabled;
        auto_grab = bool_env "AUTO_MODE_GRAB" c.automatic.auto_grab;
        auto_interval_seconds =
          int_env "AUTO_MODE_INTERVAL_SECONDS" c.automatic.auto_interval_seconds;
      };
    log_level = str_env "LOG_LEVEL" c.log_level;
  }

(** Find an instance by id. *)
let find_instance (c : t) (id : string) : instance option =
  List.find_opt (fun i -> i.inst_id = id) c.instances

(** First enabled instance of the given app (used for the convenience
    routes /api/select/radarr/... and /api/select/sonarr/...). *)
let default_instance (c : t) (app : Types.app) : instance option =
  List.find_opt (fun i -> i.inst_app = app && i.inst_enabled) c.instances

(** Effective natural-language preferences for an instance: global text
    followed by the instance-specific text, each labelled. *)
let effective_nl_preferences (c : t) (inst : instance option) : string =
  let g = String.trim c.nl_preferences in
  let i =
    match inst with
    | Some i when String.trim i.inst_nl_preferences <> "" ->
        Printf.sprintf "%s (%s):\n%s" i.inst_name
          (Types.app_to_string i.inst_app)
          (String.trim i.inst_nl_preferences)
    | _ -> ""
  in
  match (g, i) with
  | "", "" -> ""
  | g, "" -> "Global:\n" ^ g
  | "", i -> i
  | g, i -> "Global:\n" ^ g ^ "\n\n" ^ i
