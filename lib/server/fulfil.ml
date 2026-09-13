(* Turning an external request (Seerr) into Pickarr selections, shared by the
   two paths that fulfil one:

     - the Seerr request poller           (lib/server/seerr_sync.ml)
     - the Seerr webhook                  (lib/server/automatic.ml)

   Both must behave the same, in particular a TV request must be satisfied by
   one season pack per requested season (falling back to individual episodes)
   rather than one grab per episode.

   This module must not depend on [Automatic]: [Automatic] depends on it. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* What a request maps to on one instance                              *)
(* ------------------------------------------------------------------ *)

(** The unit of work a request became on one instance. *)
type target =
  | Movies of int list  (** Radarr movie ids, monitored and without a file. *)
  | Series of { series_id : int; seasons : int list }
      (** Sonarr: season-by-season selection.  [seasons] is never empty; it
          holds the requested seasons that still have missing episodes. *)
  | Episodes of int list
      (** Sonarr fallback: episode ids, used when the series cannot be
          resolved by TheTVDB id (so {!Selection.run_series} does not
          apply). *)
  | Nothing
      (** Nothing to do yet.  Callers treat this as "retry later": Seerr
          pushes to Sonarr/Radarr asynchronously, so an item approved moments
          ago is not in the library yet. *)

(** How many units of work [target] represents, used for logging and for the
    [items] field of a fulfilment summary. *)
let target_items = function
  | Movies ids -> List.length ids
  | Series { seasons; _ } -> List.length seasons
  | Episodes ids -> List.length ids
  | Nothing -> 0

let target_to_string = function
  | Movies ids -> Printf.sprintf "%d movie(s)" (List.length ids)
  | Series { series_id; seasons } ->
      Printf.sprintf "series %d, season(s) %s" series_id
        (String.concat ", " (List.map string_of_int seasons))
  | Episodes ids -> Printf.sprintf "%d episode(s)" (List.length ids)
  | Nothing -> "nothing"

(* ------------------------------------------------------------------ *)
(* Resolution                                                          *)
(* ------------------------------------------------------------------ *)

(* Seasons of [summaries] that still miss monitored episodes, restricted to
   [requested] when that is non-empty.  Pure. *)
let seasons_with_missing ~(requested : int list)
    (summaries : Client.season_summary list) : int list =
  summaries
  |> List.filter (fun (s : Client.season_summary) ->
         s.missing_episode_ids <> []
         && (requested = [] || List.mem s.season_number requested))
  |> List.map (fun (s : Client.season_summary) -> s.season_number)

(* Sonarr: series id by TheTVDB id, then the seasons that need work. *)
let resolve_sonarr (state : App_state.t) (inst : Config.instance) ~(log : string)
    ~(tvdb_id : int option) ~(seasons : int list) : target Lwt.t =
  let client = App_state.client state inst in
  let fallback_episodes () =
    let* ids =
      Client.resolve_external client ~tmdb_id:None ~tvdb_id ~seasons
    in
    match ids with
    | Error e ->
        Log_buffer.warnf "%s: %s: episode lookup failed: %s" log inst.inst_name
          (Client.error_to_string e);
        Lwt.return Nothing
    | Ok [] -> Lwt.return Nothing
    | Ok ids -> Lwt.return (Episodes ids)
  in
  match tvdb_id with
  | None -> fallback_episodes ()
  | Some tvdb -> (
      let* found = Client.series_id_by_tvdb_id client tvdb in
      match found with
      | Error e ->
          Log_buffer.warnf "%s: %s: series lookup failed (%s); trying episodes"
            log inst.inst_name (Client.error_to_string e);
          fallback_episodes ()
      | Ok None ->
          (* Sonarr has not added the series yet. *)
          Lwt.return Nothing
      | Ok (Some series_id) -> (
          let* overview = Client.fetch_series_overview client series_id in
          match overview with
          | Error e ->
              Log_buffer.warnf
                "%s: %s: could not read the seasons of series %d (%s); trying episodes"
                log inst.inst_name series_id (Client.error_to_string e);
              fallback_episodes ()
          | Ok (_series, summaries) -> (
              match seasons_with_missing ~requested:seasons summaries with
              | [] -> Lwt.return Nothing
              | wanted -> Lwt.return (Series { series_id; seasons = wanted }))))

(* Radarr: the monitored, file-less movie for the TMDB id.  When Radarr does
   not match the TMDB id but Seerr recorded the movie id it pushed
   ([externalServiceId]), that id is used instead — still only if the movie is
   monitored and has no file. *)
let resolve_radarr (state : App_state.t) (inst : Config.instance) ~(log : string)
    ~(tmdb_id : int option) ~(external_service_id : int option) : target Lwt.t =
  let client = App_state.client state inst in
  let* resolved =
    Client.resolve_external client ~tmdb_id ~tvdb_id:None ~seasons:[]
  in
  match resolved with
  | Error e ->
      Log_buffer.warnf "%s: %s: lookup failed: %s" log inst.inst_name
        (Client.error_to_string e);
      Lwt.return Nothing
  | Ok (_ :: _ as ids) -> Lwt.return (Movies ids)
  | Ok [] -> (
      match external_service_id with
      | None -> Lwt.return Nothing
      | Some movie_id -> (
          let* media = Client.fetch_media client movie_id in
          match media with
          | Ok m when m.monitored && not m.has_file ->
              Log_buffer.infof
                "%s: %s: using the movie id %d Seerr recorded (Radarr did not match the TMDB id)"
                log inst.inst_name movie_id;
              Lwt.return (Movies [ movie_id ])
          | Ok _ | Error _ -> Lwt.return Nothing))

(** Work out what a request means on one instance.

    [seasons] are the requested season numbers (empty = the whole series).
    [external_service_id] is Seerr's [externalServiceId], used as a last
    resort for movies.  [log] prefixes the log lines ("seerr"). *)
let resolve (state : App_state.t) (inst : Config.instance) ?(log = "seerr")
    ~(tmdb_id : int option) ~(tvdb_id : int option) ~(seasons : int list)
    ?(external_service_id : int option) () : target Lwt.t =
  match inst.inst_app with
  | Types.Sonarr -> resolve_sonarr state inst ~log ~tvdb_id ~seasons
  | Types.Radarr -> resolve_radarr state inst ~log ~tmdb_id ~external_service_id

(* ------------------------------------------------------------------ *)
(* Running the selections                                              *)
(* ------------------------------------------------------------------ *)

(** Everything one [target] produced. *)
type outcome = {
  results : Types.selection_result list;
      (** Every selection that ran, newest last.  Used for history summaries
          and for counting grabs. *)
  seasons : Selection.season_outcome list;
      (** Per-season detail for a [Series] target; [] otherwise. *)
  series : Types.media option;  (** The series a [Series] target described. *)
  error : string option;  (** Set when the target could not be run at all. *)
}

let empty_outcome = { results = []; seasons = []; series = None; error = None }

let grabbed_count (o : outcome) =
  List.length (List.filter (fun (r : Types.selection_result) -> r.grabbed) o.results)

let selected_count (o : outcome) =
  List.length
    (List.filter (fun (r : Types.selection_result) -> r.selected <> None) o.results)

(* One selection for one media id, with the attempt recorded and the outcome
   logged.  Exceptions never escape: a failing item must not abort the rest. *)
let select_one (state : App_state.t) (inst : Config.instance) ~(log : string)
    ~grab_allowed ~(media_id : int) (opts : Selection.options) :
    Types.selection_result option Lwt.t =
  App_state.record_attempt state.App_state.scheduler inst.Config.inst_id media_id;
  Lwt.catch
    (fun () ->
      let* result = Selection.run ~grab_allowed state inst ~media_id opts in
      match result with
      | Ok r ->
          (match r.selected with
          | None ->
              Log_buffer.infof "%s: %s: no usable release for %s" log inst.inst_name
                (Store.media_label r.media)
          | Some s ->
              Log_buffer.infof "%s: %s: %s %s for %s" log inst.inst_name
                (if r.grabbed then "grabbed" else "would grab")
                s.scored.title (Store.media_label r.media));
          Lwt.return (Some r)
      | Error e ->
          Log_buffer.warnf "%s: %s: %s" log inst.inst_name (Selection.error_to_string e);
          Lwt.return None)
    (fun exn ->
      Log_buffer.errorf "%s: selection failed: %s" log (Printexc.to_string exn);
      Lwt.return None)

(* Log what a whole-series run did, season by season. *)
let log_season_outcome ~(log : string) (inst : Config.instance)
    (o : Selection.season_outcome) =
  match o.outcome with
  | `Skipped why ->
      Log_buffer.infof "%s: %s: season %d skipped (%s)" log inst.Config.inst_name
        o.season_number why
  | `Pack r ->
      Log_buffer.infof "%s: %s: season %d pack: %s" log inst.Config.inst_name
        o.season_number
        (match r.selected with
        | None -> "no usable release"
        | Some s -> (if r.grabbed then "grabbed " else "would grab ") ^ s.scored.title)
  | `Episodes rs ->
      let grabbed =
        List.length (List.filter (fun (r : Types.selection_result) -> r.grabbed) rs)
      in
      Log_buffer.infof "%s: %s: season %d as %d episode(s), %d grabbed" log
        inst.Config.inst_name o.season_number (List.length rs) grabbed

(** Run a [target] on one instance.  [grab_allowed] gates the actual grab the
    same way automatic mode does. *)
let run (state : App_state.t) (inst : Config.instance) ?(log = "seerr")
    ~grab_allowed (target : target) (opts : Selection.options) : outcome Lwt.t =
  let one media_id = select_one state inst ~log ~grab_allowed ~media_id opts in
  let several ids =
    let* results = Lwt_list.map_s one ids in
    Lwt.return { empty_outcome with results = List.filter_map (fun r -> r) results }
  in
  match target with
  | Nothing -> Lwt.return empty_outcome
  | Movies ids -> several ids
  | Episodes ids -> several ids
  | Series { series_id; seasons } -> (
      (* The season media id is the series id, so record the attempt once. *)
      App_state.record_attempt state.App_state.scheduler inst.Config.inst_id series_id;
      let* r =
        Lwt.catch
          (fun () ->
            Selection.run_series ~grab_allowed state inst ~series_id ~seasons opts)
          (fun exn -> Lwt.return (Error (Selection.Arr_error (Printexc.to_string exn))))
      in
      match r with
      | Error e ->
          let msg = Selection.error_to_string e in
          Log_buffer.warnf "%s: %s: %s" log inst.inst_name msg;
          Lwt.return { empty_outcome with error = Some msg }
      | Ok series_result ->
          List.iter (log_season_outcome ~log inst) series_result.seasons;
          Lwt.return
            {
              results =
                List.concat_map
                  (fun (o : Selection.season_outcome) ->
                    match o.outcome with
                    | `Pack r -> [ r ]
                    | `Episodes rs -> rs
                    | `Skipped _ -> [])
                  series_result.seasons;
              seasons = series_result.seasons;
              series = Some series_result.series;
              error = None;
            })

(* ------------------------------------------------------------------ *)
(* Compact JSON for the Requests tab                                   *)
(* ------------------------------------------------------------------ *)

let opt_str = function None -> `Null | Some s -> `String s

(* One line per season: what happened and to which release. *)
let season_to_compact (o : Selection.season_outcome) : Yojson.Safe.t =
  let common kind extra =
    `Assoc
      ([
         ("season_number", `Int o.season_number);
         ("missing", `Int o.missing);
         ("total", `Int o.total);
         ("kind", `String kind);
       ]
      @ extra)
  in
  match o.outcome with
  | `Skipped why -> common "skipped" [ ("reason", `String why) ]
  | `Pack r ->
      common "pack"
        [
          ("selected", opt_str (Option.map (fun (s : Types.scored_release) -> s.scored.title) r.selected));
          ("grabbed", `Bool r.grabbed);
          ("grab_error", opt_str r.grab_error);
          ("reason", `String r.reason);
        ]
  | `Episodes rs ->
      common "episodes"
        [
          ("episodes", `Int (List.length rs));
          ( "grabbed",
            `Int (List.length (List.filter (fun (r : Types.selection_result) -> r.grabbed) rs)) );
        ]

(** [] when the target was not a whole-series run, so callers can omit the
    field for movies. *)
let seasons_to_compact (o : outcome) : Yojson.Safe.t list =
  List.map season_to_compact o.seasons
