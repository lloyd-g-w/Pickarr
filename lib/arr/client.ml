(* App-agnostic facade over the Sonarr and Radarr APIs.  See client.mli. *)

module C = Pickarr_core.Config
module T = Pickarr_core.Types

type t = { inst : C.instance }
type error = Http.error

let error_to_string = Http.error_to_string
let create inst = { inst }
let instance t = t.inst
let app t = t.inst.C.inst_app

let ( let* ) = Lwt.bind
let base t = t.inst.C.inst_url
let key t = t.inst.C.inst_api_key

(* Optional extras (tags, profile names) must never fail the whole call. *)
let best_effort (f : unit -> ('a, error) result Lwt.t) : 'a option Lwt.t =
  let* r = f () in
  Lwt.return (match r with Ok v -> Some v | Error _ -> None)

let test_connection t =
  let base_url = base t and api_key = key t in
  let* r =
    match app t with
    | T.Sonarr -> Sonarr.system_status ~base_url ~api_key ()
    | T.Radarr -> Radarr.system_status ~base_url ~api_key ()
  in
  match r with
  | Error e -> Lwt.return (Error e)
  | Ok s ->
      Lwt.return
        (Ok (s.Resources.sys_app_name, s.Resources.sys_version, s.Resources.sys_instance_name))

(* ------------------------------------------------------------------ *)
(* Media                                                               *)
(* ------------------------------------------------------------------ *)

let fetch_media t id =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Sonarr -> (
      let* ep = Sonarr.episode ~base_url ~api_key id in
      match ep with
      | Error e -> Lwt.return (Error e)
      | Ok ep -> (
          (* GET /api/v3/episode/{id} includes the series, but not on every
             Sonarr version, so fetch it when it is missing. *)
          let* series =
            match ep.Sonarr.er_series with
            | Some s -> Lwt.return (Ok s)
            | None -> Sonarr.series ~base_url ~api_key ep.Sonarr.er_series_id
          in
          match series with
          | Error e -> Lwt.return (Error e)
          | Ok series ->
              let* tags = best_effort (fun () -> Sonarr.tags ~base_url ~api_key ()) in
              let* profile =
                match series.Sonarr.sr_quality_profile_id with
                | None -> Lwt.return None
                | Some pid ->
                    best_effort (fun () -> Sonarr.quality_profile ~base_url ~api_key pid)
              in
              let profile_name = Option.bind profile (fun p -> p.Resources.qp_name) in
              let tags = Option.value tags ~default:[] in
              Lwt.return (Ok (Mapping.media_of_episode ~tags ?profile_name ep series))))
  | T.Radarr -> (
      let* m = Radarr.movie ~base_url ~api_key id in
      match m with
      | Error e -> Lwt.return (Error e)
      | Ok m ->
          let* tags = best_effort (fun () -> Radarr.tags ~base_url ~api_key ()) in
          let* profile =
            match m.Radarr.mr_quality_profile_id with
            | None -> Lwt.return None
            | Some pid -> best_effort (fun () -> Radarr.quality_profile ~base_url ~api_key pid)
          in
          let profile_name = Option.bind profile (fun p -> p.Resources.qp_name) in
          let tags = Option.value tags ~default:[] in
          Lwt.return (Ok (Mapping.media_of_movie ~tags ?profile_name m)))

(* ------------------------------------------------------------------ *)
(* Seasons and whole series (Sonarr only)                              *)
(* ------------------------------------------------------------------ *)

type season_summary = {
  season_number : int;
  monitored : bool;  (** Any monitored episode in the season. *)
  total_episodes : int;
  missing_episode_ids : int list;  (** Monitored episodes without a file. *)
  existing_quality : string option;  (** Quality of the first file on disk. *)
}

let season_summary_to_yojson (s : season_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("season_number", `Int s.season_number);
      ("monitored", `Bool s.monitored);
      ("total_episodes", `Int s.total_episodes);
      ("missing_episodes", `Int (List.length s.missing_episode_ids));
      ("missing_episode_ids", `List (List.map (fun i -> `Int i) s.missing_episode_ids));
      ("existing_quality", T.opt_str s.existing_quality);
    ]

(* Sonarr numbers specials as season 0.  They are not what "give me the
   season" means, so they are dropped unless the series has nothing else. *)
let drop_specials (seasons : season_summary list) =
  match List.filter (fun s -> s.season_number > 0) seasons with
  | [] -> seasons
  | regular -> regular

let summarise_seasons (episodes : Sonarr.episode_resource list) : season_summary list =
  let numbers =
    List.sort_uniq compare
      (List.map (fun (e : Sonarr.episode_resource) -> e.Sonarr.er_season_number) episodes)
  in
  List.map
    (fun n ->
      let of_season =
        List.filter (fun (e : Sonarr.episode_resource) -> e.Sonarr.er_season_number = n) episodes
      in
      {
        season_number = n;
        monitored = List.exists (fun (e : Sonarr.episode_resource) -> e.Sonarr.er_monitored) of_season;
        total_episodes = List.length of_season;
        missing_episode_ids =
          List.filter_map
            (fun (e : Sonarr.episode_resource) ->
              if Mapping.is_missing e then Some e.Sonarr.er_id else None)
            of_season;
        existing_quality = Mapping.first_existing_quality of_season;
      })
    numbers
  |> drop_specials

(* Series title, tags and profile name, shared by the season/series helpers. *)
let series_context t series_id =
  let base_url = base t and api_key = key t in
  let* series = Sonarr.series ~base_url ~api_key series_id in
  match series with
  | Error e -> Lwt.return (Error e)
  | Ok series ->
      let* tags = best_effort (fun () -> Sonarr.tags ~base_url ~api_key ()) in
      let* profile =
        match series.Sonarr.sr_quality_profile_id with
        | None -> Lwt.return None
        | Some pid -> best_effort (fun () -> Sonarr.quality_profile ~base_url ~api_key pid)
      in
      Lwt.return
        (Ok
           ( series,
             Option.value tags ~default:[],
             Option.bind profile (fun p -> p.Resources.qp_name) ))

let sonarr_only ~(what : string) t =
  Http.Json
    (Printf.sprintf "%s is only available for Sonarr instances (%s is a %s instance)" what
       (instance t).C.inst_name
       (T.app_to_string (app t)))

let fetch_series_overview t series_id =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Radarr -> Lwt.return (Error (sonarr_only ~what:"A series overview" t))
  | T.Sonarr -> (
      let* ctx = series_context t series_id in
      match ctx with
      | Error e -> Lwt.return (Error e)
      | Ok (series, tags, profile_name) -> (
          let* episodes = Sonarr.episodes_of_series ~base_url ~api_key series_id in
          match episodes with
          | Error e -> Lwt.return (Error e)
          | Ok episodes ->
              let media =
                Mapping.media_of_series ~tags ?profile_name episodes series
              in
              Lwt.return (Ok (media, summarise_seasons episodes))))

let season_media t ~series_id ~season_number =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Radarr -> Lwt.return (Error (sonarr_only ~what:"A season selection" t))
  | T.Sonarr -> (
      let* ctx = series_context t series_id in
      match ctx with
      | Error e -> Lwt.return (Error e)
      | Ok (series, tags, profile_name) -> (
          let* episodes =
            Sonarr.episodes_of_series ~base_url ~api_key ~season:season_number series_id
          in
          match episodes with
          | Error e -> Lwt.return (Error e)
          | Ok episodes ->
              (* Sonarr ignores an unknown seasonNumber rather than failing,
                 so filter again to be sure we describe one season. *)
              let episodes =
                List.filter
                  (fun (e : Sonarr.episode_resource) ->
                    e.Sonarr.er_season_number = season_number)
                  episodes
              in
              Lwt.return
                (Ok (Mapping.media_of_season ~tags ?profile_name ~season_number episodes series))))

(* ------------------------------------------------------------------ *)
(* Releases                                                            *)
(* ------------------------------------------------------------------ *)

let series_id_of_media (media : T.media) =
  match List.assoc_opt "series_id" media.T.extra with Some (`Int id) -> Some id | _ -> None

let search_releases t (media : T.media) =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Sonarr when media.T.media_kind = "series" ->
      (* [GET /api/v3/release?seriesId=] without a seasonNumber does not
         search the series (docs/API_RESEARCH.md §2.1); a whole series is
         selected one season at a time instead. *)
      Lwt.return
        (Error
           (Http.Json
              "Sonarr cannot search a whole series at once; run the selection per season"))
  | T.Sonarr -> (
      let season_search =
        match (media.T.media_kind, series_id_of_media media, media.T.season_number) with
        | "season", Some sid, Some sn -> Some (sid, sn)
        | _ -> None
      in
      let* r =
        match season_search with
        | Some (series_id, season_number) ->
            Sonarr.releases_for_season ~base_url ~api_key ~series_id ~season_number
        | None -> Sonarr.releases_for_episode ~base_url ~api_key media.T.media_id
      in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok l -> Lwt.return (Ok (List.map Mapping.release_of_sonarr l)))
  | T.Radarr -> (
      let* r = Radarr.releases_for_movie ~base_url ~api_key media.T.media_id in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok l -> Lwt.return (Ok (List.map Mapping.release_of_radarr l)))

let grab t (media : T.media) (release : T.release) =
  let base_url = base t and api_key = key t in
  match Mapping.grab_identity release with
  | Error e -> Lwt.return (Error (Http.Json (Mapping.grab_error_message e)))
  | Ok (guid, indexer_id) -> (
      match app t with
      | T.Sonarr ->
          Sonarr.grab ~base_url ~api_key (Mapping.sonarr_grab_body ~guid ~indexer_id ~media)
      | T.Radarr ->
          Radarr.grab ~base_url ~api_key (Mapping.radarr_grab_body ~guid ~indexer_id ~media))

(* ------------------------------------------------------------------ *)
(* Automatic-mode helpers                                              *)
(* ------------------------------------------------------------------ *)

let wanted t ~kind ~page ~page_size =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Sonarr -> (
      let* r = Sonarr.wanted ~base_url ~api_key ~kind ~page ~page_size in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok paging ->
          let* tags = best_effort (fun () -> Sonarr.tags ~base_url ~api_key ()) in
          let tags = Option.value tags ~default:[] in
          let media =
            List.filter_map
              (fun (ep : Sonarr.episode_resource) ->
                match ep.Sonarr.er_series with
                | Some series -> Some (Mapping.media_of_episode ~tags ep series)
                | None -> None)
              paging.Resources.records
          in
          Lwt.return (Ok (media, paging.Resources.total_records)))
  | T.Radarr -> (
      let* r = Radarr.wanted ~base_url ~api_key ~kind ~page ~page_size in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok paging ->
          let* tags = best_effort (fun () -> Radarr.tags ~base_url ~api_key ()) in
          let tags = Option.value tags ~default:[] in
          let media = List.map (Mapping.media_of_movie ~tags) paging.Resources.records in
          Lwt.return (Ok (media, paging.Resources.total_records)))

let queue_page_size = 1000

let queue_media_ids t =
  let base_url = base t and api_key = key t in
  match app t with
  | T.Sonarr -> (
      let* r = Sonarr.queue ~base_url ~api_key ~page_size:queue_page_size in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok paging ->
          Lwt.return
            (Ok
               (List.filter_map
                  (fun (q : Sonarr.queue_item) -> q.Sonarr.qi_episode_id)
                  paging.Resources.records)))
  | T.Radarr -> (
      let* r = Radarr.queue ~base_url ~api_key ~page_size:queue_page_size in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok paging ->
          Lwt.return
            (Ok
               (List.filter_map
                  (fun (q : Radarr.queue_item) -> q.Radarr.qi_movie_id)
                  paging.Resources.records)))

(* Sonarr/Radarr accept an ISO-8601 UTC timestamp for history/since. *)
let iso8601_utc_of_unix (t : float) =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let is_grabbed = function
  | Some e -> String.lowercase_ascii e = "grabbed"
  | None -> false

(* The string form of the history event type is what /api/v3/history/since
   accepts (the int filter on /api/v3/history has unverified numbering).  If
   an instance rejects the parameter we retry without it and filter the
   response instead, which yields the same answer for a little more data. *)
let grabbed_event = "grabbed"

let retry_without_filter ~with_filter ~without_filter =
  let* r = with_filter () in
  match r with Error (Http.Http_status (400, _)) -> without_filter () | other -> Lwt.return other

let recently_grabbed_media_ids t ~since_hours =
  let base_url = base t and api_key = key t in
  let date = iso8601_utc_of_unix (Unix.gettimeofday () -. (since_hours *. 3600.)) in
  match app t with
  | T.Sonarr -> (
      let* r =
        retry_without_filter
          ~with_filter:(fun () ->
            Sonarr.history_since ~base_url ~api_key ~event_type:grabbed_event ~date ())
          ~without_filter:(fun () -> Sonarr.history_since ~base_url ~api_key ~date ())
      in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok items ->
          Lwt.return
            (Ok
               (List.filter_map
                  (fun (h : Sonarr.history_item) ->
                    if is_grabbed h.Sonarr.hi_event_type then h.Sonarr.hi_episode_id else None)
                  items
               |> List.sort_uniq compare)))
  | T.Radarr -> (
      let* r =
        retry_without_filter
          ~with_filter:(fun () ->
            Radarr.history_since ~base_url ~api_key ~event_type:grabbed_event ~date ())
          ~without_filter:(fun () -> Radarr.history_since ~base_url ~api_key ~date ())
      in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok items ->
          Lwt.return
            (Ok
               (List.filter_map
                  (fun (h : Radarr.history_item) ->
                    if is_grabbed h.Radarr.hi_event_type then h.Radarr.hi_movie_id else None)
                  items
               |> List.sort_uniq compare)))

let parse_webhook = Mapping.parse_webhook

(* ------------------------------------------------------------------ *)
(* External-id lookups (Seerr integration)                             *)
(* ------------------------------------------------------------------ *)

let ok x = Lwt.return (Ok x)

let series_id_by_tvdb_id t (tvdb_id : int) =
  match app t with
  | T.Radarr -> ok None
  | T.Sonarr -> (
      let* r = Sonarr.series_by_tvdb_id ~base_url:(base t) ~api_key:(key t) tvdb_id in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok [] -> ok None
      | Ok (series :: _) -> ok (Some series.Sonarr.sr_id))

let resolve_external t ~(tmdb_id : int option) ~(tvdb_id : int option)
    ~(seasons : int list) =
  let base_url = base t and api_key = key t in
  match (app t, tmdb_id, tvdb_id) with
  | T.Radarr, Some tmdb, _ -> (
      let* r = Radarr.movies_by_tmdb_id ~base_url ~api_key tmdb in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok movies ->
          ok
            (List.filter_map
               (fun (m : Radarr.movie_resource) ->
                 if m.Radarr.mr_monitored && not m.Radarr.mr_has_file then Some m.Radarr.mr_id
                 else None)
               movies))
  | T.Sonarr, _, Some tvdb -> (
      let* r = Sonarr.series_by_tvdb_id ~base_url ~api_key tvdb in
      match r with
      | Error e -> Lwt.return (Error e)
      | Ok [] -> ok []
      | Ok (series :: _) -> (
          let sid = series.Sonarr.sr_id in
          let fetch season = Sonarr.episodes_of_series ~base_url ~api_key ?season sid in
          let* eps =
            match seasons with
            | [] -> fetch None
            | seasons ->
                let* per_season = Lwt_list.map_s (fun n -> fetch (Some n)) seasons in
                Lwt.return
                  (List.fold_left
                     (fun acc r ->
                       match (acc, r) with
                       | Error e, _ -> Error e
                       | Ok l, Ok more -> Ok (l @ more)
                       | Ok _, Error e -> Error e)
                     (Ok []) per_season)
          in
          match eps with
          | Error e -> Lwt.return (Error e)
          | Ok eps ->
              ok
                (List.filter_map
                   (fun (e : Sonarr.episode_resource) ->
                     if e.Sonarr.er_monitored && (not e.Sonarr.er_has_file)
                        && e.Sonarr.er_season_number > 0
                     then Some e.Sonarr.er_id
                     else None)
                   eps)))
  | _ -> ok []

(* ------------------------------------------------------------------ *)
(* Seerr / Overseerr / Jellyseerr webhook                              *)
(* ------------------------------------------------------------------ *)

type seerr_event = {
  seerr_notification_type : string;
  seerr_media_type : string option;
  seerr_tmdb_id : int option;
  seerr_tvdb_id : int option;
  seerr_seasons : int list;
  seerr_subject : string option;
}

let parse_seerr_webhook (j : Yojson.Safe.t) : (seerr_event, string) result =
  let member k v = match v with `Assoc l -> List.assoc_opt k l | _ -> None in
  let str k v =
    match member k v with
    | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
    | _ -> None
  in
  (* Seerr substitutes template variables as strings ("11111"), but a custom
     payload may send real numbers. *)
  let int k v =
    match member k v with
    | Some (`Int i) -> Some i
    | Some (`Intlit s) | Some (`String s) -> int_of_string_opt (String.trim s)
    | Some (`Float f) -> Some (int_of_float f)
    | _ -> None
  in
  match str "notification_type" j with
  | None -> Error "missing notification_type"
  | Some nt ->
      let media = match member "media" j with Some (`Assoc _ as m) -> m | _ -> `Null in
      let seasons =
        match member "extra" j with
        | Some (`List extras) ->
            List.concat_map
              (fun e ->
                match (str "name" e, str "value" e) with
                | Some name, Some value
                  when String.lowercase_ascii name = "requested seasons" ->
                    String.split_on_char ',' value
                    |> List.filter_map (fun s -> int_of_string_opt (String.trim s))
                | _ -> [])
              extras
        | _ -> []
      in
      Ok
        {
          seerr_notification_type = nt;
          seerr_media_type = Option.map String.lowercase_ascii (str "media_type" media);
          seerr_tmdb_id = int "tmdbId" media;
          seerr_tvdb_id = int "tvdbId" media;
          seerr_seasons = seasons;
          seerr_subject = str "subject" j;
        }
