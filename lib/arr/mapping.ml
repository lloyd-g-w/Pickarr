(* Mapping from Sonarr/Radarr API resources onto Pickarr's internal model,
   plus the (pure) request bodies used to grab a release.

   Sonarr and Radarr describe a release's quality but never its video codec,
   audio format, HDR flavour or Dolby Vision profile, so those are recovered
   from the release title with [Pickarr_core.Title_parser]. *)

module T = Pickarr_core.Types
module TP = Pickarr_core.Title_parser
module J = Jsonutil
module R = Resources

(* ------------------------------------------------------------------ *)
(* Small helpers                                                       *)
(* ------------------------------------------------------------------ *)

let or_else opt fallback = match opt with Some _ -> opt | None -> fallback

(** Stable identifier for a release.  Sonarr/Radarr always send a [guid], but
    it is nullable in the schema, so fall back to a digest of the title and
    indexer. *)
let release_id ~guid ~title ~indexer_id =
  match guid with
  | Some g when String.trim g <> "" -> g
  | _ -> Digest.to_hex (Digest.string (Printf.sprintf "%s|%d" title indexer_id))

let protocol_of_string_opt = function
  | None -> T.Unknown_protocol
  | Some s -> T.protocol_of_string s

(* A source is "unknown" in the API for anything the *arr parser did not
   recognise; in that case trust the title instead. *)
let known_source = function
  | None -> None
  | Some s -> (
      match String.lowercase_ascii s with "unknown" | "" -> None | _ -> Some s)

(* (name, source, resolution, modifier, is_repack, is_proper) *)
let quality_parts (qm : R.quality_model option) =
  match qm with
  | None -> (None, None, None, None, false, false)
  | Some { R.qm_quality; qm_revision } ->
      let name = Option.bind qm_quality (fun q -> q.R.quality_name) in
      let source = Option.bind qm_quality (fun q -> q.R.quality_source) in
      let resolution =
        Option.bind qm_quality (fun q ->
            match q.R.quality_resolution with Some 0 -> None | v -> v)
      in
      let modifier = Option.bind qm_quality (fun q -> q.R.quality_modifier) in
      let is_repack =
        match qm_revision with Some r -> r.R.rev_is_repack | None -> false
      in
      let is_proper =
        match qm_revision with Some r -> r.R.rev_version > 1 | None -> false
      in
      (name, source, resolution, modifier, is_repack, is_proper)

let is_remux ~modifier ~parsed_source =
  (match modifier with
  | Some m -> String.lowercase_ascii m = "remux"
  | None -> false)
  || parsed_source = Some "Remux"

(* Shared tail of the two release mappings: everything derived from the
   title plus the quality model. *)
let derive ~title ~api_source ~api_resolution ~api_modifier ~api_group ~api_languages =
  let parsed = TP.parse title in
  let remux = is_remux ~modifier:api_modifier ~parsed_source:parsed.TP.source in
  let source =
    if remux then Some "Remux"
    else
      match known_source api_source with
      | Some s -> Some (TP.normalise_source s)
      | None -> parsed.TP.source
  in
  let modifier =
    match api_modifier with
    | Some m when String.lowercase_ascii m <> "none" -> Some m
    | _ -> if remux then Some "remux" else None
  in
  let resolution = or_else api_resolution parsed.TP.resolution in
  let languages = if api_languages = [] then parsed.TP.languages else api_languages in
  let release_group = or_else (J.non_empty api_group) parsed.TP.release_group in
  (parsed, source, modifier, resolution, languages, release_group)

(* ------------------------------------------------------------------ *)
(* Releases                                                            *)
(* ------------------------------------------------------------------ *)

(** Map a Sonarr [ReleaseResource] onto {!Pickarr_core.Types.release}. *)
let release_of_sonarr (rr : Sonarr.release_resource) : T.release =
  let name, api_source, api_resolution, api_modifier, is_repack, is_proper =
    quality_parts rr.Sonarr.rr_quality
  in
  let parsed, source, modifier, resolution, languages, release_group =
    derive ~title:rr.Sonarr.rr_title ~api_source ~api_resolution ~api_modifier
      ~api_group:rr.Sonarr.rr_release_group ~api_languages:rr.Sonarr.rr_languages
  in
  {
    T.id =
      release_id ~guid:rr.Sonarr.rr_guid ~title:rr.Sonarr.rr_title
        ~indexer_id:rr.Sonarr.rr_indexer_id;
    guid = rr.Sonarr.rr_guid;
    indexer_id = (if rr.Sonarr.rr_indexer_id = 0 then None else Some rr.Sonarr.rr_indexer_id);
    indexer = rr.Sonarr.rr_indexer;
    title = rr.Sonarr.rr_title;
    size_bytes = rr.Sonarr.rr_size;
    seeders = rr.Sonarr.rr_seeders;
    leechers = rr.Sonarr.rr_leechers;
    protocol = protocol_of_string_opt rr.Sonarr.rr_protocol;
    age_hours = rr.Sonarr.rr_age_hours;
    publish_date = rr.Sonarr.rr_publish_date;
    quality = name;
    quality_source = api_source;
    resolution;
    quality_modifier = modifier;
    quality_weight = rr.Sonarr.rr_quality_weight;
    is_repack = is_repack || parsed.TP.is_repack;
    is_proper = is_proper || parsed.TP.is_proper;
    source;
    codec = parsed.TP.codec;
    audio = parsed.TP.audio;
    hdr = parsed.TP.hdr;
    dolby_vision = parsed.TP.dolby_vision;
    dv_profile = parsed.TP.dv_profile;
    release_group;
    languages;
    custom_formats =
      List.map
        (fun (c : R.custom_format) ->
          { T.cf_id = c.R.cf_id; cf_name = Option.value c.R.cf_name ~default:"" })
        rr.Sonarr.rr_custom_formats;
    custom_format_score = rr.Sonarr.rr_custom_format_score;
    arr_approved = rr.Sonarr.rr_approved;
    arr_rejected = rr.Sonarr.rr_rejected;
    arr_temporarily_rejected = rr.Sonarr.rr_temporarily_rejected;
    arr_rejection_reasons = rr.Sonarr.rr_rejections;
    download_allowed = rr.Sonarr.rr_download_allowed;
    full_season = rr.Sonarr.rr_full_season;
    season_number = rr.Sonarr.rr_season_number;
    mapped_episode_ids =
      List.map (fun (e : Sonarr.release_episode) -> e.Sonarr.re_id) rr.Sonarr.rr_mapped_episode_info;
    raw = rr.Sonarr.rr_raw;
  }

(** Map a Radarr [ReleaseResource] onto {!Pickarr_core.Types.release}. *)
let release_of_radarr (rr : Radarr.release_resource) : T.release =
  let name, api_source, api_resolution, api_modifier, is_repack, is_proper =
    quality_parts rr.Radarr.rr_quality
  in
  let parsed, source, modifier, resolution, languages, release_group =
    derive ~title:rr.Radarr.rr_title ~api_source ~api_resolution ~api_modifier
      ~api_group:rr.Radarr.rr_release_group ~api_languages:rr.Radarr.rr_languages
  in
  {
    T.id =
      release_id ~guid:rr.Radarr.rr_guid ~title:rr.Radarr.rr_title
        ~indexer_id:rr.Radarr.rr_indexer_id;
    guid = rr.Radarr.rr_guid;
    indexer_id = (if rr.Radarr.rr_indexer_id = 0 then None else Some rr.Radarr.rr_indexer_id);
    indexer = rr.Radarr.rr_indexer;
    title = rr.Radarr.rr_title;
    size_bytes = rr.Radarr.rr_size;
    seeders = rr.Radarr.rr_seeders;
    leechers = rr.Radarr.rr_leechers;
    protocol = protocol_of_string_opt rr.Radarr.rr_protocol;
    age_hours = rr.Radarr.rr_age_hours;
    publish_date = rr.Radarr.rr_publish_date;
    quality = name;
    quality_source = api_source;
    resolution;
    quality_modifier = modifier;
    quality_weight = rr.Radarr.rr_quality_weight;
    is_repack = is_repack || parsed.TP.is_repack;
    is_proper = is_proper || parsed.TP.is_proper;
    source;
    codec = parsed.TP.codec;
    audio = parsed.TP.audio;
    hdr = parsed.TP.hdr;
    dolby_vision = parsed.TP.dolby_vision;
    dv_profile = parsed.TP.dv_profile;
    release_group;
    languages;
    custom_formats =
      List.map
        (fun (c : R.custom_format) ->
          { T.cf_id = c.R.cf_id; cf_name = Option.value c.R.cf_name ~default:"" })
        rr.Radarr.rr_custom_formats;
    custom_format_score = rr.Radarr.rr_custom_format_score;
    arr_approved = rr.Radarr.rr_approved;
    arr_rejected = rr.Radarr.rr_rejected;
    arr_temporarily_rejected = rr.Radarr.rr_temporarily_rejected;
    arr_rejection_reasons = rr.Radarr.rr_rejections;
    download_allowed = rr.Radarr.rr_download_allowed;
    full_season = false;
    season_number = None;
    mapped_episode_ids = [];
    raw = rr.Radarr.rr_raw;
  }

(* ------------------------------------------------------------------ *)
(* Media                                                               *)
(* ------------------------------------------------------------------ *)

let tag_labels (tags : R.tag list) (ids : int list) =
  List.filter_map
    (fun id ->
      match List.find_opt (fun (t : R.tag) -> t.R.tag_id = id) tags with
      | Some t -> t.R.tag_label
      | None -> None)
    ids

let some_string k = function Some v -> [ (k, `String v) ] | None -> []
let some_int k = function Some v -> [ (k, `Int v) ] | None -> []

(* Fields every Sonarr media kind copies from its series. *)
let series_extra (series : Sonarr.series_resource) =
  [ ("series_id", `Int series.Sonarr.sr_id) ]
  @ some_int "tvdb_id" series.Sonarr.sr_tvdb_id
  @ some_int "tmdb_id" series.Sonarr.sr_tmdb_id
  @ some_string "imdb_id" series.Sonarr.sr_imdb_id
  (* Both link builders read these: Sonarr's UI addresses a series by
     titleSlug, Seerr addresses TV by TMDB id. *)
  @ some_string "title_slug" series.Sonarr.sr_title_slug
  @ some_string "network" series.Sonarr.sr_network
  @ some_string "certification" series.Sonarr.sr_certification
  @ some_string "series_status" series.Sonarr.sr_status

(* An episode counts as missing when it is monitored and has no file; only
   monitored episodes are Pickarr's business. *)
let is_missing (ep : Sonarr.episode_resource) =
  ep.Sonarr.er_monitored && not ep.Sonarr.er_has_file

let first_existing_quality (episodes : Sonarr.episode_resource list) =
  List.fold_left
    (fun acc (ep : Sonarr.episode_resource) -> or_else acc ep.Sonarr.er_episode_file_quality)
    None episodes

(** Build {!Pickarr_core.Types.media} for a Sonarr episode.  [series] is
    required for genres/series type; [tags] and [profile_name] are
    best-effort and may be [[]] / [None]. *)
let media_of_episode ?(tags = []) ?profile_name (ep : Sonarr.episode_resource)
    (series : Sonarr.series_resource) : T.media =
  {
    T.app = T.Sonarr;
    media_id = ep.Sonarr.er_id;
    title = series.Sonarr.sr_title;
    year = series.Sonarr.sr_year;
    media_kind = "episode";
    series_type = series.Sonarr.sr_series_type;
    season_number = Some ep.Sonarr.er_season_number;
    episode_number = Some ep.Sonarr.er_episode_number;
    episode_title = ep.Sonarr.er_title;
    genres = series.Sonarr.sr_genres;
    runtime_minutes = or_else ep.Sonarr.er_runtime series.Sonarr.sr_runtime;
    quality_profile_id = series.Sonarr.sr_quality_profile_id;
    quality_profile_name = or_else profile_name series.Sonarr.sr_profile_name;
    tags = tag_labels tags series.Sonarr.sr_tags;
    overview = or_else ep.Sonarr.er_overview series.Sonarr.sr_overview;
    original_language = series.Sonarr.sr_original_language;
    has_file = ep.Sonarr.er_has_file;
    existing_quality = ep.Sonarr.er_episode_file_quality;
    monitored = ep.Sonarr.er_monitored;
    path = series.Sonarr.sr_path;
    extra = series_extra series @ some_string "air_date_utc" ep.Sonarr.er_air_date_utc;
  }

let media_of_sonarr_group ~(kind : string) ~(season_number : int option)
    ?(tags = []) ?profile_name (episodes : Sonarr.episode_resource list)
    (series : Sonarr.series_resource) : T.media =
  let missing = List.filter is_missing episodes in
  let total = List.length episodes in
  {
    T.app = T.Sonarr;
    (* Both a season and a whole series are addressed by their series id:
       the season number (when any) says which part of it is meant. *)
    media_id = series.Sonarr.sr_id;
    title = series.Sonarr.sr_title;
    year = series.Sonarr.sr_year;
    media_kind = kind;
    series_type = series.Sonarr.sr_series_type;
    season_number;
    episode_number = None;
    episode_title = None;
    genres = series.Sonarr.sr_genres;
    runtime_minutes = series.Sonarr.sr_runtime;
    quality_profile_id = series.Sonarr.sr_quality_profile_id;
    quality_profile_name = or_else profile_name series.Sonarr.sr_profile_name;
    tags = tag_labels tags series.Sonarr.sr_tags;
    overview = series.Sonarr.sr_overview;
    original_language = series.Sonarr.sr_original_language;
    has_file = total > 0 && missing = [];
    existing_quality = first_existing_quality episodes;
    monitored =
      series.Sonarr.sr_monitored
      && (episodes = [] || List.exists (fun (e : Sonarr.episode_resource) -> e.Sonarr.er_monitored) episodes);
    path = series.Sonarr.sr_path;
    extra =
      series_extra series
      @ [
          ("total_episodes", `Int total);
          ("missing_episodes", `Int (List.length missing));
          ( "missing_episode_ids",
            `List (List.map (fun (e : Sonarr.episode_resource) -> `Int e.Sonarr.er_id) missing) );
        ];
  }

(** Build {!Pickarr_core.Types.media} for one Sonarr season
    ([media_kind = "season"], [media_id] = the series id).  [episodes] must
    be the episodes of that season. *)
let media_of_season ?tags ?profile_name ~(season_number : int)
    (episodes : Sonarr.episode_resource list) (series : Sonarr.series_resource) : T.media =
  media_of_sonarr_group ~kind:"season" ~season_number:(Some season_number) ?tags
    ?profile_name episodes series

(** Build {!Pickarr_core.Types.media} for a whole Sonarr series
    ([media_kind = "series"]).  [episodes] must be every episode of the
    series.  A series is never searched directly (Sonarr has no series-wide
    release search); it is the label and context for per-season work. *)
let media_of_series ?tags ?profile_name (episodes : Sonarr.episode_resource list)
    (series : Sonarr.series_resource) : T.media =
  media_of_sonarr_group ~kind:"series" ~season_number:None ?tags ?profile_name episodes
    series

(** Build {!Pickarr_core.Types.media} for a Radarr movie. *)
let media_of_movie ?(tags = []) ?profile_name (m : Radarr.movie_resource) : T.media =
  {
    T.app = T.Radarr;
    media_id = m.Radarr.mr_id;
    title = m.Radarr.mr_title;
    year = m.Radarr.mr_year;
    media_kind = "movie";
    series_type = None;
    season_number = None;
    episode_number = None;
    episode_title = None;
    genres = m.Radarr.mr_genres;
    runtime_minutes = m.Radarr.mr_runtime;
    quality_profile_id = m.Radarr.mr_quality_profile_id;
    quality_profile_name = profile_name;
    tags = tag_labels tags m.Radarr.mr_tags;
    overview = m.Radarr.mr_overview;
    original_language = m.Radarr.mr_original_language;
    has_file = m.Radarr.mr_has_file;
    existing_quality = m.Radarr.mr_movie_file_quality;
    monitored = m.Radarr.mr_monitored;
    path = m.Radarr.mr_path;
    extra =
      some_int "tmdb_id" m.Radarr.mr_tmdb_id
      @ some_string "imdb_id" m.Radarr.mr_imdb_id
      @ some_string "title_slug" m.Radarr.mr_title_slug
      @ some_string "original_title" m.Radarr.mr_original_title
      @ some_string "studio" m.Radarr.mr_studio
      @ some_string "certification" m.Radarr.mr_certification
      @ some_string "movie_status" m.Radarr.mr_status
      @ some_string "in_cinemas" m.Radarr.mr_in_cinemas
      @ some_string "digital_release" m.Radarr.mr_digital_release
      @ some_string "physical_release" m.Radarr.mr_physical_release;
  }

(* ------------------------------------------------------------------ *)
(* Grab bodies                                                         *)
(* ------------------------------------------------------------------ *)

(* Sonarr's and Radarr's ReleaseController both validate IndexerId (must be a
   valid id) and Guid (must not be empty), then look the release up in the
   30-minute remote-episode / remote-movie cache keyed by
   "{indexerId}_{guid}".  Everything else in the body is only consulted when
   the cached decision has no series/movie attached, so we send the media id
   as a safety net but never set shouldOverride (which would let us change
   the quality Sonarr/Radarr recorded). *)

type grab_error = Missing_guid | Missing_indexer

let grab_error_message = function
  | Missing_guid -> "release has no guid; Sonarr/Radarr cannot identify it for a grab"
  | Missing_indexer -> "release has no indexerId; Sonarr/Radarr cannot identify it for a grab"

let grab_identity (r : T.release) : (string * int, grab_error) result =
  match (r.T.guid, r.T.indexer_id) with
  | None, _ -> Error Missing_guid
  | Some g, _ when String.trim g = "" -> Error Missing_guid
  | _, None -> Error Missing_indexer
  | _, Some i when i <= 0 -> Error Missing_indexer
  | Some g, Some i -> Ok (g, i)

(** [POST /api/v3/release] body for Sonarr.

    For an episode selection [media_id] is the episode id; for a season or a
    whole-series selection it is the series id, so the hint has to be sent
    under the matching key ([docs/API_RESEARCH.md] §3.2: [seriesId],
    [episodeId] and [episodeIds] are all optional inputs).  Sonarr maps a
    pack to its episodes from the cached decision either way. *)
let sonarr_grab_body ~guid ~indexer_id ~(media : T.media) : Yojson.Safe.t =
  let media_hint =
    match media.T.media_kind with
    | "episode" -> [ ("episodeId", `Int media.T.media_id) ]
    | "season" | "series" -> [ ("seriesId", `Int media.T.media_id) ]
    | _ -> []
  in
  `Assoc ([ ("guid", `String guid); ("indexerId", `Int indexer_id) ] @ media_hint)

(** [POST /api/v3/release] body for Radarr. *)
let radarr_grab_body ~guid ~indexer_id ~(media : T.media) : Yojson.Safe.t =
  `Assoc
    [
      ("guid", `String guid);
      ("indexerId", `Int indexer_id);
      ("movieId", `Int media.T.media_id);
    ]

(* ------------------------------------------------------------------ *)
(* Webhooks                                                            *)
(* ------------------------------------------------------------------ *)

(* Payload classes: vendor/{sonarr,radarr}-webhook/*.cs.  [eventType] is
   serialised with PascalCase names ("Test", "Grab", "Download",
   "SeriesAdd", "MovieAdded", "ManualInteractionRequired", ...). *)

(** [parse_webhook app body] returns the event type and the ids of the media
    items it concerns (episode ids for Sonarr, the movie id for Radarr). *)
let parse_webhook (app : T.app) (body : Yojson.Safe.t) : (string * int list, string) result =
  match J.member_any [ "eventType"; "EventType" ] body with
  | Some (`String event) ->
      let ids =
        match app with
        | T.Sonarr ->
            J.list_def "episodes" body
            |> List.filter_map (fun e -> J.int_opt "id" e)
        | T.Radarr -> (
            match J.member "movie" body with
            | Some m -> ( match J.int_opt "id" m with Some id -> [ id ] | None -> [])
            | None -> [])
      in
      Ok (event, ids)
  | _ -> Error "webhook payload has no eventType"
