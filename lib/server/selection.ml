(* One place where a selection is actually performed, shared by the manual
   HTTP routes and by automatic mode:

     fetch media -> search releases -> pipeline (filter, score, AI) ->
     optionally grab -> append history. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Pipeline = Pickarr_core.Pipeline
module Client = Pickarr_arr.Client
module Llm = Pickarr_llm.Client

type options = {
  grab : bool;  (** Actually tell Sonarr/Radarr to grab the winner. *)
  instruction : string option;
      (** Temporary natural-language instruction for this request only; never
          persisted. *)
  use_ai : bool option;  (** Overrides [config.llm.llm_enabled] when set. *)
}

let default_options = { grab = false; instruction = None; use_ai = None }

type error =
  | Bad_request of string
  | Instance_not_found of string
  | Media_not_found of string
  | Release_not_found of string
      (** A grab-by-id request named a release the current search does not
          offer (the indexers no longer return it, or the id is wrong). *)
  | Release_rejected of string
      (** The named release exists but a hard rule or Sonarr/Radarr rejected
          it, so Pickarr must not grab it. *)
  | Arr_error of string
      (** The *arr instance could not be reached or returned an error. *)

let error_to_string = function
  | Bad_request m -> m
  | Instance_not_found id -> Printf.sprintf "unknown instance \"%s\"" id
  | Media_not_found m -> m
  | Release_not_found m -> m
  | Release_rejected m -> m
  | Arr_error m -> m

let bool_of_json_value = function
  | `Bool b -> Some b
  | `String s -> (
      match String.lowercase_ascii s with
      | "1" | "true" | "yes" | "on" -> Some true
      | "0" | "false" | "no" | "off" -> Some false
      | _ -> None)
  | `Int 1 -> Some true
  | `Int 0 -> Some false
  | _ -> None

(** Parse the request body of a selection request. Accepts
    [{"grab":bool,"instruction":string,"use_ai":bool}] with every field
    optional, an empty body, and a [?grab=true] query override. Pure, so the
    parsing rules can be unit tested. *)
let options_of_json ?(grab_query : string option) (body : Yojson.Safe.t) :
    (options, string) result =
  let from_query =
    match grab_query with
    | None -> Ok None
    | Some s -> (
        match bool_of_json_value (`String s) with
        | Some b -> Ok (Some b)
        | None -> Error (Printf.sprintf "invalid grab query value \"%s\"" s))
  in
  match from_query with
  | Error e -> Error e
  | Ok query_grab -> (
      let base = { default_options with grab = Option.value query_grab ~default:false } in
      match body with
      | `Null -> Ok base
      | `Assoc fields ->
          let result = ref (Ok base) in
          let set f = match !result with Ok o -> result := Ok (f o) | Error _ -> () in
          let fail e = match !result with Ok _ -> result := Error e | Error _ -> () in
          List.iter
            (fun (key, value) ->
              match (key, value) with
              | "grab", v -> (
                  match bool_of_json_value v with
                  | Some b -> set (fun o -> { o with grab = b })
                  | None -> fail "\"grab\" must be a boolean")
              | "use_ai", `Null -> ()
              | "use_ai", v -> (
                  match bool_of_json_value v with
                  | Some b -> set (fun o -> { o with use_ai = Some b })
                  | None -> fail "\"use_ai\" must be a boolean")
              | "instruction", `Null -> ()
              | "instruction", `String s ->
                  let s = String.trim s in
                  if s <> "" then set (fun o -> { o with instruction = Some s })
              | "instruction", _ -> fail "\"instruction\" must be a string"
              | ("media_id" | "mediaId"), _ -> ()
              | _ -> ())
            fields;
          !result
      | _ -> Error "request body must be a JSON object")

(** Parse the body of a grab-by-id request, [{"release_id":"..."}]. The id is
    the [id] field of a release from a previous selection response. Pure, so
    the rules can be unit tested. *)
let release_id_of_json (body : Yojson.Safe.t) : (string, string) result =
  let missing = "\"release_id\" must be a non-empty string" in
  match body with
  | `Assoc fields -> (
      match List.assoc_opt "release_id" fields with
      | Some (`String s) when String.trim s <> "" -> Ok (String.trim s)
      | Some (`String _) | None -> Error missing
      | Some _ -> Error missing)
  | _ -> Error missing

(** The LLM callback handed to the pipeline. Errors are flattened to strings
    so the pipeline can fall back to deterministic scoring. *)
let llm_fn (cfg : Config.t) : Pipeline.llm_fn =
 fun ~system ~user ->
  Lwt.map
    (function
      | Ok json -> Ok json
      | Error e -> Error (Llm.error_to_string e))
    (Llm.chat_json cfg.llm ~system ~user)

let ( let* ) = Lwt.bind

let arr_error_of_http ~(msg : string) (e : Pickarr_arr.Http.error) : error =
  match e with
  | Pickarr_arr.Http.Http_status (404, _) -> Media_not_found msg
  | Pickarr_arr.Http.Http_status _ | Pickarr_arr.Http.Connection _
  | Pickarr_arr.Http.Json _ ->
      Arr_error msg

(** Run the pipeline for a media item that has already been loaded: search,
    filter/score/AI, optionally grab, append history.

    [grab_allowed] lets automatic mode veto the grab after seeing the result
    (for example when the LLM confidence is too low). *)
let run_media ?(grab_allowed = fun (_ : Types.selection_result) -> true)
    (state : App_state.t) (inst : Config.instance) (media : Types.media) (opts : options) :
    (Types.selection_result, error) result Lwt.t =
  let cfg = App_state.config state in
  let client = App_state.client state inst in
  let* releases = Client.search_releases client media in
  match releases with
  | Error e ->
      Lwt.return
        (Error
           (Arr_error
              (Printf.sprintf "%s: release search failed for %s: %s" inst.inst_name
                 (Store.media_label media) (Client.error_to_string e))))
  | Ok releases ->
      Log_buffer.infof "%s: %d candidate release(s) for %s" inst.inst_name
        (List.length releases) (Store.media_label media);
      let* result =
        Pipeline.run ~config:cfg ~instance:(Some inst) ~media ~releases
          ?instruction:opts.instruction ~llm:(llm_fn cfg) ?use_ai:opts.use_ai ()
      in
      let* result =
        match (opts.grab, result.selected) with
        | false, _ | _, None -> Lwt.return result
        | true, Some selected ->
            if not (grab_allowed result) then Lwt.return result
            else
              let* grabbed = Client.grab client media selected.scored in
              (match grabbed with
              | Ok () ->
                  Log_buffer.infof "%s: grabbed %s for %s" inst.inst_name
                    selected.scored.title (Store.media_label media);
                  Lwt.return { result with grabbed = true; grab_error = None }
              | Error e ->
                  let msg = Client.error_to_string e in
                  Log_buffer.errorf "%s: grab failed for %s: %s" inst.inst_name
                    selected.scored.title msg;
                  Lwt.return { result with grabbed = false; grab_error = Some msg })
      in
      let* () =
        Store.append_history state.store
          (Store.history_entry_of_result ~instance_id:inst.inst_id result)
      in
      Lwt.return (Ok result)

(** Load one media item (Sonarr episode / Radarr movie) and run the pipeline
    for it. *)
let run ?grab_allowed (state : App_state.t) (inst : Config.instance) ~(media_id : int)
    (opts : options) : (Types.selection_result, error) result Lwt.t =
  let client = App_state.client state inst in
  let* media = Client.fetch_media client media_id in
  match media with
  | Error e ->
      let msg =
        Printf.sprintf "%s: could not load media %d: %s" inst.inst_name media_id
          (Client.error_to_string e)
      in
      Lwt.return (Error (arr_error_of_http ~msg e))
  | Ok media -> run_media ?grab_allowed state inst media opts

(* ------------------------------------------------------------------ *)
(* Grab one specific release                                           *)
(* ------------------------------------------------------------------ *)

(** Grab the candidate with id [release_id] instead of the pipeline's winner.

    Sonarr/Radarr only accept a grab for a release from the most recent
    search (their remote cache is keyed on [indexerId_guid] and expires after
    30 minutes, see docs/API_RESEARCH.md "3.4"), so this re-runs the search
    and then grabs, rather than trusting ids from an older response.

    Only releases that survive the hard rules can be grabbed: the deterministic
    rejections outrank any manual pick, exactly as in the automatic path. *)
let grab_release (state : App_state.t) (inst : Config.instance) ~(media_id : int)
    ~(release_id : string) : (Types.selection_result, error) result Lwt.t =
  let cfg = App_state.config state in
  let client = App_state.client state inst in
  let ( let* ) = Lwt.bind in
  let* media = Client.fetch_media client media_id in
  match media with
  | Error e ->
      let msg =
        Printf.sprintf "%s: could not load media %d: %s" inst.inst_name media_id
          (Client.error_to_string e)
      in
      Lwt.return
        (Error
           (match e with
           | Pickarr_arr.Http.Http_status (404, _) -> Media_not_found msg
           | Pickarr_arr.Http.Http_status _ | Pickarr_arr.Http.Connection _
           | Pickarr_arr.Http.Json _ ->
               Arr_error msg))
  | Ok media -> (
      let* releases = Client.search_releases client media in
      match releases with
      | Error e ->
          Lwt.return
            (Error
               (Arr_error
                  (Printf.sprintf "%s: release search failed for %s: %s" inst.inst_name
                     (Store.media_label media) (Client.error_to_string e))))
      | Ok releases -> (
          (* The pipeline gives the same candidate/rejected split the UI
             showed, so the manual pick is validated against it. *)
          let* result =
            Pipeline.run ~config:cfg ~instance:(Some inst) ~media ~releases ~use_ai:false ()
          in
          let matches (s : Types.scored_release) = s.Types.scored.Types.id = release_id in
          match List.find_opt matches result.Types.candidates with
          | None -> (
              let rejected =
                List.find_opt
                  (fun (r : Types.rejected_release) ->
                    r.Types.release.Types.id = release_id)
                  result.Types.rejected
              in
              match rejected with
              | Some r ->
                  let reasons =
                    String.concat "; "
                      (List.map (fun (x : Types.rejection) -> x.Types.message) r.Types.reasons)
                  in
                  Lwt.return
                    (Error
                       (Release_rejected
                          (Printf.sprintf "%s cannot be grabbed: %s" r.Types.release.Types.title
                             reasons)))
              | None ->
                  Lwt.return
                    (Error
                       (Release_not_found
                          (Printf.sprintf
                             "%s: no release with id \"%s\" is currently offered for %s \
                              (search again and retry)"
                             inst.inst_name release_id (Store.media_label media)))))
          | Some chosen ->
              let* grabbed = Client.grab client media chosen.Types.scored in
              let result =
                {
                  result with
                  Types.selected = Some chosen;
                  reason =
                    Printf.sprintf "%s was grabbed because you picked it directly"
                      chosen.Types.scored.Types.title;
                }
              in
              let result =
                match grabbed with
                | Ok () ->
                    Log_buffer.infof "%s: grabbed %s for %s (picked by hand)" inst.inst_name
                      chosen.Types.scored.Types.title (Store.media_label media);
                    { result with Types.grabbed = true; grab_error = None }
                | Error e ->
                    let msg = Client.error_to_string e in
                    Log_buffer.errorf "%s: grab failed for %s: %s" inst.inst_name
                      chosen.Types.scored.Types.title msg;
                    { result with Types.grabbed = false; grab_error = Some msg }
              in
              let* () =
                Store.append_history state.store
                  (Store.history_entry_of_result ~instance_id:inst.inst_id result)
              in
              Lwt.return (Ok result)))

(** Resolve an instance by id and grab one specific release. *)
let grab_release_on_instance_id (state : App_state.t) ~(instance_id : string)
    ~(media_id : int) ~(release_id : string) =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> grab_release state inst ~media_id ~release_id

(** Resolve an instance by id and run a selection. *)
let run_on_instance_id (state : App_state.t) ~(instance_id : string) ~(media_id : int)
    (opts : options) =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> run state inst ~media_id opts

(** Resolve the default instance for an app and run a selection. *)
let run_on_default (state : App_state.t) ~(app : Types.app) ~(media_id : int)
    (opts : options) =
  match App_state.default_instance state app with
  | None -> Lwt.return (Error (Instance_not_found (Types.app_to_string app)))
  | Some inst -> run state inst ~media_id opts

(* ------------------------------------------------------------------ *)
(* Seasons and whole series (Sonarr)                                   *)
(* ------------------------------------------------------------------ *)

(** What to do with one season, decided from the configured policy and how
    much of the season is missing.  Pure, so the policy can be unit tested. *)
type season_plan = Plan_pack | Plan_episodes | Plan_skip of string

let season_plan (s : Config.seasons) ~(missing : int) ~(total : int) : season_plan =
  if total <= 0 then Plan_skip "the season has no episodes"
  else if missing <= 0 then Plan_skip "nothing missing"
  else if not s.prefer_packs then Plan_episodes
  else
    let fraction = float_of_int missing /. float_of_int total in
    if fraction >= s.min_missing_fraction then Plan_pack else Plan_episodes

let season_plan_to_string = function
  | Plan_pack -> "season pack"
  | Plan_episodes -> "per episode"
  | Plan_skip why -> "skipped: " ^ why

(** What happened for one season of a whole-series selection. *)
type season_outcome = {
  season_number : int;
  missing : int;
  total : int;
  outcome :
    [ `Pack of Types.selection_result
    | `Episodes of Types.selection_result list
    | `Skipped of string ];
}

type series_result = { series : Types.media; seasons : season_outcome list }

let outcome_to_yojson = function
  | `Pack r ->
      `Assoc
        [ ("kind", `String "pack"); ("selection", Types.selection_result_to_yojson r) ]
  | `Episodes rs ->
      `Assoc
        [
          ("kind", `String "episodes");
          ("selections", `List (List.map Types.selection_result_to_yojson rs));
        ]
  | `Skipped why -> `Assoc [ ("kind", `String "skipped"); ("reason", `String why) ]

let season_outcome_to_yojson (o : season_outcome) : Yojson.Safe.t =
  `Assoc
    [
      ("season_number", `Int o.season_number);
      ("missing", `Int o.missing);
      ("total", `Int o.total);
      ("outcome", outcome_to_yojson o.outcome);
    ]

(* Whether a season ended up with something grabbed (or grabbable). *)
let outcome_results = function
  | `Pack r -> [ r ]
  | `Episodes rs -> rs
  | `Skipped _ -> []

let series_result_to_yojson (r : series_result) : Yojson.Safe.t =
  let results = List.concat_map (fun o -> outcome_results o.outcome) r.seasons in
  `Assoc
    [
      ("series", Types.media_to_yojson r.series);
      ("seasons", `List (List.map season_outcome_to_yojson r.seasons));
      ( "summary",
        `Assoc
          [
            ("seasons", `Int (List.length r.seasons));
            ("selections", `Int (List.length results));
            ( "selected",
              `Int (List.length (List.filter (fun (s : Types.selection_result) -> s.selected <> None) results)) );
            ( "grabbed",
              `Int (List.length (List.filter (fun (s : Types.selection_result) -> s.grabbed) results)) );
          ] );
    ]

(** Select a season pack for one season of a Sonarr series. *)
let run_season ?grab_allowed (state : App_state.t) (inst : Config.instance)
    ~(series_id : int) ~(season_number : int) (opts : options) :
    (Types.selection_result, error) result Lwt.t =
  let client = App_state.client state inst in
  let* media = Client.season_media client ~series_id ~season_number in
  match media with
  | Error e ->
      let msg =
        Printf.sprintf "%s: could not load series %d season %d: %s" inst.inst_name
          series_id season_number (Client.error_to_string e)
      in
      Lwt.return (Error (arr_error_of_http ~msg e))
  | Ok media -> run_media ?grab_allowed state inst media opts

(* Episode ids the overview reported as monitored and missing. *)
let missing_ids_of_media (media : Types.media) : int list =
  match List.assoc_opt "missing_episode_ids" media.Types.extra with
  | Some (`List l) -> List.filter_map (function `Int i -> Some i | _ -> None) l
  | _ -> []

let extra_int (media : Types.media) key =
  match List.assoc_opt key media.Types.extra with Some (`Int i) -> Some i | _ -> None

(** Select every missing episode of a season individually. *)
let run_episodes ?grab_allowed state inst (episode_ids : int list) (opts : options) =
  Lwt_list.fold_left_s
    (fun acc media_id ->
      let* r = run ?grab_allowed state inst ~media_id opts in
      match r with
      | Ok result -> Lwt.return (result :: acc)
      | Error e ->
          (* One unavailable episode must not abort the rest of the season. *)
          Log_buffer.warnf "%s: %s" inst.Config.inst_name (error_to_string e);
          Lwt.return acc)
    [] episode_ids
  |> Lwt.map List.rev

(** Select releases for a whole Sonarr series, season by season, following
    [Config.seasons]: a season pack when enough of the season is missing,
    otherwise (or as a fallback) the missing episodes one by one.

    [seasons], when non-empty, restricts the work to those season numbers. *)
let run_series ?grab_allowed (state : App_state.t) (inst : Config.instance)
    ~(series_id : int) ?(seasons : int list = []) (opts : options) :
    (series_result, error) result Lwt.t =
  let cfg = App_state.config state in
  let policy = cfg.Config.seasons in
  let client = App_state.client state inst in
  let* overview = Client.fetch_series_overview client series_id in
  match overview with
  | Error e ->
      let msg =
        Printf.sprintf "%s: could not load series %d: %s" inst.inst_name series_id
          (Client.error_to_string e)
      in
      Lwt.return (Error (arr_error_of_http ~msg e))
  | Ok (series, summaries) ->
      let wanted =
        match seasons with
        | [] -> summaries
        | ns -> List.filter (fun (s : Client.season_summary) -> List.mem s.season_number ns) summaries
      in
      let missing_seasons =
        List.filter (fun n -> not (List.exists (fun (s : Client.season_summary) -> s.season_number = n) summaries)) seasons
      in
      List.iter
        (fun n ->
          Log_buffer.warnf "%s: %s has no season %d" inst.inst_name
            (Store.media_label series) n)
        missing_seasons;
      Log_buffer.infof "%s: %s: %d season(s) to consider%s" inst.inst_name
        (Store.media_label series) (List.length wanted)
        (if opts.grab then "" else " (no grab requested)");
      let* outcomes =
        Lwt_list.map_s
          (fun (s : Client.season_summary) ->
            let missing = List.length s.missing_episode_ids in
            let total = s.total_episodes in
            let plan = season_plan policy ~missing ~total in
            Log_buffer.infof "%s: %s season %d: %d/%d missing -> %s" inst.inst_name
              (Store.media_label series) s.season_number missing total
              (season_plan_to_string plan);
            let episodes () =
              let* results =
                run_episodes ?grab_allowed state inst s.missing_episode_ids opts
              in
              Lwt.return { season_number = s.season_number; missing; total; outcome = `Episodes results }
            in
            match plan with
            | Plan_skip why ->
                Lwt.return
                  { season_number = s.season_number; missing; total; outcome = `Skipped why }
            | Plan_episodes -> episodes ()
            | Plan_pack -> (
                let* pack =
                  run_season ?grab_allowed state inst ~series_id ~season_number:s.season_number
                    opts
                in
                match pack with
                | Error e ->
                    if policy.fallback_to_episodes then (
                      Log_buffer.warnf "%s: season %d pack selection failed (%s); falling back to episodes"
                        inst.inst_name s.season_number (error_to_string e);
                      episodes ())
                    else
                      Lwt.return
                        {
                          season_number = s.season_number;
                          missing;
                          total;
                          outcome = `Skipped (error_to_string e);
                        }
                | Ok result ->
                    let pack_failed =
                      result.selected = None || (opts.grab && result.grab_error <> None)
                    in
                    if pack_failed && policy.fallback_to_episodes then (
                      Log_buffer.infof
                        "%s: no usable season pack for season %d (%s); falling back to episodes"
                        inst.inst_name s.season_number
                        (match result.grab_error with Some e -> e | None -> result.reason);
                      episodes ())
                    else
                      Lwt.return
                        {
                          season_number = s.season_number;
                          missing;
                          total;
                          outcome = `Pack result;
                        }))
          wanted
      in
      Lwt.return (Ok { series; seasons = outcomes })

(** Resolve an instance by id, then {!run_season}. *)
let run_season_on_instance_id (state : App_state.t) ~(instance_id : string)
    ~(series_id : int) ~(season_number : int) (opts : options) =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> run_season state inst ~series_id ~season_number opts

(** Resolve an instance by id, then {!run_series}. *)
let run_series_on_instance_id (state : App_state.t) ~(instance_id : string)
    ~(series_id : int) ?seasons (opts : options) =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> run_series state inst ~series_id ?seasons opts

(** The default Sonarr instance, then {!run_season}. *)
let run_season_on_default (state : App_state.t) ~(series_id : int)
    ~(season_number : int) (opts : options) =
  match App_state.default_instance state Types.Sonarr with
  | None -> Lwt.return (Error (Instance_not_found "sonarr"))
  | Some inst -> run_season state inst ~series_id ~season_number opts

(** The default Sonarr instance, then {!run_series}. *)
let run_series_on_default (state : App_state.t) ~(series_id : int) ?seasons
    (opts : options) =
  match App_state.default_instance state Types.Sonarr with
  | None -> Lwt.return (Error (Instance_not_found "sonarr"))
  | Some inst -> run_series state inst ~series_id ?seasons opts

(** The series overview used by the UI to list seasons. *)
let series_overview (state : App_state.t) ~(instance_id : string) ~(series_id : int) :
    (Yojson.Safe.t, error) result Lwt.t =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> (
      let client = App_state.client state inst in
      let* overview = Client.fetch_series_overview client series_id in
      match overview with
      | Error e ->
          let msg =
            Printf.sprintf "%s: could not load series %d: %s" inst.inst_name series_id
              (Client.error_to_string e)
          in
          Lwt.return (Error (arr_error_of_http ~msg e))
      | Ok (series, summaries) ->
          Lwt.return
            (Ok
               (`Assoc
                  [
                    ("instance_id", `String inst.inst_id);
                    ("series", Types.media_to_yojson series);
                    ("total_episodes", Types.opt_int (extra_int series "total_episodes"));
                    ("missing_episodes", Types.opt_int (extra_int series "missing_episodes"));
                    ("seasons", `List (List.map Client.season_summary_to_yojson summaries));
                  ])))

(** Parse the optional ["seasons": [int]] field of a whole-series request. *)
let seasons_of_json (body : Yojson.Safe.t) : (int list, string) result =
  let number = function
    | `Int i -> Ok i
    | `Intlit s | `String s -> (
        match int_of_string_opt (String.trim s) with
        | Some i -> Ok i
        | None -> Error (Printf.sprintf "\"seasons\" contains a non-numeric value %S" s))
    | _ -> Error "\"seasons\" must be a list of season numbers"
  in
  match body with
  | `Assoc fields -> (
      match List.assoc_opt "seasons" fields with
      | None | Some `Null -> Ok []
      | Some (`List l) ->
          List.fold_left
            (fun acc v ->
              match (acc, number v) with
              | Error e, _ -> Error e
              | Ok _, Error e -> Error e
              | Ok ns, Ok n -> if n < 0 then Error "season numbers must not be negative" else Ok (n :: ns))
            (Ok []) l
          |> Result.map List.rev
      | Some (`Int n) -> if n < 0 then Error "season numbers must not be negative" else Ok [ n ]
      | Some _ -> Error "\"seasons\" must be a list of season numbers")
  | _ -> Ok []
