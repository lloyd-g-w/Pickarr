(** App-agnostic facade over the Sonarr and Radarr APIs.

    Every function returns a [result]; transport and decoding problems never
    escape as exceptions. *)

type t
type error = Http.error

val error_to_string : error -> string
val create : Pickarr_core.Config.instance -> t
val instance : t -> Pickarr_core.Config.instance
val app : t -> Pickarr_core.Types.app

val test_connection : t -> (string * string * string, error) result Lwt.t
(** [GET /api/v3/system/status] returning [(appName, version, instanceName)]. *)

val fetch_media : t -> int -> (Pickarr_core.Types.media, error) result Lwt.t
(** Sonarr: [id] is an episode id (the series is fetched too).  Radarr: [id]
    is a movie id.  Tag labels and the quality-profile name are best effort:
    a failure to fetch them leaves the corresponding fields empty rather than
    failing the call. *)

val search_releases :
  t -> Pickarr_core.Types.media -> (Pickarr_core.Types.release list, error) result Lwt.t
(** Interactive search: [GET /api/v3/release?episodeId=] (Sonarr),
    [?seriesId=&seasonNumber=] when [media.media_kind = "season"], or
    [?movieId=] (Radarr).  Nothing is filtered out: releases Sonarr/Radarr
    rejected come back with [arr_rejected = true] and their reasons.

    Note that this call runs a live indexer search and typically takes
    several seconds; it also primes the 30-minute release cache that
    {!grab} depends on. *)

val grab :
  t ->
  Pickarr_core.Types.media ->
  Pickarr_core.Types.release ->
  (unit, error) result Lwt.t
(** [POST /api/v3/release] with the release's [guid] and [indexerId], letting
    Sonarr/Radarr fetch the torrent/NZB and hand it to the download client.
    The release must have been returned by a {!search_releases} call made
    within the last 30 minutes, otherwise Sonarr/Radarr answer 404
    ("Couldn't find requested release in cache"). *)

val wanted :
  t ->
  kind:[ `Missing | `Cutoff ] ->
  page:int ->
  page_size:int ->
  (Pickarr_core.Types.media list * int, error) result Lwt.t
(** Monitored items that have no file ([`Missing]) or have not met their
    cutoff ([`Cutoff]), plus the total record count for paging. *)

val queue_media_ids : t -> (int list, error) result Lwt.t
(** Episode/movie ids that already have something in the download queue. *)

val recently_grabbed_media_ids : t -> since_hours:float -> (int list, error) result Lwt.t
(** Episode/movie ids with a [grabbed] history event in the last
    [since_hours].  Used by automatic mode to avoid double grabs. *)

val parse_webhook :
  Pickarr_core.Types.app -> Yojson.Safe.t -> (string * int list, string) result
(** Parse an incoming Sonarr/Radarr webhook body into its event type
    (["Grab"], ["Download"], ["Test"], ["SeriesAdd"], ["MovieAdded"], ...)
    and the affected media ids. *)

val resolve_external :
  t -> tmdb_id:int option -> tvdb_id:int option -> seasons:int list -> (int list, error) result Lwt.t
(** Map external ids onto this instance's media ids.  Radarr: the monitored,
    file-less movie with that TMDB id ([GET /api/v3/movie?tmdbId=]).  Sonarr:
    the monitored, missing episodes of the series with that TVDB id
    ([GET /api/v3/series?tvdbId=] then [GET /api/v3/episode?seriesId=]),
    restricted to [seasons] when non-empty.  Specials (season 0) are skipped.
    Returns [[]] when nothing matches. *)

(** A parsed Seerr / Overseerr / Jellyseerr webhook notification. *)
type seerr_event = {
  seerr_notification_type : string;  (** e.g. MEDIA_APPROVED, MEDIA_AUTO_APPROVED, TEST_NOTIFICATION *)
  seerr_media_type : string option;  (** "movie" | "tv" *)
  seerr_tmdb_id : int option;
  seerr_tvdb_id : int option;
  seerr_seasons : int list;  (** from the "Requested Seasons" extra *)
  seerr_subject : string option;
}

val parse_seerr_webhook : Yojson.Safe.t -> (seerr_event, string) result
(** Parse the default Seerr webhook JSON payload
    ({notification_type, subject, media:{media_type,tmdbId,tvdbId,...}, extra:[{name,value}]}).
    Numeric ids are accepted as strings (Seerr's template output) or numbers. *)
