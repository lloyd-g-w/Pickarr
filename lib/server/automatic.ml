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

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client

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
(* Season grouping (unit tested)                                       *)
(* ------------------------------------------------------------------ *)

(** The (series, season) an episode belongs to, when both are known. *)
let season_key (m : Types.media) : (int * int) option =
  if m.media_kind <> "episode" then None
  else
    match (List.assoc_opt "series_id" m.extra, m.season_number) with
    | Some (`Int series_id), Some season_number -> Some (series_id, season_number)
    | _ -> None

(** Group wanted episodes by (series id, season number), preserving the order
    in which the seasons were first seen.  Episodes whose series or season is
    unknown (and anything that is not an episode) are returned separately and
    handled one by one. *)
let group_by_season (media : Types.media list) :
    ((int * int) * Types.media list) list * Types.media list =
  let keys =
    List.fold_left
      (fun acc m ->
        match season_key m with
        | Some key when not (List.mem key acc) -> key :: acc
        | _ -> acc)
      [] media
    |> List.rev
  in
  let groups =
    List.map (fun key -> (key, List.filter (fun m -> season_key m = Some key) media)) keys
  in
  (groups, List.filter (fun m -> season_key m = None) media)

(* ------------------------------------------------------------------ *)
(* Scheduler state helpers                                             *)
(* ------------------------------------------------------------------ *)

let attempts_assoc (s : App_state.scheduler) =
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) s.attempted []

let record_attempt = App_state.record_attempt

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

(* One series overview per pass and per series: a season decision needs the
   whole-season episode counts, which the wanted list does not carry. *)
let season_summary_lookup state (inst : Config.instance) =
  let cache : (int, Client.season_summary list) Hashtbl.t = Hashtbl.create 8 in
  let client = App_state.client state inst in
  fun ~(series_id : int) ~(season_number : int) ->
    let find summaries =
      List.find_opt
        (fun (s : Client.season_summary) -> s.season_number = season_number)
        summaries
    in
    match Hashtbl.find_opt cache series_id with
    | Some summaries -> Lwt.return (find summaries)
    | None -> (
        let* overview = Client.fetch_series_overview client series_id in
        match overview with
        | Error e ->
            Log_buffer.warnf
              "automatic: %s: could not read the seasons of series %d (%s); \
               falling back to single episodes"
              inst.inst_name series_id (Client.error_to_string e);
            Hashtbl.replace cache series_id [];
            Lwt.return None
        | Ok (_series, summaries) ->
            Hashtbl.replace cache series_id summaries;
            Lwt.return (find summaries))

(* One automatic.item event per finished selection. *)
let item_event (inst : Config.instance) (result : Types.selection_result) =
  let label = Store.media_label result.media in
  Activity.event ~instance_id:inst.inst_id ~media:label
    ?level:(if result.grab_error <> None then Some Events.Warn else None)
    ~data:
      [
        ("media_id", `Int result.media.media_id);
        ( "selected",
          match result.selected with None -> `Null | Some s -> `String s.scored.title );
        ("grabbed", `Bool result.grabbed);
        ("grab_error", match result.grab_error with None -> `Null | Some e -> `String e);
        ("method", `String (Store.method_to_string result.method_));
      ]
    "automatic.item"
    (match result.selected with
    | None -> Printf.sprintf "automatic: %s: no usable release for %s" inst.inst_name label
    | Some s ->
        Printf.sprintf "automatic: %s: %s %s for %s" inst.inst_name
          (if result.grabbed then "grabbed" else "would grab")
          s.scored.title label)

(* Run the chosen items.  Sonarr episodes of the same season are collapsed
   into a single season-pack selection when the configured policy asks for
   it; everything else is processed one item at a time. *)
let process_chosen state (inst : Config.instance) (a : Config.automatic)
    ~(opts : Selection.options) ~(run_one : Types.media -> Yojson.Safe.t Lwt.t)
    (chosen : Types.media list) : Yojson.Safe.t list Lwt.t =
  let cfg = App_state.config state in
  let policy = cfg.Config.seasons in
  if inst.inst_app <> Types.Sonarr || not policy.prefer_packs then
    Lwt_list.map_s run_one chosen
  else
    let groups, ungrouped = group_by_season chosen in
    let season_summary = season_summary_lookup state inst in
    let* grouped_results =
      Lwt_list.map_s
        (fun ((series_id, season_number), (items : Types.media list)) ->
          let* summary = season_summary ~series_id ~season_number in
          let plan =
            match summary with
            | None -> Selection.Plan_episodes
            | Some s ->
                Selection.season_plan policy
                  ~missing:(List.length s.missing_episode_ids)
                  ~total:s.total_episodes
          in
          match (plan, summary) with
          | Selection.Plan_pack, Some s ->
              (* The whole season is attempted as one item; every missing
                 episode enters the cooldown so the next pass leaves the
                 season alone. *)
              List.iter
                (record_attempt state.App_state.scheduler inst.inst_id)
                s.missing_episode_ids;
              Log_buffer.infof
                "automatic: %s: series %d season %d: %d/%d missing -> one season pack"
                inst.inst_name series_id season_number
                (List.length s.missing_episode_ids) s.total_episodes;
              Activity.set_prefix
                (Printf.sprintf "%s series %d season %d (pack): " inst.inst_name series_id
                   season_number);
              let* r =
                Selection.run_season ~grab_allowed:(should_grab a) state inst ~series_id
                  ~season_number opts
              in
              Activity.set_prefix "";
              (match r with
              | Ok result ->
                  item_event inst result;
                  (match result.selected with
                  | None ->
                      Log_buffer.infof
                        "automatic: %s: no usable season pack for %s" inst.inst_name
                        (Store.media_label result.media)
                  | Some sel ->
                      Log_buffer.infof "automatic: %s: %s %s for %s" inst.inst_name
                        (if result.grabbed then "grabbed" else "would grab")
                        sel.scored.title
                        (Store.media_label result.media));
                  (* No pack survived the rules: fall back to the episodes
                     this pass had picked, as a manual run would. *)
                  if result.selected = None && policy.fallback_to_episodes then
                    let* per_episode = Lwt_list.map_s run_one items in
                    Lwt.return (summary_of_result ~instance:inst result :: per_episode)
                  else Lwt.return [ summary_of_result ~instance:inst result ]
              | Error e ->
                  let msg = Selection.error_to_string e in
                  Log_buffer.warnf "automatic: %s: %s" inst.inst_name msg;
                  if policy.fallback_to_episodes then
                    let* per_episode = Lwt_list.map_s run_one items in
                    Lwt.return (summary_of_error ~instance:inst msg :: per_episode)
                  else Lwt.return [ summary_of_error ~instance:inst msg ])
          | _ -> Lwt_list.map_s run_one items)
        groups
    in
    let* ungrouped_results = Lwt_list.map_s run_one ungrouped in
    Lwt.return (List.concat grouped_results @ ungrouped_results)

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
              let opts =
                { Selection.grab = a.auto_grab; instruction = None; use_ai = None }
              in
              let total = List.length chosen in
              let counter = ref 0 in
              let run_one (m : Types.media) =
                incr counter;
                let label = Store.media_label m in
                Activity.set_prefix
                  (Printf.sprintf "%s item %d/%d: %s \xe2\x80\x94 " inst.inst_name !counter
                     (max total !counter) label);
                record_attempt state.App_state.scheduler inst.inst_id m.media_id;
                let* r =
                  Selection.run ~grab_allowed:(should_grab a) state inst
                    ~media_id:m.media_id opts
                in
                Activity.set_prefix "";
                match r with
                | Ok result ->
                    (match result.selected with
                    | None ->
                        Log_buffer.infof "automatic: %s: no usable release for %s"
                          inst.inst_name (Store.media_label result.media)
                    | Some s ->
                        Log_buffer.infof "automatic: %s: %s %s for %s" inst.inst_name
                          (if result.grabbed then "grabbed" else "would grab")
                          s.scored.title
                          (Store.media_label result.media));
                    item_event inst result;
                    Lwt.return (summary_of_result ~instance:inst result)
                | Error e ->
                    let msg = Selection.error_to_string e in
                    Log_buffer.warnf "automatic: %s: %s" inst.inst_name msg;
                    Activity.event ~level:Events.Warn ~instance_id:inst.inst_id ~media:label
                      ~data:[ ("media_id", `Int m.media_id); ("error", `String msg) ]
                      "automatic.item"
                      (Printf.sprintf "automatic: %s: %s" inst.inst_name msg);
                    Lwt.return (summary_of_error ~instance:inst msg)
              in
              let* results = process_chosen state inst a ~opts ~run_one chosen in
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
      let duration_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.) in
      let count key =
        List.length
          (List.filter
             (function
               | `Assoc f -> (
                   match List.assoc_opt key f with
                   | None | Some `Null | Some (`Bool false) -> false
                   | Some _ -> true)
               | _ -> false)
             results)
      in
      Activity.event
        ?level:(if sched.last_error <> None then Some Events.Warn else None)
        ~data:
          [
            ("instances", `Int (List.length instances));
            ("items", `Int (List.length results));
            ("selected", `Int (count "selected"));
            ("grabbed", `Int (count "grabbed"));
            ("skipped", `Int (count "skipped"));
            ("errors", `Int (count "error"));
            ("dry_run", `Bool (not a.auto_grab));
            ("duration_ms", `Int duration_ms);
          ]
        "automatic.pass"
        (Printf.sprintf "automatic pass: %d instance(s), %d item(s), %d grabbed%s"
           (List.length instances) (List.length results) (count "grabbed")
           (if a.auto_grab then "" else " (dry run)"));
      Lwt.return
        (`Assoc
          [
            ("ran_at", `String (rfc3339_of_unix started));
            ("duration_ms", `Int duration_ms);
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
    (* The pass itself runs as an "automatic_pass" queue job, so it is visible
       in the queue and never overlaps a pass that is still queued or running
       (the job is de-duplicated). *)
    (if cfg.automatic.auto_enabled then
       match Jobs.enqueue state ~source:"automatic" "automatic_pass" (`Assoc []) with
       | Ok _ -> ()
       | Error e ->
           state.App_state.scheduler.last_error <- Some e;
           Log_buffer.errorf "automatic: could not queue a pass: %s" e);
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

(** The queue job a webhook-triggered selection becomes: a "grab_best" when
    automatic mode may grab, otherwise a "search" (a dry run), gated by the
    automatic-mode confidence rule ([gate = "automatic"]).  Pure. *)
let webhook_job (a : Config.automatic) (inst : Config.instance) (media_id : int) :
    string * Yojson.Safe.t =
  let target_kind = match inst.inst_app with Types.Radarr -> "movie" | Types.Sonarr -> "episode" in
  ( (if a.auto_grab then "grab_best" else "search"),
    `Assoc
      [
        ("instance_id", `String inst.inst_id);
        ("target", `Assoc [ ("kind", `String target_kind); ("media_id", `Int media_id) ]);
        ("gate", `String "automatic");
      ] )

let job_id_of (job : Yojson.Safe.t) : Yojson.Safe.t =
  match job with
  | `Assoc f -> ( match List.assoc_opt "id" f with Some (`Int i) -> `Int i | _ -> `Null)
  | _ -> `Null

(** Handle a webhook payload for [inst]. Never fails the request: unknown or
    non-actionable events are acknowledged. The work is queued (source
    "webhook") so the *arr webhook call returns immediately and the
    selection shows up in the queue. *)
let handle_webhook (state : App_state.t) (inst : Config.instance) (body : Yojson.Safe.t)
    : Yojson.Safe.t =
  let cfg = App_state.config state in
  match Client.parse_webhook inst.inst_app body with
  | Error e ->
      Log_buffer.warnf "webhook: %s: unparseable payload: %s" inst.inst_name e;
      Activity.event ~level:Events.Warn ~instance_id:inst.inst_id
        ~data:[ ("app", `String (Types.app_to_string inst.inst_app)); ("error", `String e) ]
        "webhook.received"
        (Printf.sprintf "webhook from %s: unparseable payload: %s" inst.inst_name e);
      `Assoc [ ("accepted", `Bool false); ("error", `String e) ]
  | Ok (event, media_ids) -> (
      let action =
        webhook_action ~trigger_enabled:cfg.automatic.auto_webhook_trigger ~event ~media_ids
      in
      Activity.event ~instance_id:inst.inst_id
        ~data:
          [
            ("app", `String (Types.app_to_string inst.inst_app));
            ("event", `String event);
            ("media_ids", `List (List.map (fun i -> `Int i) media_ids));
            ( "action",
              `String
                (match action with
                | `Test -> "test"
                | `Ignored _ -> "ignored"
                | `Full_pass -> "scheduler_pass"
                | `Select _ -> "select") );
          ]
        "webhook.received"
        (Printf.sprintf "webhook from %s: %s" inst.inst_name event);
      match action with
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
          let job =
            match Jobs.enqueue state ~source:"webhook" "automatic_pass" (`Assoc []) with
            | Ok job -> job_id_of job
            | Error e ->
                Log_buffer.errorf "webhook: could not queue a pass: %s" e;
                `Null
          in
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String event);
              ("action", `String "scheduler_pass");
              ("job_id", job);
            ]
      | `Select ids ->
          Log_buffer.infof "webhook: %s: %s triggered selection for %d item(s)"
            inst.inst_name event (List.length ids);
          let a = cfg.automatic in
          let jobs =
            List.filter_map
              (fun media_id ->
                record_attempt state.App_state.scheduler inst.inst_id media_id;
                let kind, params = webhook_job a inst media_id in
                match Jobs.enqueue state ~source:"webhook" kind params with
                | Ok job -> Some (job_id_of job)
                | Error e ->
                    Log_buffer.warnf "webhook: %s: could not queue media %d: %s"
                      inst.inst_name media_id e;
                    None)
              ids
          in
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String event);
              ("action", `String "select");
              ("media_ids", `List (List.map (fun i -> `Int i) ids));
              ("job_ids", `List jobs);
            ])

(* ------------------------------------------------------------------ *)
(* Seerr / Overseerr / Jellyseerr webhook                              *)
(* ------------------------------------------------------------------ *)

(** Seerr notification types that mean "this media was just requested and
    approved", i.e. Sonarr/Radarr are about to (or just did) add it. *)
let seerr_trigger_types = [ "MEDIA_APPROVED"; "MEDIA_AUTO_APPROVED" ]

(** Decide what a Seerr notification should cause. Pure so it can be unit
    tested. *)
let seerr_action ~(trigger_enabled : bool) (ev : Client.seerr_event) =
  let nt = String.uppercase_ascii ev.Client.seerr_notification_type in
  if nt = "TEST_NOTIFICATION" then `Test
  else if not trigger_enabled then `Ignored "webhook triggers are disabled"
  else if not (List.mem nt seerr_trigger_types) then `Ignored ("event not actionable: " ^ nt)
  else
    match ev.Client.seerr_media_type with
    | Some "movie" when ev.Client.seerr_tmdb_id <> None -> `Resolve Types.Radarr
    | Some "tv" when ev.Client.seerr_tvdb_id <> None -> `Resolve Types.Sonarr
    | Some "tv" -> `Ignored "tv request without a tvdbId"
    | Some "movie" -> `Ignored "movie request without a tmdbId"
    | Some other -> `Ignored ("unknown media_type: " ^ other)
    | None -> `Ignored "notification carries no media"

(** How long to wait before looking the request up in Sonarr/Radarr: Seerr
    sends the notification as it approves, before the *arr has finished
    adding the item, so the first lookup is delayed and retried.  Each lookup
    is a short "seerr_webhook" queue job; the waiting happens outside the
    queue so a pending lookup never holds a worker. *)
let seerr_initial_delay = 20.0
let seerr_retry_delay = 60.0
let seerr_max_attempts = 5

(** The "seerr_webhook" job parameters for a parsed notification.  Pure;
    {!seerr_event_of_params} is its inverse. *)
let seerr_event_to_params ?(attempt = 1) (ev : Client.seerr_event) : Yojson.Safe.t =
  let opt_int = function None -> `Null | Some i -> `Int i in
  `Assoc
    [
      ("notification_type", `String ev.Client.seerr_notification_type);
      ("media_type", match ev.Client.seerr_media_type with None -> `Null | Some m -> `String m);
      ("tmdb_id", opt_int ev.Client.seerr_tmdb_id);
      ("tvdb_id", opt_int ev.Client.seerr_tvdb_id);
      ("seasons", `List (List.map (fun n -> `Int n) ev.Client.seerr_seasons));
      ("subject", match ev.Client.seerr_subject with None -> `Null | Some s -> `String s);
      ("attempt", `Int attempt);
    ]

(** Parse "seerr_webhook" job parameters: the event, the *arr it belongs to
    and the attempt number.  Pure. *)
let seerr_event_of_params (params : Yojson.Safe.t) :
    (Client.seerr_event * Types.app * int, string) result =
  match params with
  | `Assoc f -> (
      let str k =
        match List.assoc_opt k f with
        | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
        | _ -> None
      in
      let int k =
        match List.assoc_opt k f with
        | Some (`Int i) when i > 0 -> Ok (Some i)
        | None | Some `Null -> Ok None
        | Some (`String s) -> (
            match int_of_string_opt (String.trim s) with
            | Some i when i > 0 -> Ok (Some i)
            | _ -> Error (Printf.sprintf "\"%s\" must be a positive integer" k))
        | Some _ -> Error (Printf.sprintf "\"%s\" must be a positive integer" k)
      in
      let seasons =
        match List.assoc_opt "seasons" f with
        | None | Some `Null -> Ok []
        | Some (`List l) ->
            List.fold_right
              (fun v acc ->
                match (v, acc) with
                | `Int n, Ok ns when n >= 0 -> Ok (n :: ns)
                | _, Error e -> Error e
                | _ -> Error "\"seasons\" must be a list of season numbers")
              l (Ok [])
        | Some _ -> Error "\"seasons\" must be a list of season numbers"
      in
      let attempt =
        match List.assoc_opt "attempt" f with
        | None | Some `Null -> Ok 1
        | Some (`Int n) when n >= 1 -> Ok n
        | Some _ -> Error "\"attempt\" must be a positive integer"
      in
      match (str "notification_type", int "tmdb_id", int "tvdb_id", seasons, attempt) with
      | None, _, _, _, _ -> Error "\"notification_type\" is required"
      | _, Error e, _, _, _ | _, _, Error e, _, _ | _, _, _, Error e, _ | _, _, _, _, Error e ->
          Error e
      | Some nt, Ok tmdb, Ok tvdb, Ok seasons, Ok attempt -> (
          let media_type = Option.map String.lowercase_ascii (str "media_type") in
          let ev =
            {
              Client.seerr_notification_type = nt;
              seerr_media_type = media_type;
              seerr_tmdb_id = tmdb;
              seerr_tvdb_id = tvdb;
              seerr_seasons = seasons;
              seerr_subject = str "subject";
            }
          in
          match media_type with
          | Some "movie" when tmdb <> None -> Ok (ev, Types.Radarr, attempt)
          | Some "tv" when tvdb <> None -> Ok (ev, Types.Sonarr, attempt)
          | Some "movie" -> Error "a movie notification needs a \"tmdb_id\""
          | Some "tv" -> Error "a tv notification needs a \"tvdb_id\""
          | _ -> Error "\"media_type\" must be \"movie\" or \"tv\""))
  | _ -> Error "parameters must be a JSON object"

(** What one lookup of a Seerr notification found. *)
type seerr_attempt =
  | Seerr_done of Yojson.Safe.t  (** Selections ran; the summary. *)
  | Seerr_not_yet  (** Nothing in Sonarr/Radarr yet: try again later. *)
  | Seerr_no_instance of string  (** Nothing to try it on. *)

(** One lookup: resolve the notification against every enabled instance of
    [app] and, when something matched, run the selections (automatic-mode
    grab policy).  No waiting here; {!seerr_resolve_and_select} and the
    "seerr_webhook" job decide when to look again. *)
let seerr_resolve_once (state : App_state.t) (app : Types.app) (ev : Client.seerr_event) :
    seerr_attempt Lwt.t =
  let cfg = App_state.config state in
  let a = cfg.automatic in
  let label = Option.value ev.Client.seerr_subject ~default:"(untitled)" in
  let instances =
    List.filter (fun (i : Config.instance) -> i.inst_enabled && i.inst_app = app) cfg.instances
  in
  let opts = { Selection.grab = a.auto_grab; instruction = None; use_ai = None } in
  if instances = [] then (
    let msg =
      Printf.sprintf "\"%s\" is a %s request but no enabled %s instance is configured" label
        (Types.app_to_string app) (Types.app_to_string app)
    in
    Log_buffer.warnf "seerr: %s" msg;
    Lwt.return (Seerr_no_instance msg))
  else
    let* found =
      Lwt_list.map_s
        (fun inst ->
          let* target =
            Fulfil.resolve state inst ~log:"seerr" ~tmdb_id:ev.Client.seerr_tmdb_id
              ~tvdb_id:ev.Client.seerr_tvdb_id ~seasons:ev.Client.seerr_seasons ()
          in
          Lwt.return (inst, target))
        instances
    in
    let total =
      List.fold_left (fun acc (_, target) -> acc + Fulfil.target_items target) 0 found
    in
    if total = 0 then Lwt.return Seerr_not_yet
    else (
      Log_buffer.infof "seerr: \"%s\" resolved to %d item(s); running selection" label total;
      Activity.event ~media:label
        ~data:[ ("items", `Int total); ("app", `String (Types.app_to_string app)) ]
        "seerr.resolved"
        (Printf.sprintf "seerr: \"%s\" resolved to %d item(s)" label total);
      let* per_instance =
        Lwt_list.map_s
          (fun ((inst : Config.instance), target) ->
            if Fulfil.target_items target = 0 then Lwt.return []
            else (
              Activity.progress
                (Printf.sprintf "%s: %s" inst.inst_name (Fulfil.target_to_string target));
              let* outcome =
                Fulfil.run state inst ~log:"seerr" ~grab_allowed:(should_grab a) target opts
              in
              Lwt.return
                (List.map (fun r -> summary_of_result ~instance:inst r) outcome.Fulfil.results
                @
                match outcome.Fulfil.error with
                | None -> []
                | Some msg -> [ summary_of_error ~instance:inst msg ])))
          found
      in
      Lwt.return
        (Seerr_done
           (`Assoc
             [
               ("subject", `String label);
               ("app", `String (Types.app_to_string app));
               ("items", `Int total);
               ("results", `List (List.concat per_instance));
             ])))

(** Look a notification up, retrying while the *arr is still adding the item,
    and run the selections.  Waits inline; kept for callers outside the
    queue.  The webhook path uses the "seerr_webhook" job instead. *)
let seerr_resolve_and_select (state : App_state.t) (app : Types.app) (ev : Client.seerr_event) =
  let label = Option.value ev.Client.seerr_subject ~default:"(untitled)" in
  let rec attempt n =
    let* () = Lwt_unix.sleep (if n = 1 then seerr_initial_delay else seerr_retry_delay) in
    let* r = seerr_resolve_once state app ev in
    match r with
    | Seerr_done _ | Seerr_no_instance _ -> Lwt.return_unit
    | Seerr_not_yet when n < seerr_max_attempts ->
        Log_buffer.infof "seerr: \"%s\" not in %s yet (attempt %d/%d); retrying" label
          (Types.app_to_string app) n seerr_max_attempts;
        attempt (n + 1)
    | Seerr_not_yet ->
        Log_buffer.warnf
          "seerr: \"%s\" never appeared as a monitored, missing item in %s; giving up" label
          (Types.app_to_string app);
        Lwt.return_unit
  in
  attempt 1

(** Queue the "seerr_webhook" lookup for [ev] after [delay] seconds. *)
let schedule_seerr_lookup (state : App_state.t) ~(delay : float) ?(attempt = 1)
    (ev : Client.seerr_event) =
  Lwt.async (fun () ->
      Lwt.catch
        (fun () ->
          let* () = Lwt_unix.sleep delay in
          (match
             Jobs.enqueue state ~source:"webhook" "seerr_webhook"
               (seerr_event_to_params ~attempt ev)
           with
          | Ok _ -> ()
          | Error e -> Log_buffer.errorf "seerr: could not queue the lookup: %s" e);
          Lwt.return_unit)
        (fun exn ->
          Log_buffer.errorf "seerr: could not queue the lookup: %s" (Printexc.to_string exn);
          Lwt.return_unit))

(** Handle a Seerr webhook body. Always acknowledges; the lookup and
    selection are queued (after a short delay, while Seerr pushes the item to
    the *arr) so Seerr's request returns immediately. *)
let handle_seerr_webhook (state : App_state.t) (body : Yojson.Safe.t) : Yojson.Safe.t =
  let cfg = App_state.config state in
  match Client.parse_seerr_webhook body with
  | Error e ->
      Log_buffer.warnf "seerr: unparseable payload: %s" e;
      Activity.event ~level:Events.Warn
        ~data:[ ("source", `String "seerr"); ("error", `String e) ]
        "webhook.received"
        (Printf.sprintf "Seerr webhook: unparseable payload: %s" e);
      `Assoc [ ("accepted", `Bool false); ("error", `String e) ]
  | Ok ev -> (
      let nt = ev.Client.seerr_notification_type in
      let action = seerr_action ~trigger_enabled:cfg.automatic.auto_webhook_trigger ev in
      Activity.event ?media:ev.Client.seerr_subject
        ~data:
          [
            ("source", `String "seerr");
            ("event", `String nt);
            ( "media_type",
              match ev.Client.seerr_media_type with None -> `Null | Some m -> `String m );
            ( "action",
              `String
                (match action with
                | `Test -> "test"
                | `Ignored _ -> "ignored"
                | `Resolve _ -> "resolve_and_select") );
          ]
        "webhook.received"
        (Printf.sprintf "Seerr webhook: %s%s" nt
           (match ev.Client.seerr_subject with Some s -> " for " ^ s | None -> ""));
      match action with
      | `Test ->
          Log_buffer.infof "seerr: test notification received";
          `Assoc [ ("accepted", `Bool true); ("event", `String nt); ("action", `String "test") ]
      | `Ignored why ->
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String nt);
              ("action", `String "ignored");
              ("detail", `String why);
            ]
      | `Resolve app ->
          Log_buffer.infof "seerr: %s for \"%s\" (%s); scheduling lookup" nt
            (Option.value ev.Client.seerr_subject ~default:"?")
            (Types.app_to_string app);
          schedule_seerr_lookup state ~delay:seerr_initial_delay ev;
          `Assoc
            [
              ("accepted", `Bool true);
              ("event", `String nt);
              ("action", `String "resolve_and_select");
              ("app", `String (Types.app_to_string app));
            ])
