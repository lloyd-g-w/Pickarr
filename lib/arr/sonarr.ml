(* Typed Sonarr v3/v4 resources and endpoints.

   Verified against vendor/sonarr-openapi.json (Sonarr.Api.V3/openapi.json,
   branch develop; "The v3 API docs apply to both v3 and v4 versions of
   Sonarr") and vendor/sonarr-ReleaseResource.cs /
   vendor/sonarr-ReleaseController.cs. *)

module J = Jsonutil
module R = Resources

(* ------------------------------------------------------------------ *)
(* Resources                                                           *)
(* ------------------------------------------------------------------ *)

(** [ReleaseEpisodeResource]: the episodes a release was mapped onto. *)
type release_episode = {
  re_id : int;
  re_season_number : int;
  re_episode_number : int;
  re_title : string option;
}

let release_episode_of_yojson j =
  {
    re_id = J.int_def "id" 0 j;
    re_season_number = J.int_def "seasonNumber" 0 j;
    re_episode_number = J.int_def "episodeNumber" 0 j;
    re_title = J.non_empty (J.string_opt "title" j);
  }

(** [ReleaseResource] as returned by [GET /api/v3/release]. *)
type release_resource = {
  rr_id : int;
  rr_guid : string option;
  rr_title : string;
  rr_size : int64;
  rr_indexer : string option;
  rr_indexer_id : int;
  rr_seeders : int option;
  rr_leechers : int option;
  rr_protocol : string option;  (** DownloadProtocol: unknown|usenet|torrent *)
  rr_age : int;
  rr_age_hours : float option;
  rr_publish_date : string option;
  rr_quality : R.quality_model option;
  rr_quality_weight : int option;
  rr_languages : string list;
  rr_release_group : string option;
  rr_custom_formats : R.custom_format list;
  rr_custom_format_score : int option;
  rr_approved : bool;
  rr_rejected : bool;
  rr_temporarily_rejected : bool;
  rr_rejections : string list;
  rr_download_allowed : bool;
  rr_full_season : bool;
  rr_season_number : int option;
  rr_mapped_episode_info : release_episode list;
  rr_mapped_series_id : int option;
  rr_episode_requested : bool;
  rr_raw : Yojson.Safe.t;
}

let release_resource_of_yojson j =
  {
    rr_id = J.int_def "id" 0 j;
    rr_guid = J.non_empty (J.string_opt "guid" j);
    rr_title = J.string_def "title" "" j;
    rr_size = J.int64_def "size" 0L j;
    rr_indexer = J.non_empty (J.string_opt "indexer" j);
    rr_indexer_id = J.int_def "indexerId" 0 j;
    rr_seeders = J.int_opt "seeders" j;
    rr_leechers = J.int_opt "leechers" j;
    rr_protocol = J.non_empty (J.string_opt "protocol" j);
    rr_age = J.int_def "age" 0 j;
    rr_age_hours = J.float_opt "ageHours" j;
    rr_publish_date = J.non_empty (J.string_opt "publishDate" j);
    rr_quality = Option.map R.quality_model_of_yojson (J.member "quality" j);
    rr_quality_weight = J.int_opt "qualityWeight" j;
    rr_languages = R.language_names j "languages";
    rr_release_group = J.non_empty (J.string_opt "releaseGroup" j);
    rr_custom_formats = R.custom_formats j "customFormats";
    rr_custom_format_score = J.int_opt "customFormatScore" j;
    rr_approved = J.bool_def "approved" false j;
    rr_rejected = J.bool_def "rejected" false j;
    rr_temporarily_rejected = J.bool_def "temporarilyRejected" false j;
    rr_rejections = J.string_list "rejections" j;
    rr_download_allowed = J.bool_def "downloadAllowed" true j;
    rr_full_season = J.bool_def "fullSeason" false j;
    rr_season_number =
      (match J.int_opt "mappedSeasonNumber" j with
      | Some n -> Some n
      | None -> J.int_opt "seasonNumber" j);
    rr_mapped_episode_info =
      J.list_def "mappedEpisodeInfo" j |> List.map release_episode_of_yojson;
    rr_mapped_series_id = J.int_opt "mappedSeriesId" j;
    rr_episode_requested = J.bool_def "episodeRequested" false j;
    rr_raw = j;
  }

(** [SeriesResource]: only the fields that inform release selection. *)
type series_resource = {
  sr_id : int;
  sr_title : string;
  sr_year : int option;
  sr_series_type : string option;  (** SeriesTypes: standard | daily | anime *)
  sr_genres : string list;
  sr_tags : int list;
  sr_quality_profile_id : int option;
  sr_runtime : int option;
  sr_overview : string option;
  sr_network : string option;
  sr_certification : string option;
  sr_original_language : string option;
  sr_path : string option;
  sr_monitored : bool;
  sr_status : string option;
  sr_tvdb_id : int option;
  sr_imdb_id : string option;
  sr_profile_name : string option;
}

let series_resource_of_yojson j =
  {
    sr_id = J.int_def "id" 0 j;
    sr_title = J.string_def "title" "" j;
    sr_year = (match J.int_opt "year" j with Some 0 -> None | v -> v);
    sr_series_type = J.non_empty (J.string_opt "seriesType" j);
    sr_genres = J.string_list "genres" j;
    sr_tags = J.int_list "tags" j;
    sr_quality_profile_id = J.int_opt "qualityProfileId" j;
    sr_runtime = (match J.int_opt "runtime" j with Some 0 -> None | v -> v);
    sr_overview = J.non_empty (J.string_opt "overview" j);
    sr_network = J.non_empty (J.string_opt "network" j);
    sr_certification = J.non_empty (J.string_opt "certification" j);
    sr_original_language =
      (match J.member "originalLanguage" j with
      | Some l -> (R.language_of_yojson l).R.lang_name
      | None -> None);
    sr_path = J.non_empty (J.string_opt "path" j);
    sr_monitored = J.bool_def "monitored" true j;
    sr_status = J.non_empty (J.string_opt "status" j);
    sr_tvdb_id = J.int_opt "tvdbId" j;
    sr_imdb_id = J.non_empty (J.string_opt "imdbId" j);
    sr_profile_name = J.non_empty (J.string_opt "profileName" j);
  }

(** [EpisodeResource]. [er_series] is populated when the endpoint was asked
    for [includeSeries=true] (or by [GET /api/v3/episode/{id}]). *)
type episode_resource = {
  er_id : int;
  er_series_id : int;
  er_season_number : int;
  er_episode_number : int;
  er_title : string option;
  er_overview : string option;
  er_air_date_utc : string option;
  er_runtime : int option;
  er_has_file : bool;
  er_monitored : bool;
  er_episode_file_quality : string option;
  er_series : series_resource option;
}

let episode_resource_of_yojson j =
  {
    er_id = J.int_def "id" 0 j;
    er_series_id = J.int_def "seriesId" 0 j;
    er_season_number = J.int_def "seasonNumber" 0 j;
    er_episode_number = J.int_def "episodeNumber" 0 j;
    er_title = J.non_empty (J.string_opt "title" j);
    er_overview = J.non_empty (J.string_opt "overview" j);
    er_air_date_utc = J.non_empty (J.string_opt "airDateUtc" j);
    er_runtime = (match J.int_opt "runtime" j with Some 0 -> None | v -> v);
    er_has_file = J.bool_def "hasFile" false j;
    er_monitored = J.bool_def "monitored" true j;
    er_episode_file_quality =
      (match J.member "episodeFile" j with
      | None -> None
      | Some f -> (
          match Option.map R.quality_model_of_yojson (J.member "quality" f) with
          | Some { R.qm_quality = Some q; _ } -> q.R.quality_name
          | _ -> None));
    er_series = Option.map series_resource_of_yojson (J.member "series" j);
  }

(** [QueueResource] fields needed to know what is already downloading. *)
type queue_item = { qi_id : int; qi_episode_id : int option; qi_series_id : int option }

let queue_item_of_yojson j =
  {
    qi_id = J.int_def "id" 0 j;
    qi_episode_id = J.int_opt "episodeId" j;
    qi_series_id = J.int_opt "seriesId" j;
  }

(** [HistoryResource] fields needed for the "grabbed recently" check. *)
type history_item = {
  hi_id : int;
  hi_episode_id : int option;
  hi_series_id : int option;
  hi_event_type : string option;
  hi_date : string option;
  hi_source_title : string option;
}

let history_item_of_yojson j =
  {
    hi_id = J.int_def "id" 0 j;
    hi_episode_id = J.int_opt "episodeId" j;
    hi_series_id = J.int_opt "seriesId" j;
    hi_event_type = J.non_empty (J.string_opt "eventType" j);
    hi_date = J.non_empty (J.string_opt "date" j);
    hi_source_title = J.non_empty (J.string_opt "sourceTitle" j);
  }

(* ------------------------------------------------------------------ *)
(* Endpoints                                                           *)
(* ------------------------------------------------------------------ *)

let ( let* ) = Lwt.bind
let ok x = Lwt.return (Ok x)

let map_result f = function Ok v -> Ok (f v) | Error e -> Error e

(** [GET /api/v3/system/status] *)
let system_status ~base_url ~api_key () =
  let* r = Http.get ~base_url ~api_key "/api/v3/system/status" in
  Lwt.return (map_result R.system_status_of_yojson r)

(** [GET /api/v3/episode/{id}] *)
let episode ~base_url ~api_key id =
  let* r = Http.get ~base_url ~api_key (Printf.sprintf "/api/v3/episode/%d" id) in
  Lwt.return (map_result episode_resource_of_yojson r)

(** [GET /api/v3/series/{id}] *)
let series ~base_url ~api_key id =
  let* r = Http.get ~base_url ~api_key (Printf.sprintf "/api/v3/series/%d" id) in
  Lwt.return (map_result series_resource_of_yojson r)

(** [GET /api/v3/tag] *)
let tags ~base_url ~api_key () =
  let* r = Http.get ~base_url ~api_key "/api/v3/tag" in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "tags" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map R.tag_of_yojson l))

(** [GET /api/v3/qualityprofile/{id}] *)
let quality_profile ~base_url ~api_key id =
  let* r = Http.get ~base_url ~api_key (Printf.sprintf "/api/v3/qualityprofile/%d" id) in
  Lwt.return (map_result R.quality_profile_of_yojson r)

(** [GET /api/v3/release?episodeId=]  (interactive search for one episode) *)
let releases_for_episode ~base_url ~api_key episode_id =
  let* r =
    Http.get ~base_url ~api_key
      ~query:[ ("episodeId", string_of_int episode_id) ]
      "/api/v3/release"
  in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "releases" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map release_resource_of_yojson l))

(** [GET /api/v3/release?seriesId=&seasonNumber=]  (season pack search) *)
let releases_for_season ~base_url ~api_key ~series_id ~season_number =
  let* r =
    Http.get ~base_url ~api_key
      ~query:
        [
          ("seriesId", string_of_int series_id);
          ("seasonNumber", string_of_int season_number);
        ]
      "/api/v3/release"
  in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "releases" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map release_resource_of_yojson l))

(** [POST /api/v3/release] — tells Sonarr to grab a release it has already
    offered us.  The release must still be in Sonarr's 30-minute remote
    episode cache, keyed by [indexerId ^ "_" ^ guid]. *)
let grab ~base_url ~api_key body =
  let* r = Http.post ~base_url ~api_key "/api/v3/release" body in
  Lwt.return (map_result (fun _ -> ()) r)

(** [GET /api/v3/wanted/missing] or [GET /api/v3/wanted/cutoff]. *)
let wanted ~base_url ~api_key ~kind ~page ~page_size =
  let path =
    match kind with `Missing -> "/api/v3/wanted/missing" | `Cutoff -> "/api/v3/wanted/cutoff"
  in
  let* r =
    Http.get ~base_url ~api_key
      ~query:
        [
          ("page", string_of_int page);
          ("pageSize", string_of_int page_size);
          ("includeSeries", "true");
          ("monitored", "true");
        ]
      path
  in
  Lwt.return (map_result (R.paging_of_yojson episode_resource_of_yojson) r)

(** [GET /api/v3/queue] *)
let queue ~base_url ~api_key ~page_size =
  let* r =
    Http.get ~base_url ~api_key
      ~query:
        [
          ("page", "1");
          ("pageSize", string_of_int page_size);
          ("includeUnknownSeriesItems", "true");
        ]
      "/api/v3/queue"
  in
  Lwt.return (map_result (R.paging_of_yojson queue_item_of_yojson) r)

(** [GET /api/v3/history/since?date=&eventType=grabbed] — returns a plain
    array.  [eventType] here is the string form of [EpisodeHistoryEventType]
    (unlike [/api/v3/history], whose filter is an int array with unverified
    numbering).  Callers still filter on the response's string [eventType],
    so an instance that rejects the parameter is handled by [?event_type]
    being dropped. *)
let history_since ~base_url ~api_key ?event_type ~date () =
  let query =
    ("date", date)
    :: (match event_type with Some e -> [ ("eventType", e) ] | None -> [])
  in
  let* r = Http.get ~base_url ~api_key ~query "/api/v3/history/since" in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "history records" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map history_item_of_yojson l))
