(* Typed client for the Seerr / Overseerr / Jellyseerr request API.

   Endpoints and field names are taken from the Seerr OpenAPI document and
   from the server entities (server/entity/MediaRequest.ts,
   server/entity/Media.ts, server/routes/request.ts).  The OpenAPI schema for
   MediaRequest is thinner than the payload the server actually sends — it
   omits [type], [seasons] and the [externalServiceId] fields — so every
   decoder here is lenient (see jsonutil.ml) and treats missing values as
   "unknown" rather than failing.

   Authentication is the admin API key in the X-Api-Key header, which is what
   {!Http} already sends. Approving or declining a request additionally needs
   the MANAGE_REQUESTS permission; an admin key has it. *)

module J = Jsonutil

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Enumerations                                                        *)
(* ------------------------------------------------------------------ *)

(** Request status ([MediaRequestStatus] in server/constants/media.ts). *)
let status_pending = 1
let status_approved = 2
let status_declined = 3
let status_failed = 4
let status_completed = 5

let request_status_to_string = function
  | 1 -> "pending"
  | 2 -> "approved"
  | 3 -> "declined"
  | 4 -> "failed"
  | 5 -> "completed"
  | n -> Printf.sprintf "unknown(%d)" n

(** Media availability ([MediaStatus] in server/constants/media.ts). *)
let media_unknown = 1
let media_pending = 2
let media_processing = 3
let media_partially_available = 4
let media_available = 5
let media_blocklisted = 6
let media_deleted = 7

let media_status_to_string = function
  | 1 -> "unknown"
  | 2 -> "pending"
  | 3 -> "processing"
  | 4 -> "partially_available"
  | 5 -> "available"
  | 6 -> "blocklisted"
  | 7 -> "deleted"
  | n -> Printf.sprintf "unknown(%d)" n

(** The [filter] query parameter of [GET /request]. The mapping to request and
    media statuses is implemented in server/routes/request.ts:
    - [`Pending]: request status PENDING;
    - [`Approved]: request status APPROVED, any availability;
    - [`Processing]: APPROVED and not yet available — the queue to fulfil;
    - [`Available]: completed requests;
    - [`Unavailable]: PENDING or APPROVED;
    - [`Failed]: request status FAILED. *)
type request_filter =
  [ `All | `Approved | `Available | `Failed | `Pending | `Processing | `Unavailable ]

let filter_to_string : request_filter -> string = function
  | `All -> "all"
  | `Approved -> "approved"
  | `Available -> "available"
  | `Failed -> "failed"
  | `Pending -> "pending"
  | `Processing -> "processing"
  | `Unavailable -> "unavailable"

let filter_of_string (s : string) : request_filter option =
  match String.lowercase_ascii (String.trim s) with
  | "all" -> Some `All
  | "approved" -> Some `Approved
  | "available" -> Some `Available
  | "failed" -> Some `Failed
  | "pending" -> Some `Pending
  | "processing" -> Some `Processing
  | "unavailable" -> Some `Unavailable
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Resources                                                           *)
(* ------------------------------------------------------------------ *)

type status = {
  sv_version : string;
  sv_commit_tag : string option;
  sv_update_available : bool;
}

let status_of_yojson j =
  {
    sv_version = J.string_def "version" "unknown" j;
    sv_commit_tag = J.non_empty (J.string_opt "commitTag" j);
    sv_update_available = J.bool_def "updateAvailable" false j;
  }

type user = { us_id : int; us_name : string option; us_email : string option }

let user_of_yojson j =
  {
    us_id = J.int_def "id" 0 j;
    (* displayName is a computed property of the User entity; older payloads
       and Plex/Jellyfin accounts fall back to the other name fields. *)
    us_name =
      J.non_empty
        (match J.string_opt "displayName" j with
        | Some n -> Some n
        | None -> (
            match J.string_opt "username" j with
            | Some n -> Some n
            | None -> (
                match J.string_opt "plexUsername" j with
                | Some n -> Some n
                | None -> J.string_opt "jellyfinUsername" j)));
    us_email = J.non_empty (J.string_opt "email" j);
  }

(** One season of a TV request ([SeasonRequest]). *)
type season_request = { sq_id : int; sq_season_number : int; sq_status : int }

let season_request_of_yojson j =
  {
    sq_id = J.int_def "id" 0 j;
    sq_season_number = J.int_def "seasonNumber" 0 j;
    sq_status = J.int_def "status" 0 j;
  }

(** The [Media] row a request points at. [mi_external_service_id] is the
    Radarr movie id / Sonarr series id, set once Seerr has pushed the item to
    the *arr; it is null until then. *)
type media_info = {
  mi_id : int;
  mi_media_type : string option;
  mi_tmdb_id : int option;
  mi_tvdb_id : int option;
  mi_imdb_id : string option;
  mi_status : int;
  mi_status4k : int;
  mi_external_service_id : int option;
  mi_external_service_id4k : int option;
  mi_service_id : int option;
}

let media_info_of_yojson j =
  {
    mi_id = J.int_def "id" 0 j;
    mi_media_type =
      Option.map String.lowercase_ascii (J.non_empty (J.string_opt "mediaType" j));
    mi_tmdb_id = J.int_opt "tmdbId" j;
    mi_tvdb_id = J.int_opt "tvdbId" j;
    mi_imdb_id = J.non_empty (J.string_opt "imdbId" j);
    mi_status = J.int_def "status" media_unknown j;
    mi_status4k = J.int_def "status4k" media_unknown j;
    mi_external_service_id = J.int_opt "externalServiceId" j;
    mi_external_service_id4k = J.int_opt "externalServiceId4k" j;
    mi_service_id = J.int_opt "serviceId" j;
  }

let empty_media_info =
  {
    mi_id = 0;
    mi_media_type = None;
    mi_tmdb_id = None;
    mi_tvdb_id = None;
    mi_imdb_id = None;
    mi_status = media_unknown;
    mi_status4k = media_unknown;
    mi_external_service_id = None;
    mi_external_service_id4k = None;
    mi_service_id = None;
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

let request_of_yojson j =
  let media =
    match J.member "media" j with
    | Some m -> media_info_of_yojson m
    | None -> empty_media_info
  in
  {
    rq_id = J.int_def "id" 0 j;
    rq_status = J.int_def "status" 0 j;
    (* MediaRequest.type is the authoritative field; fall back to the media
       row for payloads that omit it. *)
    rq_type =
      Option.map String.lowercase_ascii
        (match J.non_empty (J.string_opt "type" j) with
        | Some t -> Some t
        | None -> media.mi_media_type);
    rq_is4k = J.bool_def "is4k" false j;
    rq_seasons = List.map season_request_of_yojson (J.list_def "seasons" j);
    rq_media = media;
    rq_requested_by = Option.map user_of_yojson (J.member "requestedBy" j);
    rq_created_at = J.non_empty (J.string_opt "createdAt" j);
    rq_updated_at = J.non_empty (J.string_opt "updatedAt" j);
  }

(** The season numbers a TV request asks for, without specials and
    duplicates. An empty list means "the whole series". *)
let season_numbers (r : request) : int list =
  r.rq_seasons
  |> List.filter_map (fun s -> if s.sq_season_number > 0 then Some s.sq_season_number else None)
  |> List.sort_uniq compare

(** Availability of the copy this request is for (4K requests track a
    separate status). *)
let request_media_status (r : request) : int =
  if r.rq_is4k then r.rq_media.mi_status4k else r.rq_media.mi_status

(** The *arr id Seerr recorded for this request's copy, if it has pushed it
    already. Radarr: movie id. Sonarr: series id. *)
let request_external_service_id (r : request) : int option =
  if r.rq_is4k then r.rq_media.mi_external_service_id4k
  else r.rq_media.mi_external_service_id

type page_info = { pi_page : int; pi_pages : int; pi_page_size : int; pi_results : int }

let page_info_of_yojson j =
  {
    pi_page = J.int_def "page" 1 j;
    pi_pages = J.int_def "pages" 1 j;
    pi_page_size = J.int_def "pageSize" 0 j;
    pi_results = J.int_def "results" 0 j;
  }

type request_page = { rp_page_info : page_info; rp_results : request list }

let request_page_of_yojson j =
  {
    rp_page_info =
      (match J.member "pageInfo" j with
      | Some p -> page_info_of_yojson p
      | None -> { pi_page = 1; pi_pages = 1; pi_page_size = 0; pi_results = 0 });
    rp_results = List.map request_of_yojson (J.list_def "results" j);
  }

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

let counts_of_yojson j =
  {
    ct_total = J.int_def "total" 0 j;
    ct_movie = J.int_def "movie" 0 j;
    ct_tv = J.int_def "tv" 0 j;
    ct_pending = J.int_def "pending" 0 j;
    ct_approved = J.int_def "approved" 0 j;
    ct_declined = J.int_def "declined" 0 j;
    ct_processing = J.int_def "processing" 0 j;
    ct_available = J.int_def "available" 0 j;
  }

(** Display data for a request, from [GET /movie/{tmdbId}] or
    [GET /tv/{tmdbId}]. *)
type title = { ti_title : string; ti_year : int option }

let year_of_date = function
  | None -> None
  | Some d when String.length d >= 4 -> int_of_string_opt (String.sub d 0 4)
  | Some _ -> None

let movie_title_of_yojson j =
  {
    ti_title =
      (match J.non_empty (J.string_opt "title" j) with
      | Some t -> t
      | None -> J.string_def "originalTitle" "" j);
    ti_year = year_of_date (J.non_empty (J.string_opt "releaseDate" j));
  }

let tv_title_of_yojson j =
  {
    ti_title =
      (match J.non_empty (J.string_opt "name" j) with
      | Some t -> t
      | None -> J.string_def "originalName" "" j);
    ti_year = year_of_date (J.non_empty (J.string_opt "firstAirDate" j));
  }

(* ------------------------------------------------------------------ *)
(* Endpoints                                                           *)
(* ------------------------------------------------------------------ *)

let api_base = "/api/v1"
let path p = api_base ^ p
let map_result f = function Ok v -> Ok (f v) | Error e -> Error e

(** [GET /api/v1/status] — also used as the connection test. *)
let status ~base_url ~api_key () =
  let* r = Http.get ~base_url ~api_key (path "/status") in
  Lwt.return (map_result status_of_yojson r)

(** [GET /api/v1/request] — one page of requests, newest last when
    [sort_direction] is ["asc"]. *)
let requests ~base_url ~api_key ~(filter : request_filter) ?(take = 20) ?(skip = 0)
    ?(sort = "added") ?(sort_direction = "asc") ?(media_type : string option) () =
  let query =
    [
      ("filter", filter_to_string filter);
      ("take", string_of_int (max 1 take));
      ("skip", string_of_int (max 0 skip));
      ("sort", sort);
      ("sortDirection", sort_direction);
    ]
    @ match media_type with Some m -> [ ("mediaType", m) ] | None -> []
  in
  let* r = Http.get ~base_url ~api_key ~query (path "/request") in
  Lwt.return (map_result request_page_of_yojson r)

(** [GET /api/v1/request/{id}] *)
let request_by_id ~base_url ~api_key id =
  let* r = Http.get ~base_url ~api_key (path (Printf.sprintf "/request/%d" id)) in
  Lwt.return (map_result request_of_yojson r)

(** [GET /api/v1/request/count] *)
let request_count ~base_url ~api_key () =
  let* r = Http.get ~base_url ~api_key (path "/request/count") in
  Lwt.return (map_result counts_of_yojson r)

(** [POST /api/v1/request/{id}/approve] — needs MANAGE_REQUESTS. *)
let approve ~base_url ~api_key id =
  let* r =
    Http.post ~base_url ~api_key (path (Printf.sprintf "/request/%d/approve" id)) (`Assoc [])
  in
  Lwt.return (map_result request_of_yojson r)

(** [POST /api/v1/request/{id}/decline] — needs MANAGE_REQUESTS. *)
let decline ~base_url ~api_key id =
  let* r =
    Http.post ~base_url ~api_key (path (Printf.sprintf "/request/%d/decline" id)) (`Assoc [])
  in
  Lwt.return (map_result request_of_yojson r)

(** [GET /api/v1/movie/{tmdbId}] — title and release year. *)
let movie_title ~base_url ~api_key tmdb_id =
  let* r = Http.get ~base_url ~api_key (path (Printf.sprintf "/movie/%d" tmdb_id)) in
  Lwt.return (map_result movie_title_of_yojson r)

(** [GET /api/v1/tv/{tmdbId}] — name and first air year. *)
let tv_title ~base_url ~api_key tmdb_id =
  let* r = Http.get ~base_url ~api_key (path (Printf.sprintf "/tv/%d" tmdb_id)) in
  Lwt.return (map_result tv_title_of_yojson r)
