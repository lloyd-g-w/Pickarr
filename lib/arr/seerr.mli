(** Typed client for the Seerr / Overseerr / Jellyseerr request API
    ([/api/v1], authenticated with the admin API key in X-Api-Key).

    Decoders are lenient: unknown or missing fields fall back to defaults
    instead of raising, because the served payload carries more fields than
    the published OpenAPI schema. *)

(** {1 Enumerations} *)

val status_pending : int
val status_approved : int
val status_declined : int
val status_failed : int
val status_completed : int

val request_status_to_string : int -> string

val media_unknown : int
val media_pending : int
val media_processing : int
val media_partially_available : int
val media_available : int
val media_blocklisted : int
val media_deleted : int

val media_status_to_string : int -> string

(** The [filter] query parameter of [GET /request]. [`Processing] is
    "approved but not available yet", i.e. the queue Pickarr fulfils. *)
type request_filter =
  [ `All | `Approved | `Available | `Failed | `Pending | `Processing | `Unavailable ]

val filter_to_string : request_filter -> string
val filter_of_string : string -> request_filter option

(** {1 Resources} *)

type status = {
  sv_version : string;
  sv_commit_tag : string option;
  sv_update_available : bool;
}

type user = { us_id : int; us_name : string option; us_email : string option }
type season_request = { sq_id : int; sq_season_number : int; sq_status : int }

type media_info = {
  mi_id : int;
  mi_media_type : string option;  (** "movie" | "tv" *)
  mi_tmdb_id : int option;
  mi_tvdb_id : int option;
  mi_imdb_id : string option;
  mi_status : int;
  mi_status4k : int;
  mi_external_service_id : int option;
      (** Radarr movie id / Sonarr series id, once Seerr has pushed it. *)
  mi_external_service_id4k : int option;
  mi_service_id : int option;
}

type request = {
  rq_id : int;
  rq_status : int;
  rq_type : string option;  (** "movie" | "tv" *)
  rq_is4k : bool;
  rq_seasons : season_request list;
  rq_media : media_info;
  rq_requested_by : user option;
  rq_created_at : string option;
  rq_updated_at : string option;
}

type page_info = { pi_page : int; pi_pages : int; pi_page_size : int; pi_results : int }
type request_page = { rp_page_info : page_info; rp_results : request list }

type counts = {
  ct_total : int;
  ct_movie : int;
  ct_tv : int;
  ct_pending : int;
  ct_approved : int;
  ct_declined : int;
  ct_processing : int;
  ct_available : int;
}

type title = { ti_title : string; ti_year : int option }

(** {1 Decoders} (exposed for fixture tests) *)

val status_of_yojson : Yojson.Safe.t -> status
val request_of_yojson : Yojson.Safe.t -> request
val request_page_of_yojson : Yojson.Safe.t -> request_page
val counts_of_yojson : Yojson.Safe.t -> counts
val movie_title_of_yojson : Yojson.Safe.t -> title
val tv_title_of_yojson : Yojson.Safe.t -> title

(** {1 Derived values} *)

val season_numbers : request -> int list
(** Requested season numbers, specials (season 0) and duplicates removed. An
    empty list means the whole series. *)

val request_media_status : request -> int
(** Availability of the copy this request is for: [status4k] for a 4K
    request, [status] otherwise. *)

val request_external_service_id : request -> int option
(** The Radarr movie id / Sonarr series id Seerr recorded for this copy, if
    the item has already been pushed to the *arr. *)

(** {1 Endpoints} *)

val status : base_url:string -> api_key:string -> unit -> (status, Http.error) result Lwt.t
(** [GET /api/v1/status]; used as the connection test. *)

val requests :
  base_url:string ->
  api_key:string ->
  filter:request_filter ->
  ?take:int ->
  ?skip:int ->
  ?sort:string ->
  ?sort_direction:string ->
  ?media_type:string ->
  unit ->
  (request_page, Http.error) result Lwt.t
(** [GET /api/v1/request]. [sort] is ["added"] or ["modified"];
    [sort_direction] ["asc"] or ["desc"]; [media_type] ["movie"], ["tv"] or
    ["all"]. *)

val request_by_id : base_url:string -> api_key:string -> int -> (request, Http.error) result Lwt.t
val request_count : base_url:string -> api_key:string -> unit -> (counts, Http.error) result Lwt.t

val approve : base_url:string -> api_key:string -> int -> (request, Http.error) result Lwt.t
(** [POST /api/v1/request/{id}/approve]. Requires MANAGE_REQUESTS, which the
    admin API key has. *)

val decline : base_url:string -> api_key:string -> int -> (request, Http.error) result Lwt.t

val movie_title : base_url:string -> api_key:string -> int -> (title, Http.error) result Lwt.t
(** [GET /api/v1/movie/{tmdbId}]: requests carry no title of their own. *)

val tv_title : base_url:string -> api_key:string -> int -> (title, Http.error) result Lwt.t
