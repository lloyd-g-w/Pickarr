(* The queue job kinds: every user and background action Pickarr performs
   runs as one of these jobs (see lib/server/jobs.mli for the queue itself).

     search         run the pipeline for a movie / episode / season / series
     grab_best      the same, then grab the winner
     grab_release   grab one specific release from the last search
     seerr_select   work one Seerr request like the Search page
     seerr_fulfil   fulfil one Seerr request the way the poller would
     automatic_pass one automatic-mode pass
     seerr_pass     one Seerr poller pass
     seerr_webhook  one lookup of a Seerr webhook notification

   Each kind has a synchronous parameter parser (no I/O) and a runner that
   calls the existing logic and returns exactly the JSON the synchronous HTTP
   endpoints have always answered, links included.  Runner errors carry the
   HTTP status they stand for as a "[ddd] " prefix (see {!Responses}) so the
   endpoints that wait for a job keep their status codes.

   [seerr_fulfil] is not in the original queue contract: it is the job that
   replaced the background fulfilment after a manual approval.  [search] and
   [grab_best] accept an optional ["gate": "automatic"] (webhook selections
   keep automatic mode's confidence rule), and [grab_release] an optional
   ["release_title"] used for the initial label. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Parameters (pure, unit tested)                                      *)
(* ------------------------------------------------------------------ *)

(** What a selection job works on. *)
type target =
  | Movie of int  (** Radarr movie id *)
  | Episode of int  (** Sonarr episode id *)
  | Season of { series_id : int; season_number : int }  (** a season pack *)
  | Series of { series_id : int; seasons : int list }
      (** season by season; [seasons = []] means every season *)

let field key = function `Assoc f -> List.assoc_opt key f | _ -> None

let positive_int key json : (int, string) result =
  let bad = Error (Printf.sprintf "\"%s\" must be a positive integer" key) in
  match field key json with
  | Some (`Int i) when i > 0 -> Ok i
  | Some (`String s) -> (
      match int_of_string_opt (String.trim s) with Some i when i > 0 -> Ok i | _ -> bad)
  | _ -> bad

let season_number_of key json : (int, string) result =
  let bad = Error (Printf.sprintf "\"%s\" must be a season number (0 or greater)" key) in
  match field key json with
  | Some (`Int i) when i >= 0 -> Ok i
  | Some (`String s) -> (
      match int_of_string_opt (String.trim s) with Some i when i >= 0 -> Ok i | _ -> bad)
  | _ -> bad

(** Parse a [target] object:
    [{"kind":"movie","media_id":n}], [{"kind":"episode","media_id":n}],
    [{"kind":"season","series_id":n,"season_number":n}] or
    [{"kind":"series","series_id":n,"seasons":[n...]?}]. *)
let target_of_json (json : Yojson.Safe.t) : (target, string) result =
  match json with
  | `Assoc _ -> (
      match field "kind" json with
      | Some (`String "movie") -> Result.map (fun i -> Movie i) (positive_int "media_id" json)
      | Some (`String "episode") -> Result.map (fun i -> Episode i) (positive_int "media_id" json)
      | Some (`String "season") -> (
          match (positive_int "series_id" json, season_number_of "season_number" json) with
          | Error e, _ | _, Error e -> Error e
          | Ok series_id, Ok season_number -> Ok (Season { series_id; season_number }))
      | Some (`String "series") -> (
          match (positive_int "series_id" json, Selection.seasons_of_json json) with
          | Error e, _ | _, Error e -> Error e
          | Ok series_id, Ok seasons -> Ok (Series { series_id; seasons }))
      | Some (`String k) ->
          Error
            (Printf.sprintf
               "unknown target kind \"%s\" (expected movie, episode, season or series)" k)
      | _ -> Error "\"target.kind\" is required")
  | _ -> Error "\"target\" must be an object"

let target_to_json : target -> Yojson.Safe.t = function
  | Movie id -> `Assoc [ ("kind", `String "movie"); ("media_id", `Int id) ]
  | Episode id -> `Assoc [ ("kind", `String "episode"); ("media_id", `Int id) ]
  | Season { series_id; season_number } ->
      `Assoc
        [
          ("kind", `String "season");
          ("series_id", `Int series_id);
          ("season_number", `Int season_number);
        ]
  | Series { series_id; seasons = [] } ->
      `Assoc [ ("kind", `String "series"); ("series_id", `Int series_id) ]
  | Series { series_id; seasons } ->
      `Assoc
        [
          ("kind", `String "series");
          ("series_id", `Int series_id);
          ("seasons", `List (List.map (fun n -> `Int n) seasons));
        ]

(** The part of a dedupe key that names the target. *)
let target_key : target -> string = function
  | Movie id -> Printf.sprintf "movie:%d" id
  | Episode id -> Printf.sprintf "episode:%d" id
  | Season { series_id; season_number } -> Printf.sprintf "season:%d:%d" series_id season_number
  | Series { series_id; seasons = [] } -> Printf.sprintf "series:%d" series_id
  | Series { series_id; seasons } ->
      Printf.sprintf "series:%d:%s" series_id
        (String.concat "," (List.map string_of_int seasons))

(** Which application a target belongs to. *)
let target_app : target -> Types.app = function
  | Movie _ -> Types.Radarr
  | Episode _ | Season _ | Series _ -> Types.Sonarr

(** The placeholder title used until the media title is known. *)
let target_description (inst : Config.instance) : target -> string = function
  | Movie id -> Printf.sprintf "%s movie %d" inst.inst_name id
  | Episode id -> Printf.sprintf "%s episode %d" inst.inst_name id
  | Season { series_id; season_number } ->
      Printf.sprintf "%s series %d season %d" inst.inst_name series_id season_number
  | Series { series_id; seasons = [] } -> Printf.sprintf "%s series %d" inst.inst_name series_id
  | Series { series_id; seasons } ->
      Printf.sprintf "%s series %d seasons %s" inst.inst_name series_id
        (String.concat ", " (List.map string_of_int seasons))

(** Look the ["instance_id"] up; unknown ids are a 404. *)
let instance_of ~(find_instance : string -> Config.instance option) (params : Yojson.Safe.t) :
    (Config.instance, string) result =
  match field "instance_id" params with
  | Some (`String id) when String.trim id <> "" -> (
      let id = String.trim id in
      match find_instance id with
      | Some inst -> Ok inst
      | None -> Error (Responses.unknown_instance id))
  | _ -> Error "\"instance_id\" is required"

let target_for_instance (inst : Config.instance) (params : Yojson.Safe.t) :
    (target, string) result =
  match field "target" params with
  | None -> Error "\"target\" is required"
  | Some t -> (
      match target_of_json t with
      | Error e -> Error e
      | Ok target ->
          if target_app target <> inst.inst_app then
            Error
              (Printf.sprintf "%s is a %s instance; a %s target needs a %s instance"
                 inst.inst_name
                 (Types.app_to_string inst.inst_app)
                 (match target with
                 | Movie _ -> "movie"
                 | Episode _ -> "episode"
                 | Season _ -> "season"
                 | Series _ -> "series")
                 (Types.app_to_string (target_app target)))
          else Ok target)

(** The [instruction] / [use_ai] options of a selection job.  [grab] in the
    parameters is ignored: the kind decides. *)
let options_of_params ~(grab : bool) (params : Yojson.Safe.t) :
    (Selection.options, string) result =
  let relevant =
    match params with
    | `Assoc f ->
        `Assoc (List.filter (fun (k, _) -> k = "instruction" || k = "use_ai") f)
    | _ -> `Null
  in
  Result.map (fun o -> { o with Selection.grab }) (Selection.options_of_json relevant)

type gate = No_gate | Automatic_gate

let gate_of_params (params : Yojson.Safe.t) : (gate, string) result =
  match field "gate" params with
  | None | Some `Null | Some (`String ("" | "none")) -> Ok No_gate
  | Some (`String "automatic") -> Ok Automatic_gate
  | Some _ -> Error "\"gate\" must be \"automatic\" or \"none\""

(** A parsed "search" or "grab_best" job. *)
type selection_job = {
  sj_instance : Config.instance;
  sj_target : target;
  sj_options : Selection.options;
  sj_gate : gate;
}

let parse_selection ~(find_instance : string -> Config.instance option) ~(grab : bool)
    (params : Yojson.Safe.t) : (selection_job, string) result =
  match params with
  | `Assoc _ -> (
      match instance_of ~find_instance params with
      | Error e -> Error e
      | Ok inst -> (
          match
            (target_for_instance inst params, options_of_params ~grab params, gate_of_params params)
          with
          | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e
          | Ok target, Ok options, Ok gate ->
              Ok { sj_instance = inst; sj_target = target; sj_options = options; sj_gate = gate }))
  | _ -> Error "parameters must be a JSON object"

let selection_dedupe_key ~(kind : string) (j : selection_job) : string =
  Printf.sprintf "%s:%s:%s" kind j.sj_instance.inst_id (target_key j.sj_target)

let selection_label_prefix ~(grab : bool) = if grab then "Grab" else "Search"

let selection_label ~(grab : bool) (j : selection_job) : string =
  Printf.sprintf "%s \xc2\xb7 %s" (selection_label_prefix ~grab)
    (target_description j.sj_instance j.sj_target)

(** A parsed "grab_release" job. *)
type release_job = {
  rj_instance : Config.instance;
  rj_target : target;  (** never [Series] *)
  rj_release : Selection.grab_target;
  rj_title : string option;
}

let parse_release ~(find_instance : string -> Config.instance option) (params : Yojson.Safe.t)
    : (release_job, string) result =
  match params with
  | `Assoc _ -> (
      match instance_of ~find_instance params with
      | Error e -> Error e
      | Ok inst -> (
          match (target_for_instance inst params, Selection.grab_target_of_json params) with
          | Error e, _ | _, Error e -> Error e
          | Ok (Series _), _ ->
              Error "a whole series cannot be grabbed as one release; pick a season"
          | Ok target, Ok release ->
              let title =
                match field "release_title" params with
                | Some (`String t) when String.trim t <> "" -> Some (String.trim t)
                | _ -> None
              in
              Ok { rj_instance = inst; rj_target = target; rj_release = release; rj_title = title }))
  | _ -> Error "parameters must be a JSON object"

let release_dedupe_key (j : release_job) : string =
  Printf.sprintf "grab_release:%s:%s" j.rj_instance.inst_id j.rj_release.target_release_id

let release_label (j : release_job) : string =
  Printf.sprintf "Grab release \xc2\xb7 %s"
    (match j.rj_title with
    | Some t -> t
    | None -> target_description j.rj_instance j.rj_target)

let request_id_of (params : Yojson.Safe.t) : (int, string) result =
  match params with
  | `Assoc _ -> positive_int "request_id" params
  | _ -> Error "parameters must be a JSON object"

(** A parsed "seerr_select" job. *)
let parse_seerr_select (params : Yojson.Safe.t) : (int * Seerr_sync.select_body, string) result
    =
  match request_id_of params with
  | Error e -> Error e
  | Ok request_id ->
      Result.map (fun body -> (request_id, body)) (Seerr_sync.select_body_of_json params)

let seerr_label ~(request_id : int) = Printf.sprintf "Seerr request #%d" request_id

(* ------------------------------------------------------------------ *)
(* Runners                                                             *)
(* ------------------------------------------------------------------ *)

(** Run [f] inside the job, with an {!Activity} context so the code it calls
    can report progress, emit job-tagged events and name the job.
    [title] turns a media title into the job's label; [None] keeps the label
    (the passes). *)
let in_job ~(instance_id : string option) ~(title : (string -> string) option)
    (f : unit -> (Yojson.Safe.t, string) result Lwt.t) : Jobs.ctx -> (Yojson.Safe.t, string) result Lwt.t =
 fun (ctx : Jobs.ctx) ->
  let activity =
    {
      Activity.job_id = ctx.job_id;
      instance_id;
      progress = ctx.progress;
      set_title = (match title with Some t -> fun s -> ctx.set_label (t s) | None -> fun _ -> ());
      prefix = "";
      titled = false;
    }
  in
  Activity.with_ctx activity f

let titled prefix = Some (fun t -> Printf.sprintf "%s \xc2\xb7 %s" prefix t)

let run_selection_job (state : App_state.t) (j : selection_job) () :
    (Yojson.Safe.t, string) result Lwt.t =
  let inst = j.sj_instance and opts = j.sj_options in
  let grab_allowed =
    match j.sj_gate with
    | No_gate -> None
    | Automatic_gate -> Some (Automatic.should_grab (App_state.config state).automatic)
  in
  let finish json = Ok (Responses.decorate state ~instance_id:inst.inst_id json) in
  let of_selection = function
    | Error e -> Error (Responses.selection_error e)
    | Ok r -> finish (Types.selection_result_to_yojson r)
  in
  match j.sj_target with
  | Movie media_id | Episode media_id ->
      Lwt.map of_selection (Selection.run ?grab_allowed state inst ~media_id opts)
  | Season { series_id; season_number } ->
      Lwt.map of_selection (Selection.run_season ?grab_allowed state inst ~series_id ~season_number opts)
  | Series { series_id; seasons } ->
      let* r = Selection.run_series ?grab_allowed state inst ~series_id ~seasons opts in
      Lwt.return
        (match r with
        | Error e -> Error (Responses.selection_error e)
        | Ok r -> finish (Selection.series_result_to_yojson r))

let run_release_job (state : App_state.t) (j : release_job) () :
    (Yojson.Safe.t, string) result Lwt.t =
  let inst = j.rj_instance and target = j.rj_release in
  let* r =
    match j.rj_target with
    | Movie media_id | Episode media_id -> Selection.grab_release state inst ~media_id ~target
    | Season { series_id; season_number } ->
        Selection.grab_release_season state inst ~series_id ~season_number ~target
    | Series _ -> Lwt.return (Error (Selection.Bad_request "a whole series cannot be grabbed"))
  in
  Lwt.return
    (match r with
    | Error e -> Error (Responses.selection_error e)
    | Ok r ->
        Ok
          (Responses.decorate state ~instance_id:inst.inst_id
             (Types.selection_result_to_yojson r)))

let string_member key json =
  match field key json with Some (`String s) -> Some s | _ -> None

let run_seerr_select (state : App_state.t) ~(request_id : int) (body : Seerr_sync.select_body) ()
    : (Yojson.Safe.t, string) result Lwt.t =
  let* r = Seerr_sync.select_for_request state ~request_id body in
  Lwt.return
    (match r with
    | Error e -> Error (Responses.seerr_error e)
    | Ok json -> Ok (Responses.decorate state ?instance_id:(string_member "instance_id" json) json))

let run_seerr_fulfil (state : App_state.t) ~(request_id : int) () :
    (Yojson.Safe.t, string) result Lwt.t =
  let* r = Seerr_sync.fulfil_by_id state request_id in
  Lwt.return
    (match r with
    | Ok json -> Ok json
    | Error (`Unconfigured m) -> Error (Responses.status_error ~status:409 m)
    | Error (`Not_found m) -> Error (Responses.status_error ~status:404 m)
    | Error (`Upstream m) -> Error (Responses.status_error ~status:502 m))

let run_seerr_webhook (state : App_state.t) (ev : Pickarr_arr.Client.seerr_event)
    (app : Types.app) (attempt : int) () : (Yojson.Safe.t, string) result Lwt.t =
  let label = Option.value ev.seerr_subject ~default:"(untitled)" in
  Activity.set_title label;
  Activity.progress
    (Printf.sprintf "looking for it in %s (attempt %d/%d)" (Types.app_to_string app) attempt
       Automatic.seerr_max_attempts);
  let* r = Automatic.seerr_resolve_once state app ev in
  match r with
  | Automatic.Seerr_done summary ->
      Lwt.return
        (Ok
           (match summary with
           | `Assoc f -> `Assoc (f @ [ ("attempt", `Int attempt) ])
           | other -> other))
  | Automatic.Seerr_no_instance m -> Lwt.return (Error (Responses.status_error ~status:409 m))
  | Automatic.Seerr_not_yet when attempt < Automatic.seerr_max_attempts ->
      Log_buffer.infof "seerr: \"%s\" not in %s yet (attempt %d/%d); retrying in %.0fs" label
        (Types.app_to_string app) attempt Automatic.seerr_max_attempts
        Automatic.seerr_retry_delay;
      Automatic.schedule_seerr_lookup state ~delay:Automatic.seerr_retry_delay
        ~attempt:(attempt + 1) ev;
      Lwt.return
        (Ok
           (`Assoc
             [
               ("subject", `String label);
               ("status", `String "not_in_arr_yet");
               ("attempt", `Int attempt);
               ("next_attempt_in_seconds", `Float Automatic.seerr_retry_delay);
             ]))
  | Automatic.Seerr_not_yet ->
      let msg =
        Printf.sprintf
          "\"%s\" never appeared as a monitored, missing item in %s (gave up after %d attempts)"
          label (Types.app_to_string app) attempt
      in
      Log_buffer.warnf "seerr: %s" msg;
      Lwt.return (Error (Responses.status_error ~status:404 msg))

(* ------------------------------------------------------------------ *)
(* Registration                                                        *)
(* ------------------------------------------------------------------ *)

let register_selection ~(kind : string) ~(grab : bool) =
  Jobs.register kind (fun state params ->
      Result.map
        (fun (j : selection_job) ->
          {
            Jobs.label = selection_label ~grab j;
            instance_id = Some j.sj_instance.inst_id;
            dedupe_key = Some (selection_dedupe_key ~kind j);
            run =
              in_job ~instance_id:(Some j.sj_instance.inst_id)
                ~title:(titled (selection_label_prefix ~grab))
                (run_selection_job state j);
          })
        (parse_selection ~find_instance:(App_state.find_instance state) ~grab params))

let register_all () =
  register_selection ~kind:"search" ~grab:false;
  register_selection ~kind:"grab_best" ~grab:true;
  Jobs.register "grab_release" (fun state params ->
      Result.map
        (fun (j : release_job) ->
          {
            Jobs.label = release_label j;
            instance_id = Some j.rj_instance.inst_id;
            dedupe_key = Some (release_dedupe_key j);
            run =
              in_job ~instance_id:(Some j.rj_instance.inst_id) ~title:(titled "Grab release")
                (run_release_job state j);
          })
        (parse_release ~find_instance:(App_state.find_instance state) params));
  Jobs.register "seerr_select" (fun state params ->
      Result.map
        (fun (request_id, (body : Seerr_sync.select_body)) ->
          let prefix = seerr_label ~request_id in
          {
            Jobs.label = prefix;
            instance_id = body.sb_instance_id;
            dedupe_key = None;
            run =
              in_job ~instance_id:body.sb_instance_id ~title:(titled prefix)
                (run_seerr_select state ~request_id body);
          })
        (parse_seerr_select params));
  Jobs.register "seerr_fulfil" (fun state params ->
      Result.map
        (fun request_id ->
          let prefix = seerr_label ~request_id in
          {
            Jobs.label = prefix ^ " \xc2\xb7 fulfil";
            instance_id = None;
            dedupe_key = Some (Printf.sprintf "seerr_fulfil:%d" request_id);
            run = in_job ~instance_id:None ~title:(titled prefix) (run_seerr_fulfil state ~request_id);
          })
        (request_id_of params));
  Jobs.register "automatic_pass" (fun state _params ->
      Ok
        {
          Jobs.label = "Automatic pass";
          instance_id = None;
          dedupe_key = Some "automatic_pass";
          run =
            in_job ~instance_id:None ~title:None (fun () ->
                Lwt.map (fun summary -> Ok summary) (Automatic.run_once state));
        });
  Jobs.register "seerr_pass" (fun state _params ->
      Ok
        {
          Jobs.label = "Seerr pass";
          instance_id = None;
          dedupe_key = Some "seerr_pass";
          run =
            in_job ~instance_id:None ~title:None (fun () ->
                Lwt.map (fun summary -> Ok summary) (Seerr_sync.run_once state));
        });
  Jobs.register "seerr_webhook" (fun state params ->
      Result.map
        (fun ((ev : Pickarr_arr.Client.seerr_event), app, attempt) ->
          {
            Jobs.label =
              Printf.sprintf "Seerr webhook \xc2\xb7 %s%s"
                (Option.value ev.seerr_subject ~default:ev.seerr_notification_type)
                (if attempt > 1 then Printf.sprintf " (attempt %d)" attempt else "");
            instance_id = None;
            dedupe_key = None;
            run = in_job ~instance_id:None ~title:None (run_seerr_webhook state ev app attempt);
          })
        (Automatic.seerr_event_of_params params))
