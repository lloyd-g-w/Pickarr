(* Automatic mode.

   Pickarr polls each automatic-enabled instance for wanted items
   (wanted/missing, optionally wanted/cutoff), runs the selection pipeline for
   them and — when [automatic.grab] is on — grabs the winner. It deliberately
   never issues EpisodeSearch/MoviesSearch commands, because those make
   Sonarr/Radarr perform their own release decision. See
   docs/AUTOMATIC_MODE.md for the rationale.

   Safety properties:
   - passes never overlap (scheduler mutex);
   - items already in the download queue are skipped;
   - items grabbed in the last 24h are skipped;
   - every attempted item enters a cooldown so a failing item is not retried
     on every pass;
   - with [automatic.grab = false] the pass is a dry run. *)

module Config = Selectarr_core.Config
module Types = Selectarr_core.Types
module Client = Selectarr_arr.Client

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Pure decision helpers (unit tested)                                 *)
(* ------------------------------------------------------------------ *)

(** Why an item must not be processed in this pass, if so.

    [attempts] maps (instance id, media id) to the unix time of the previous
    attempt; [cooldown_seconds] is how long such an item is left alone. *)
let skip_reason ~(now : float) ~(cooldown_seconds : float)
    ~(attempts : ((string * int) * float) list) ~(queue : int list)
    ~(recently_grabbed : int list) ~(instance_id : string) ~(media_id : int) :
    string option =
  if List.mem media_id queue then Some "already in the download queue"
  else if List.mem media_id recently_grabbed then Some "grabbed recently"
  else
    match List.assoc_opt (instance_id, media_id) attempts with
    | Some at when now -. at < cooldown_seconds ->
        Some
          (Printf.sprintf "attempted %.0fs ago (cooldown %.0fs)" (now -. at)
             cooldown_seconds)
    | _ -> None

(** Whether a finished selection may be grabbed in automatic mode.

    Requires [automatic.grab]; when the pick came from the LLM the confidence
    must reach [automatic.min_confidence]. Deterministic picks (including
    fallbacks after an LLM failure) are not confidence gated because there is
    no confidence to gate on. *)
let should_grab (a : Config.automatic) (r : Types.selection_result) : bool =
  if not a.auto_grab then false
  else if Option.is_none r.selected then false
  else
    match (r.method_, r.llm) with
    | Types.By_llm, Some d -> d.confidence >= a.auto_min_confidence
    | Types.By_llm, None -> false
    | Types.By_deterministic, _ | Types.By_deterministic_fallback _, _ -> true

(** Cooldown window: one interval, but never less than 10 minutes, so a
   short poll interval does not hammer the indexers through Sonarr/Radarr. *)
let cooldown_seconds (a : Config.automatic) =
  Float.max 600. (float_of_int a.auto_interval_seconds)

(** Pick the items to process this pass: skip what must be skipped, cap at
    [limit]. Returns the chosen media plus the (media, reason) pairs skipped. *)
let plan ~(now : float) ~(cooldown_seconds : float)
    ~(attempts : ((string * int) * float) list) ~(queue : int list)
    ~(recently_grabbed : int list) ~(instance_id : string) ~(limit : int)
    (wanted : Types.media list) : Types.media list * (Types.media * string) list =
  let rec go acc skipped remaining = function
    | [] -> (List.rev acc, List.rev skipped)
    | _ when remaining <= 0 -> (List.rev acc, List.rev skipped)
    | (m : Types.media) :: tl -> (
        match
          skip_reason ~now ~cooldown_seconds ~attempts ~queue ~recently_grabbed
            ~instance_id ~media_id:m.media_id
        with
        | Some reason -> go acc ((m, reason) :: skipped) remaining tl
        | None -> go (m :: acc) skipped (remaining - 1) tl)
  in
  if limit <= 0 then ([], List.map (fun m -> (m, "run limit is zero")) wanted)
  else go [] [] limit wanted

(* ------------------------------------------------------------------ *)
(* Scheduler state helpers                                             *)
(* ------------------------------------------------------------------ *)

let attempts_assoc (s : App_state.scheduler) =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) s.attempted []

let record_attempt (s : App_state.scheduler) instance_id media_id =
  Hashtbl.replace s.attempted (instance_id, media_id) (Unix.gettimeofday ())

let forget_stale_attempts (s : App_state.scheduler) ~now ~cooldown =
  Hashtbl.iter
    (fun k at -> if now -. at > cooldown *. 4. then Hashtbl.remove s.attempted k)
    (Hashtbl.copy s.attempted)

let rfc3339_of_unix t =
  match Ptime.of_float_s t with
  | Some p -> Ptime.to_rfc3339 ~tz_offset_s:0 p
  | None -> "unknown"

(* ------------------------------------------------------------------ *)
(* A single pass                                                       *)
(* ------------------------------------------------------------------ *)

let summary_of_result ~(instance : Config.instance) (r : Types.selection_result) =
  `Assoc
    [
      ("instance_id", `String instance.inst_id);
      ("instance", `String instance.inst_name);
      ("media_id", `Int r.media.media_id);
      ("media", `String (Store.media_label r.media));
      ( "selected",
        match r.selected with
        | None -> `Null
        | Some s -> `String s.scored.title );
      ("score", match r.selected with None -> `Null | Some s -> `Float s.score);
      ("method", `String (Store.method_to_string r.method_));
      ("confidence", (match r.llm with None -> `Null | Some d -> `Float d.confidence));
      ("reason", `String r.reason);
      ("grabbed", `Bool r.grabbed);
      ("grab_error", match r.grab_error with None -> `Null | Some e -> `String e);
    ]

let summary_of_skip ~(instance : Config.instance) (m : Types.media) reason =
  `Assoc
    [
      ("instance_id", `String instance.inst_id);
      ("instance", `String instance.inst_name);
      ("media_id", `Int m.media_id);
      ("media", `String (Store.media_label m));
      ("skipped", `String reason);
    ]

let summary_of_error ~(instance : Config.instance) message =
  `Assoc
    [
      ("instance_id", `String instance.inst_id);
      ("instance", `String instance.inst_name);
      ("error", `String message);
    ]

(** Collect wanted items for an instance: missing first, then cutoff-unmet if
    enabled. Only the first page is read; [limit] bounds how much work a pass
    can create anyway. *)
let fetch_wanted state (inst : Config.instance) (a : Config.automatic) ~page_size =
  let client = App_state.client state inst in
  let fetch kind =
    if page_size <= 0 then Lwt.return (Ok [])
    else
      Lwt.map
        (function Ok (items, _total) -> Ok items | Error e -> Error e)
        (Client.wanted client ~kind ~page:1 ~page_size)
  in
  let* missing = if a.auto_search_missing then fetch `Missing else Lwt.return (Ok []) in
  match missing with
  | Error e -> Lwt.return (Error e)
  | Ok missing ->
      if not a.auto_search_cutoff_unmet then Lwt.return (Ok missing)
      else
        Lwt.map
          (function
            | Ok cutoff ->
                let seen = List.map (fun (m : Types.media) -> m.media_id) missing in
                Ok
                  (missing
                  @ List.filter
                      (fun (m : Types.media) -> not (List.mem m.media_id seen))
                      cutoff)
            | Error e -> Error e)
          (fetch `Cutoff)

let process_instance state (inst : Config.instance) (a : Config.automatic) =
  let client = App_state.client state inst in
  let* queue = Client.queue_media_ids client in
  match queue with
  | Error e ->
      let msg =
        Printf.sprintf "could not read the download queue: %s" (Client.error_to_string e)
      in
      Log_buffer.warnf "automatic: %s: %s (instance skipped)" inst.inst_name msg;
      Lwt.return [ summary_of_error ~instance:inst msg ]
  | Ok queue -> (
      let* recent = Client.recently_grabbed_media_ids client ~since_hours:24. in
      match recent with
      | Error e ->
          let msg =
            Printf.sprintf "could not read history: %s" (Client.error_to_string e)
          in
          Log_buffer.warnf "automatic: %s: %s (instance skipped)" inst.inst_name msg;
          Lwt.return [ summary_of_error ~instance:inst msg ]
      | Ok recent -> (
          let page_size = max 1 (a.auto_max_items_per_run * 4) in
          let* wanted = fetch_wanted state inst a ~page_size in
          match wanted with
          | Error e ->
              let msg =
                Printf.sprintf "could not read wanted items: %s"
                  (Client.error_to_string e)
              in
              Log_buffer.warnf "automatic: %s: %s (instance skipped)" inst.inst_name msg;
              Lwt.return [ summary_of_error ~instance:inst msg ]
          | Ok wanted ->
              let now = Unix.gettimeofday () in
              let cooldown = cooldown_seconds a in
              let chosen, skipped =
                plan ~now ~cooldown_seconds:cooldown
                  ~attempts:(attempts_assoc state.App_state.scheduler)
                  ~queue ~recently_grabbed:recent ~instance_id:inst.inst_id
                  ~limit:a.auto_max_items_per_run wanted
              in
              Log_buffer.infof
                "automatic: %s: %d wanted, %d selected for processing, %d skipped%s"
                inst.inst_name (List.length wanted) (List.length chosen)
                (List.length skipped)
                (if a.auto_grab then "" else " (dry run: grabbing disabled)");
              let* results =
                Lwt_list.map_s
                  (fun (m : Types.media) ->
                    record_attempt state.App_state.scheduler inst.inst_id m.media_id;
                    let opts =
                      {
                        Selection.grab = a.auto_grab;
                        instruction = None;
                        use_ai = None;
                      }
                    in
                    let* r =
                      Selection.run ~grab_allowed:(should_grab a) state inst
                        ~media_id:m.media_id opts
                    in
                    match r with
                    | Ok result ->
                        (match result.selected with
                        | None ->
                            Log_buffer.infof "automatic: %s: no usable release for %s"
                              inst.inst_name (Store.media_label result.media)
                        | Some s ->
                            Log_buffer.infof "automatic: %s: %s %s for %s"
                              inst.inst_name
                              (if result.grabbed then "grabbed" else "would grab")
                              s.scored.title
                              (Store.media_label result.media));
                        Lwt.return (summary_of_result ~instance:inst result)
                    | Error e ->
                        let msg = Selection.error_to_string e in
                        Log_buffer.warnf "automatic: %s: %s" inst.inst_name msg;
                        Lwt.return (summary_of_error ~instance:inst msg))
                  chosen
              in
              forget_stale_attempts state.App_state.scheduler ~now ~cooldown;
              Lwt.return
                (results @ List.map (fun (m, r) -> summary_of_skip ~instance:inst m r) skipped)))

(** Run one scheduler pass over every automatic-enabled instance. Only one
    pass runs at a time; a concurrent call waits for the running pass. *)
let run_once (state : App_state.t) : Yojson.Safe.t Lwt.t =
  Lwt_mutex.with_lock state.App_state.scheduler.mutex (fun () ->
      let cfg = App_state.config state in
      let a = cfg.automatic in
      let instances = App_state.automatic_instances state in
      let sched = state.App_state.scheduler in
      let started = Unix.gettimeofday () in
      let* results =
        if instances = [] then (
          Log_buffer.infof
            "automatic: no instance has automatic mode enabled; nothing to do";
          Lwt.return [])
        else Lwt_list.map_s (fun inst -> process_instance state inst a) instances
      in
      let results = List.concat results in
      sched.runs <- sched.runs + 1;
      sched.last_run_at <- Some (rfc3339_of_unix started);
      sched.last_run_unix <- Some started;
      sched.last_results <- results;
      sched.last_error <-
        (match
           List.filter_map
             (function `Assoc f -> List.assoc_opt "error" f | _ -> None)
             results
         with
        | `String e :: _ -> Some e
        | _ -> None);
      Lwt.return
        (`Assoc
          [
            ("ran_at", `String (rfc3339_of_unix started));
            ("duration_ms", `Int (int_of_float ((Unix.gettimeofday () -. started) *. 1000.)));
            ("instances", `Int (List.length instances));
            ("dry_run", `Bool (not a.auto_grab));
            ("results", `List results);
          ]))

(* ------------------------------------------------------------------ *)
(* Background loop                                                     *)
(* ------------------------------------------------------------------ *)

let interval_of cfg =
  let i = cfg.Config.automatic.auto_interval_seconds in
  if i < 60 then 60 else i

(** Start the background scheduler. The loop stays alive for the lifetime of
    the process and re-reads the configuration every tick, so automatic mode
    can be switched on and off (and its interval changed) from the UI without
    a restart. Exceptions inside a pass are logged and do not stop the
    loop. *)
let start (state : App_state.t) =
  let rec loop () =
    let cfg = App_state.config state in
    let interval = interval_of cfg in
    let sched = state.App_state.scheduler in
    sched.enabled <- cfg.automatic.auto_enabled;
    sched.next_run_at <- Some (rfc3339_of_unix (Unix.gettimeofday () +. float_of_int interval));
    let* () = Lwt_unix.sleep (float_of_int interval) in
    let cfg = App_state.config state in
    let* () =
      if not cfg.automatic.auto_enabled then Lwt.return_unit
      else
        Lwt.catch
          (fun () -> Lwt.map (fun (_ : Yojson.Safe.t) -> ()) (run_once state))
          (fun exn ->
            let msg = Printexc.to_string exn in
            state.App_state.scheduler.last_error <- Some msg;
            Log_buffer.errorf "automatic: pass failed: %s" msg;
            Lwt.return_unit)
    in
    loop ()
  in
  Lwt.async (fun () ->
      Lwt.catch loop (fun exn ->
          Log_buffer.errorf "automatic: scheduler stopped: %s" (Printexc.to_string exn);
          Lwt.return_unit))

let status (state : App_state.t) : Yojson.Safe.t =
  let cfg = App_state.config state in
  let sched = state.App_state.scheduler in
  let opt_str = function None -> `Null | Some s -> `String s in
  `Assoc
    [
      ("enabled", `Bool cfg.automatic.auto_enabled);
      ("grab", `Bool cfg.automatic.auto_grab);
      ("interval_seconds", `Int (interval_of cfg));
      ("min_confidence", `Float cfg.automatic.auto_min_confidence);
      ("max_items_per_run", `Int cfg.automatic.auto_max_items_per_run);
      ("webhook_trigger", `Bool cfg.automatic.auto_webhook_trigger);
      ( "instances",
        `List
          (List.map
             (fun (i : Config.instance) -> `String i.inst_name)
             (App_state.automatic_instances state)) );
      ("runs", `Int sched.runs);
      ("running", `Bool (Lwt_mutex.is_locked sched.mutex));
      ("last_run_at", opt_str sched.last_run_at);
      ("next_run_at", opt_str sched.next_run_at);
      ("last_error", opt_str sched.last_error);
      ("cooldown_entries", `Int (Hashtbl.length sched.attempted));
      ("last_results", `List sched.last_results);
    ]

(* ------------------------------------------------------------------ *)
(* Webhooks                                                            *)
(* ------------------------------------------------------------------ *)

(** Webhook events that mean "this item now needs a release".

    Verified against the upstream enums (vendor/sonarr-WebhookEventType.cs,
    vendor/radarr-WebhookEventType.cs): Sonarr sends SeriesAdd and
    EpisodeFileDelete, Radarr sends MovieAdded and MovieFileDelete. There is
    no "download failed" webhook event in either application. *)
let trigger_events = [ "SeriesAdd"; "MovieAdded"; "EpisodeFileDelete"; "MovieFileDelete" ]

let is_trigger_event event =
  List.exists
    (fun e -> String.lowercase_ascii e = String.lowercase_ascii event)
    trigger_events

(** Decide what a webhook should cause, given the event name and the media ids
    the payload carried. Pure so it can be unit tested. *)
let webhook_action ~(trigger_enabled : bool) ~(event : string) ~(media_ids : int list) =
  if String.lowercase_ascii event = "test" then `Test
  else if not trigger_enabled then `Ignored "webhook triggers are disabled"
  else if not (is_trigger_event event) then `Ignored ("event not actionable: " ^ event)
  else match media_ids with [] -> `Full_pass | ids -> `Select ids

(** Handle a webhook payload for [inst]. Never fails the request: unknown or
    non-actionable events are acknowledged. Selections run in the background
    so the *arr webhook call returns immediately. *)
let handle_webhook (state : App_state.t) (inst : Config.instance) (body : Yojson.Safe.t)
    : Yojson.Safe.t =
  let cfg = App_state.config state in
  match Client.parse_webhook inst.inst_app body with
  | Error e ->
      Log_buffer.warnf "webhook: %s: unparseable payload: %s" inst.inst_name e;
      `Assoc [ ("accepted", `Bool false); ("error", `String e) ]
  | Ok (event, media_ids) -> (
      match
        webhook_action ~trigger_enabled:cfg.automatic.auto_webhook_trigger ~event
          ~media_ids
      with
      | `Test ->
          Log_buffer.infof "webhook: %s: test event received" inst.inst_name;
          `Assoc [ ("accepted", `Bool true); ("event", `String event); ("action", `String "test") ]
      | `Ignored why ->
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String event);
              ("action", `String "ignored");
              ("detail", `String why);
            ]
      | `Full_pass ->
          Log_buffer.infof "webhook: %s: %s triggered a scheduler pass" inst.inst_name
            event;
          Lwt.async (fun () ->
              Lwt.catch
                (fun () -> Lwt.map (fun (_ : Yojson.Safe.t) -> ()) (run_once state))
                (fun exn ->
                  Log_buffer.errorf "webhook: pass failed: %s" (Printexc.to_string exn);
                  Lwt.return_unit));
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String event);
              ("action", `String "scheduler_pass");
            ]
      | `Select ids ->
          Log_buffer.infof "webhook: %s: %s triggered selection for %d item(s)"
            inst.inst_name event (List.length ids);
          let a = cfg.automatic in
          Lwt.async (fun () ->
              Lwt_list.iter_s
                (fun media_id ->
                  record_attempt state.App_state.scheduler inst.inst_id media_id;
                  Lwt.catch
                    (fun () ->
                      Lwt.map
                        (function
                          | Ok (_ : Types.selection_result) -> ()
                          | Error e ->
                              Log_buffer.warnf "webhook: %s: %s" inst.inst_name
                                (Selection.error_to_string e))
                        (Selection.run ~grab_allowed:(should_grab a) state inst ~media_id
                           { Selection.grab = a.auto_grab; instruction = None; use_ai = None }))
                    (fun exn ->
                      Log_buffer.errorf "webhook: selection failed: %s"
                        (Printexc.to_string exn);
                      Lwt.return_unit))
                ids);
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String event);
              ("action", `String "select");
              ("media_ids", `List (List.map (fun i -> `Int i) ids));
            ])
