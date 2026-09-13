(* Typed Radarr v3 resources and endpoints.

   Verified against vendor/radarr-openapi.json (Radarr.Api.V3/openapi.json,
   branch develop) and vendor/radarr-ReleaseResource.cs /
   vendor/radarr-ReleaseController.cs. *)

module J = Jsonutil
module R = Resources

(* ------------------------------------------------------------------ *)
(* Resources                                                           *)
(* ------------------------------------------------------------------ *)

(** [ReleaseResource] as returned by [GET /api/v3/release?movieId=]. *)
type release_resource = {
  rr_id : int;
  rr_guid : string option;
  rr_title : string;
  rr_size : int64;
  rr_indexer : string option;
  rr_indexer_id : int;
  rr_seeders : int option;
  rr_leechers : int option;
  rr_protocol : string option;
  rr_age : int;
  rr_age_hours : float option;
  rr_publish_date : string option;
  rr_quality : R.quality_model option;
  rr_quality_weight : int option;
  rr_languages : string list;
  rr_release_group : string option;
  rr_edition : string option;
  rr_custom_formats : R.custom_format list;
  rr_custom_format_score : int option;
  rr_approved : bool;
  rr_rejected : bool;
  rr_temporarily_rejected : bool;
  rr_rejections : string list;
  rr_download_allowed : bool;
  rr_mapped_movie_id : int option;
  rr_movie_requested : bool;
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
    rr_edition = J.non_empty (J.string_opt "edition" j);
    rr_custom_formats = R.custom_formats j "customFormats";
    rr_custom_format_score = J.int_opt "customFormatScore" j;
    rr_approved = J.bool_def "approved" false j;
    rr_rejected = J.bool_def "rejected" false j;
    rr_temporarily_rejected = J.bool_def "temporarilyRejected" false j;
    rr_rejections = J.string_list "rejections" j;
    rr_download_allowed = J.bool_def "downloadAllowed" true j;
    rr_mapped_movie_id = J.int_opt "mappedMovieId" j;
    rr_movie_requested = J.bool_def "movieRequested" false j;
    rr_raw = j;
  }

(** [MovieResource]: the fields that inform release selection. *)
type movie_resource = {
  mr_id : int;
  mr_title : string;
  mr_original_title : string option;
  mr_year : int option;
  mr_genres : string list;
  mr_tags : int list;
  mr_quality_profile_id : int option;
  mr_runtime : int option;
  mr_overview : string option;
  mr_studio : string option;
  mr_certification : string option;
  mr_original_language : string option;
  mr_path : string option;
  mr_monitored : bool;
  mr_has_file : bool;
  mr_movie_file_quality : string option;
  mr_status : string option;
  mr_tmdb_id : int option;
  mr_imdb_id : string option;
  mr_in_cinemas : string option;
  mr_digital_release : string option;
  mr_physical_release : string option;
  mr_size_on_disk : int64;
}

let movie_resource_of_yojson j =
  {
    mr_id = J.int_def "id" 0 j;
    mr_title = J.string_def "title" "" j;
    mr_original_title = J.non_empty (J.string_opt "originalTitle" j);
    mr_year = (match J.int_opt "year" j with Some 0 -> None | v -> v);
    mr_genres = J.string_list "genres" j;
    mr_tags = J.int_list "tags" j;
    mr_quality_profile_id = J.int_opt "qualityProfileId" j;
    mr_runtime = (match J.int_opt "runtime" j with Some 0 -> None | v -> v);
    mr_overview = J.non_empty (J.string_opt "overview" j);
    mr_studio = J.non_empty (J.string_opt "studio" j);
    mr_certification = J.non_empty (J.string_opt "certification" j);
    mr_original_language =
      (match J.member "originalLanguage" j with
      | Some l -> (R.language_of_yojson l).R.lang_name
      | None -> None);
    mr_path = J.non_empty (J.string_opt "path" j);
    mr_monitored = J.bool_def "monitored" true j;
    mr_has_file = J.bool_def "hasFile" false j;
    mr_movie_file_quality =
      (match J.member "movieFile" j with
      | None -> None
      | Some f -> (
          match Option.map R.quality_model_of_yojson (J.member "quality" f) with
          | Some { R.qm_quality = Some q; _ } -> q.R.quality_name
          | _ -> None));
    mr_status = J.non_empty (J.string_opt "status" j);
    mr_tmdb_id = J.int_opt "tmdbId" j;
    mr_imdb_id = J.non_empty (J.string_opt "imdbId" j);
    mr_in_cinemas = J.non_empty (J.string_opt "inCinemas" j);
    mr_digital_release = J.non_empty (J.string_opt "digitalRelease" j);
    mr_physical_release = J.non_empty (J.string_opt "physicalRelease" j);
    mr_size_on_disk = J.int64_def "sizeOnDisk" 0L j;
  }

(** [QueueResource] fields needed to know what is already downloading. *)
type queue_item = { qi_id : int; qi_movie_id : int option }

let queue_item_of_yojson j =
  { qi_id = J.int_def "id" 0 j; qi_movie_id = J.int_opt "movieId" j }

(** [HistoryResource] fields needed for the "grabbed recently" check. *)
type history_item = {
  hi_id : int;
  hi_movie_id : int option;
  hi_event_type : string option;
  hi_date : string option;
  hi_source_title : string option;
}

let history_item_of_yojson j =
  {
    hi_id = J.int_def "id" 0 j;
    hi_movie_id = J.int_opt "movieId" j;
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

(** [GET /api/v3/movie/{id}] *)
let movie ~base_url ~api_key id =
  let* r = Http.get ~base_url ~api_key (Printf.sprintf "/api/v3/movie/%d" id) in
  Lwt.return (map_result movie_resource_of_yojson r)

(** [GET /api/v3/movie?tmdbId=]  (lookup by TMDB id; used by the Seerr
    webhook to map a request onto a library movie) *)
let movies_by_tmdb_id ~base_url ~api_key tmdb_id =
  let* r =
    Http.get ~base_url ~api_key ~query:[ ("tmdbId", string_of_int tmdb_id) ] "/api/v3/movie"
  in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "movies" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map movie_resource_of_yojson l))

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

(** [GET /api/v3/release?movieId=] *)
let releases_for_movie ~base_url ~api_key movie_id =
  let* r =
    Http.get ~base_url ~api_key
      ~query:[ ("movieId", string_of_int movie_id) ]
      "/api/v3/release"
  in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "releases" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map release_resource_of_yojson l))

(** [POST /api/v3/release] — grab a release Radarr has already offered us.
    The release must still be in Radarr's remote movie cache, keyed by
    [indexerId ^ "_" ^ guid].

    Radarr echoes the posted resource back, but the grab has happened as soon
    as the status is 2xx, so the body is deliberately not parsed. *)
let grab ~base_url ~api_key body =
  Http.post_unit ~base_url ~api_key "/api/v3/release" body

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
          ("monitored", "true");
          ("sortKey", "movieMetadata.sortTitle");
          ("sortDirection", "ascending");
        ]
      path
  in
  Lwt.return (map_result (R.paging_of_yojson movie_resource_of_yojson) r)

(** [GET /api/v3/queue] *)
let queue ~base_url ~api_key ~page_size =
  let* r =
    Http.get ~base_url ~api_key
      ~query:
        [
          ("page", "1");
          ("pageSize", string_of_int page_size);
          ("includeUnknownMovieItems", "true");
        ]
      "/api/v3/queue"
  in
  Lwt.return (map_result (R.paging_of_yojson queue_item_of_yojson) r)

(** [GET /api/v3/history/since?date=] — plain array; event type filtered
    client-side. *)
let history_since ~base_url ~api_key ?event_type ~date () =
  let query =
    ("date", date) :: (match event_type with Some e -> [ ("eventType", e) ] | None -> [])
  in
  let* r = Http.get ~base_url ~api_key ~query "/api/v3/history/since" in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok j -> (
      match J.as_list "history records" j with
      | Error m -> Lwt.return (Error (Http.Json m))
      | Ok l -> ok (List.map history_item_of_yojson l))
