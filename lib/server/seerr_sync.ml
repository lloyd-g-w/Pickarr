(* Seerr / Overseerr / Jellyseerr request integration.

   Pickarr polls Seerr's request queue and, for every approved request that is
   not available yet, resolves the media in Sonarr/Radarr and runs the normal
   selection pipeline for it. Optionally it also approves pending requests
   first, so a Seerr user's request goes straight from "requested" to a
   Pickarr-chosen release.

   Division of labour:
   - Seerr keeps owning the request list, approvals and its own *arr push
     (adding the movie/series and setting the quality profile);
   - Pickarr only decides which release is grabbed, through Sonarr/Radarr.

   The Seerr webhook (see Automatic.handle_seerr_webhook) does the same thing
   event-driven for newly approved items; this poller is the safety net that
   also covers requests approved while Pickarr was down, and requests that
   Sonarr/Radarr never found a release for.

   Safety properties, mirroring automatic mode:
   - passes never overlap (mutex);
   - a request is retried at most once every [attempt_cooldown_seconds];
   - requests whose media is already available are skipped;
   - with [seerr.grab = false] a pass is a dry run. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client
module Seerr = Pickarr_arr.Seerr

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Pure decision helpers (unit tested)                                 *)
(* ------------------------------------------------------------------ *)

let contains_ci ~needle ~haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else
    let needle = String.lowercase_ascii needle and haystack = String.lowercase_ascii haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0

(** Whether an instance looks like a 4K instance. Seerr models 4K as a
    separate *arr server; Pickarr has no such concept, so the instance name or
    id is the only signal available. *)
let is_4k_instance (i : Config.instance) =
  contains_ci ~needle:"4k" ~haystack:i.inst_name
  || contains_ci ~needle:"4k" ~haystack:i.inst_id

(** Pick the instances a request should be fulfilled on, given the enabled
    instances of the right app. A 4K request prefers 4K-looking instances; a
    normal request prefers the others. When the preferred set is empty every
    candidate is used, so a single-instance setup always works. *)
let choose_instances ~(is4k : bool) (instances : Config.instance list) :
    Config.instance list =
  let four_k, normal = List.partition is_4k_instance instances in
  let preferred = if is4k then four_k else normal in
  if preferred <> [] then preferred else instances

(** Which *arr application fulfils a request type. *)
let app_of_media_type (t : string option) : Types.app option =
  match Option.map String.lowercase_ascii t with
  | Some "movie" -> Some Types.Radarr
  | Some "tv" | Some "series" -> Some Types.Sonarr
  | _ -> None

(** How long a request is left alone after Pickarr attempted it. Long enough
    that a request nothing can be found for does not occupy every pass. *)
let attempt_cooldown_seconds = 6. *. 3600.

(** Why a request must not be processed in this pass, if so. [attempted] maps
    a Seerr request id to the unix time of the previous attempt. *)
let skip_reason ~(now : float) ~(cooldown_seconds : float)
    ~(attempted : (int * float) list) (r : Seerr.request) : string option =
  if r.rq_status <> Seerr.status_approved then
    Some ("request is " ^ Seerr.request_status_to_string r.rq_status)
  else if Seerr.request_media_status r = Seerr.media_available then
    Some "media is already available"
  else if app_of_media_type r.rq_type = None then
    Some
      (Printf.sprintf "unsupported request type %s"
         (Option.value r.rq_type ~default:"(none)"))
  else
    match List.assoc_opt r.rq_id attempted with
    | Some at when now -. at < cooldown_seconds ->
        Some
          (Printf.sprintf "attempted %.0fs ago (cooldown %.0fs)" (now -. at) cooldown_seconds)
    | _ -> None

(** Choose the requests to fulfil this pass: skip what must be skipped, cap at
    [limit]. Returns the chosen requests plus the (request, reason) pairs that
    were skipped. *)
let plan ~(now : float) ~(cooldown_seconds : float) ~(attempted : (int * float) list)
    ~(limit : int) (requests : Seerr.request list) :
    Seerr.request list * (Seerr.request * string) list =
  let rec go acc skipped remaining = function
    | [] -> (List.rev acc, List.rev skipped)
    | rest when remaining <= 0 ->
        (List.rev acc, List.rev skipped @ List.map (fun r -> (r, "run limit reached")) rest)
    | (r : Seerr.request) :: tl -> (
        match skip_reason ~now ~cooldown_seconds ~attempted r with
        | Some reason -> go acc ((r, reason) :: skipped) remaining tl
        | None -> go (r :: acc) skipped (remaining - 1) tl)
  in
  if limit <= 0 then ([], List.map (fun r -> (r, "run limit is zero")) requests)
  else go [] [] limit requests

(** A request is ready to be looked up in the *arr only once Seerr has pushed
    it there. This is advisory: Seerr sets the id asynchronously, so a missing
    id only means "try again", never "give up". *)
let pushed_to_arr (r : Seerr.request) = Seerr.request_external_service_id r <> None

(* ------------------------------------------------------------------ *)
(* Poller state (module level: one Seerr connection per process)       *)
(* ------------------------------------------------------------------ *)

type sync = {
  mutex : Lwt_mutex.t;
  mutable runs : int;
  mutable last_run_at : string option;
  mutable next_run_at : string option;
  mutable last_error : string option;
  mutable last_results : Yojson.Safe.t list;
  mutable last_approved : int;
  mutable last_fulfilled : int;
  attempted : (int, float) Hashtbl.t;  (** Seerr request id -> unix time *)
}

let sync =
  {
    mutex = Lwt_mutex.create ();
    runs = 0;
    last_run_at = None;
    next_run_at = None;
    last_error = None;
    last_results = [];
    last_approved = 0;
    last_fulfilled = 0;
    attempted = Hashtbl.create 32;
  }

let attempts_assoc () = Hashtbl.fold (fun k v acc -> (k, v) :: acc) sync.attempted []
let record_attempt request_id = Hashtbl.replace sync.attempted request_id (Unix.gettimeofday ())

let forget_stale_attempts ~now =
  Hashtbl.iter
    (fun k at -> if now -. at > attempt_cooldown_seconds *. 4. then Hashtbl.remove sync.attempted k)
    (Hashtbl.copy sync.attempted)

(** Whether the integration is configured well enough to talk to Seerr. *)
let configured (s : Config.seerr) =
  s.seerr_enabled && String.trim s.seerr_url <> "" && String.trim s.seerr_api_key <> ""

let unconfigured_reason (s : Config.seerr) =
  if not s.seerr_enabled then "the Seerr integration is disabled"
  else if String.trim s.seerr_url = "" then "no Seerr URL is configured"
  else if String.trim s.seerr_api_key = "" then "no Seerr API key is configured"
  else "ready"

(* ------------------------------------------------------------------ *)
(* Titles (requests carry none; looked up best effort and cached)      *)
(* ------------------------------------------------------------------ *)

(** How many result entries are kept for the UI. *)
let max_remembered_results = 100

type title_cache = (string * int, Seerr.title option) Hashtbl.t

let title_cache () : title_cache = Hashtbl.create 16

let title_of_request (s : Config.seerr) (cache : title_cache) (r : Seerr.request) :
    Seerr.title option Lwt.t =
  match (r.rq_type, r.rq_media.mi_tmdb_id) with
  | Some kind, Some tmdb -> (
      match Hashtbl.find_opt cache (kind, tmdb) with
      | Some cached -> Lwt.return cached
      | None ->
          let base_url = s.seerr_url and api_key = s.seerr_api_key in
          let* looked_up =
            if kind = "movie" then Seerr.movie_title ~base_url ~api_key tmdb
            else Seerr.tv_title ~base_url ~api_key tmdb
          in
          let title =
            match looked_up with
            | Ok t when String.trim t.ti_title <> "" -> Some t
            | Ok _ -> None
            | Error e ->
                Log_buffer.warnf "seerr: could not read the title of %s %d: %s" kind tmdb
                  (Pickarr_arr.Http.error_to_string e);
                None
          in
          Hashtbl.replace cache (kind, tmdb) title;
          Lwt.return title)
  | _ -> Lwt.return None

(** Human label for logs and summaries. *)
let label ?(title : Seerr.title option) (r : Seerr.request) =
  match title with
  | Some t ->
      Printf.sprintf "%s%s" t.ti_title
        (match t.ti_year with Some y -> Printf.sprintf " (%d)" y | None -> "")
      ^ if r.rq_is4k then " [4K]" else ""
  | None ->
      Printf.sprintf "%s request #%d"
        (Option.value r.rq_type ~default:"unknown")
        r.rq_id

(* ------------------------------------------------------------------ *)
(* Compact JSON for the UI                                             *)
(* ------------------------------------------------------------------ *)

let opt_str = function None -> `Null | Some s -> `String s
let opt_int = function None -> `Null | Some i -> `Int i

let request_to_compact ?(title : Seerr.title option) (r : Seerr.request) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `Int r.rq_id);
      ("status", `Int r.rq_status);
      ("status_label", `String (Seerr.request_status_to_string r.rq_status));
      ("type", opt_str r.rq_type);
      ("is4k", `Bool r.rq_is4k);
      ("title", match title with None -> `Null | Some t -> `String t.ti_title);
      ("year", match title with None -> `Null | Some t -> opt_int t.ti_year);
      ("tmdb_id", opt_int r.rq_media.mi_tmdb_id);
      ("tvdb_id", opt_int r.rq_media.mi_tvdb_id);
      ("seasons", `List (List.map (fun n -> `Int n) (Seerr.season_numbers r)));
      ( "requested_by",
        match r.rq_requested_by with
        | None -> `Null
        | Some u -> `String (Option.value u.us_name ~default:(Option.value u.us_email ~default:"?")) );
      ("created_at", opt_str r.rq_created_at);
      ("media_status", `Int (Seerr.request_media_status r));
      ("media_status_label", `String (Seerr.media_status_to_string (Seerr.request_media_status r)));
      ("pushed_to_arr", `Bool (pushed_to_arr r));
    ]

let summary_of_request ?(title : Seerr.title option) (r : Seerr.request) extra =
  `Assoc
    ([ ("request_id", `Int r.rq_id); ("request", `String (label ?title r)) ] @ extra)

let summary_of_error ?(title : Seerr.title option) (r : Seerr.request) message =
  summary_of_request ?title r [ ("error", `String message) ]

let summary_of_skip ?(title : Seerr.title option) (r : Seerr.request) reason =
  summary_of_request ?title r [ ("skipped", `String reason) ]

(* ------------------------------------------------------------------ *)
(* Fulfilment                                                          *)
(* ------------------------------------------------------------------ *)

(** How Pickarr grabs for a Seerr request: the Seerr [grab] switch decides
    whether anything is grabbed at all, and automatic mode's minimum AI
    confidence still gates LLM picks. *)
let grab_policy (cfg : Config.t) =
  Automatic.should_grab { cfg.automatic with auto_grab = cfg.seerr.seerr_grab }

let selection_options (cfg : Config.t) =
  { Selection.grab = cfg.seerr.seerr_grab; instruction = None; use_ai = None }

(** Resolve what a request means on one instance: a movie, a set of seasons
    of a series, or (as a fallback) individual episodes.  See
    {!Fulfil.resolve}. *)
let resolve_on_instance (state : App_state.t) (r : Seerr.request) (inst : Config.instance) :
    Fulfil.target Lwt.t =
  Fulfil.resolve state inst ~log:"seerr" ~tmdb_id:r.rq_media.mi_tmdb_id
    ~tvdb_id:r.rq_media.mi_tvdb_id ~seasons:(Seerr.season_numbers r)
    ?external_service_id:(Seerr.request_external_service_id r) ()

(** Run a resolved target and turn it into the per-selection summaries the UI
    shows, plus the per-season detail for a TV request. *)
let fulfil_on_instance (state : App_state.t) (cfg : Config.t) (inst : Config.instance)
    (target : Fulfil.target) : (Yojson.Safe.t list * Yojson.Safe.t list) Lwt.t =
  let* outcome =
    Fulfil.run state inst ~log:"seerr" ~grab_allowed:(grab_policy cfg) target
      (selection_options cfg)
  in
  let summaries =
    List.map (fun r -> Automatic.summary_of_result ~instance:inst r) outcome.results
  in
  let summaries =
    match outcome.error with
    | None -> summaries
    | Some msg -> summaries @ [ Automatic.summary_of_error ~instance:inst msg ]
  in
  Lwt.return (summaries, Fulfil.seasons_to_compact outcome)

(** Delays before the 1st, 2nd and 3rd resolution attempt of a request within
    one pass. Seerr approves and pushes to the *arr asynchronously, so an item
    approved moments ago is not there yet. *)
let resolve_delays = [ 0.; 15.; 60. ]

(** Fulfil one request: pick the instances, resolve the media ids (retrying
    while the *arr is still adding the item) and run a selection for each. *)
let fulfil_request (state : App_state.t) (cfg : Config.t) ?(title : Seerr.title option)
    (r : Seerr.request) : Yojson.Safe.t list Lwt.t =
  match app_of_media_type r.rq_type with
  | None ->
      Lwt.return
        [ summary_of_skip ?title r ("unsupported request type " ^ Option.value r.rq_type ~default:"(none)") ]
  | Some app -> (
      let candidates =
        List.filter
          (fun (i : Config.instance) -> i.inst_enabled && i.inst_app = app)
          cfg.instances
      in
      match choose_instances ~is4k:r.rq_is4k candidates with
      | [] ->
          let msg =
            Printf.sprintf "no enabled %s instance is configured" (Types.app_to_string app)
          in
          Log_buffer.warnf "seerr: %s: %s" (label ?title r) msg;
          Lwt.return [ summary_of_error ?title r msg ]
      | instances ->
          record_attempt r.rq_id;
          let rec attempt delays =
            let* found =
              Lwt_list.map_s
                (fun inst ->
                  let* target = resolve_on_instance state r inst in
                  Lwt.return (inst, target))
                instances
            in
            let total =
              List.fold_left
                (fun acc (_, target) -> acc + Fulfil.target_items target)
                0 found
            in
            if total > 0 then Lwt.return (Some (found, total))
            else
              match delays with
              | [] -> Lwt.return None
              | delay :: rest ->
                  Log_buffer.infof
                    "seerr: %s is not a monitored, missing item in %s yet; retrying in %.0fs"
                    (label ?title r) (Types.app_to_string app) delay;
                  let* () = Lwt_unix.sleep delay in
                  attempt rest
          in
          let* outcome =
            match resolve_delays with
            | [] -> attempt []
            | first :: rest ->
                let* () = if first > 0. then Lwt_unix.sleep first else Lwt.return_unit in
                attempt rest
          in
          (match outcome with
          | None ->
              let msg =
                Printf.sprintf
                  "nothing to select: %s has no monitored, missing item for this request%s"
                  (Types.app_to_string app)
                  (if pushed_to_arr r then "" else " (Seerr has not pushed it yet)")
              in
              Log_buffer.warnf "seerr: %s: %s" (label ?title r) msg;
              Lwt.return [ summary_of_skip ?title r msg ]
          | Some (found, total) ->
              let* per_instance =
                Lwt_list.map_s
                  (fun ((inst : Config.instance), target) ->
                    if Fulfil.target_items target = 0 then Lwt.return ([], [])
                    else (
                      Log_buffer.infof "seerr: %s: fulfilling %s with %s" inst.inst_name
                        (label ?title r) (Fulfil.target_to_string target);
                      fulfil_on_instance state cfg inst target))
                  found
              in
              let results = List.concat_map fst per_instance in
              let seasons = List.concat_map snd per_instance in
              Lwt.return
                (summary_of_request ?title r
                   ([ ("action", `String "fulfilled"); ("items", `Int total) ]
                   @ if seasons = [] then [] else [ ("seasons", `List seasons) ])
                :: results)))

(* ------------------------------------------------------------------ *)
(* Approval                                                            *)
(* ------------------------------------------------------------------ *)

(** Approve the pending requests, oldest first. Seerr then pushes each item to
    Sonarr/Radarr itself; the fulfilment step below picks them up (retrying
    while the push is still in flight).

    Requests are only approved when [seerr.auto_approve] is on. Users who let
    Seerr auto-approve for them never see a pending request here, which is
    fine: the fulfilment step is what matters. *)
let approve_pending (cfg : Config.t) (cache : title_cache) :
    (Yojson.Safe.t list * Seerr.request list) Lwt.t =
  let s = cfg.seerr in
  let base_url = s.seerr_url and api_key = s.seerr_api_key in
  let* page =
    Seerr.requests ~base_url ~api_key ~filter:`Pending ~take:s.seerr_max_requests_per_run
      ~sort:"added" ~sort_direction:"asc" ()
  in
  match page with
  | Error e ->
      let msg = Pickarr_arr.Http.error_to_string e in
      Log_buffer.warnf "seerr: could not read pending requests: %s" msg;
      Lwt.return ([ `Assoc [ ("error", `String msg) ] ], [])
  | Ok page ->
      let* results =
        Lwt_list.map_s
          (fun (r : Seerr.request) ->
            let* title = title_of_request s cache r in
            let* approved = Seerr.approve ~base_url ~api_key r.rq_id in
            match approved with
            | Ok updated ->
                Log_buffer.infof "seerr: approved %s (request #%d)" (label ?title r) r.rq_id;
                Lwt.return
                  (summary_of_request ?title r [ ("action", `String "approved") ], Some updated)
            | Error e ->
                let msg = Pickarr_arr.Http.error_to_string e in
                Log_buffer.warnf "seerr: could not approve request #%d: %s" r.rq_id msg;
                Lwt.return (summary_of_error ?title r msg, None))
          page.rp_results
      in
      Lwt.return (List.map fst results, List.filter_map snd results)

(* ------------------------------------------------------------------ *)
(* One pass                                                            *)
(* ------------------------------------------------------------------ *)

let interval_of (cfg : Config.t) = max 30 cfg.seerr.seerr_poll_interval_seconds

(** Fulfil the approved-but-unavailable requests.

    [extra] are requests approved earlier in this same pass: Seerr's
    [filter=processing] page is read before they are visible there, so they
    are merged in explicitly. *)
let process_approved (state : App_state.t) (cfg : Config.t) (cache : title_cache)
    ~(extra : Seerr.request list) : Yojson.Safe.t list Lwt.t =
  let s = cfg.seerr in
  let base_url = s.seerr_url and api_key = s.seerr_api_key in
  let* page =
    Seerr.requests ~base_url ~api_key ~filter:`Processing ~take:(s.seerr_max_requests_per_run * 2)
      ~sort:"added" ~sort_direction:"asc" ()
  in
  match page with
  | Error e ->
      let msg = Pickarr_arr.Http.error_to_string e in
      Log_buffer.warnf "seerr: could not read approved requests: %s" msg;
      Lwt.return [ `Assoc [ ("error", `String msg) ] ]
  | Ok page ->
      let known = List.map (fun (r : Seerr.request) -> r.rq_id) page.rp_results in
      let requests =
        page.rp_results
        @ List.filter (fun (r : Seerr.request) -> not (List.mem r.rq_id known)) extra
      in
      let now = Unix.gettimeofday () in
      (* A request approved in this pass is fulfilled now even if an earlier
         pass already attempted it: the approval is new information. *)
      let approved_now = List.map (fun (r : Seerr.request) -> r.rq_id) extra in
      let attempted =
        List.filter (fun (id, _) -> not (List.mem id approved_now)) (attempts_assoc ())
      in
      let chosen, skipped =
        plan ~now ~cooldown_seconds:attempt_cooldown_seconds ~attempted
          ~limit:s.seerr_max_requests_per_run requests
      in
      Log_buffer.infof "seerr: %d approved request(s), %d to fulfil, %d skipped%s"
        (List.length requests) (List.length chosen) (List.length skipped)
        (if s.seerr_grab then "" else " (dry run: grabbing disabled)");
      let* results =
        Lwt_list.map_s
          (fun (r : Seerr.request) ->
            let* title = title_of_request s cache r in
            fulfil_request state cfg ?title r)
          chosen
      in
      let* skipped =
        Lwt_list.map_s
          (fun ((r : Seerr.request), reason) ->
            let* title = title_of_request s cache r in
            Lwt.return (summary_of_skip ?title r reason))
          skipped
      in
      forget_stale_attempts ~now;
      Lwt.return (List.concat results @ skipped)

let error_summary message = `Assoc [ ("error", `String message) ]

(** Run one Seerr pass: approve (optional), then fulfil. Never raises; the
    summary is also stored for the UI. *)
let run_once (state : App_state.t) : Yojson.Safe.t Lwt.t =
  Lwt_mutex.with_lock sync.mutex (fun () ->
      let cfg = App_state.config state in
      let s = cfg.seerr in
      let started = Unix.gettimeofday () in
      let finish results =
        sync.runs <- sync.runs + 1;
        sync.last_run_at <- Some (Automatic.rfc3339_of_unix started);
        sync.last_results <- List.filteri (fun i _ -> i < max_remembered_results) results;
        sync.last_error <-
          (match
             List.filter_map (function `Assoc f -> List.assoc_opt "error" f | _ -> None) results
           with
          | `String e :: _ -> Some e
          | _ -> None);
        Lwt.return
          (`Assoc
            [
              ("ran_at", `String (Automatic.rfc3339_of_unix started));
              ( "duration_ms",
                `Int (int_of_float ((Unix.gettimeofday () -. started) *. 1000.)) );
              ("approved", `Int sync.last_approved);
              ("fulfilled", `Int sync.last_fulfilled);
              ("dry_run", `Bool (not s.seerr_grab));
              ("results", `List results);
            ])
      in
      if not (configured s) then (
        sync.last_error <- Some (unconfigured_reason s);
        finish [ error_summary (unconfigured_reason s) ])
      else
        let cache = title_cache () in
        let* approvals, approved_now =
          if s.seerr_auto_approve then approve_pending cfg cache else Lwt.return ([], [])
        in
        sync.last_approved <- List.length approved_now;
        let* fulfilments =
          if s.seerr_process_approved then process_approved state cfg cache ~extra:approved_now
          else Lwt.return []
        in
        sync.last_fulfilled <-
          List.length
            (List.filter
               (function
                 | `Assoc f -> List.assoc_opt "action" f = Some (`String "fulfilled")
                 | _ -> false)
               fulfilments);
        finish (approvals @ fulfilments))

(* ------------------------------------------------------------------ *)
(* Single-request actions (used by the routes)                         *)
(* ------------------------------------------------------------------ *)

(** Fulfil one request by id, in the background. Used after a manual approval
    and by POST /api/seerr/requests/:id/fulfil, so the HTTP call returns
    immediately instead of waiting for the *arr. *)
let fulfil_in_background (state : App_state.t) (request_id : int) =
  Lwt.async (fun () ->
      Lwt.catch
        (fun () ->
          let cfg = App_state.config state in
          let s = cfg.seerr in
          if not (configured s) then (
            Log_buffer.warnf "seerr: cannot fulfil request #%d: %s" request_id
              (unconfigured_reason s);
            Lwt.return_unit)
          else
            let* r = Seerr.request_by_id ~base_url:s.seerr_url ~api_key:s.seerr_api_key request_id in
            match r with
            | Error e ->
                Log_buffer.warnf "seerr: cannot read request #%d: %s" request_id
                  (Pickarr_arr.Http.error_to_string e);
                Lwt.return_unit
            | Ok r ->
                let cache = title_cache () in
                let* title = title_of_request s cache r in
                let* results = fulfil_request state cfg ?title r in
                sync.last_results <-
                  List.filteri
                    (fun i _ -> i < max_remembered_results)
                    (results @ sync.last_results);
                Lwt.return_unit)
        (fun exn ->
          Log_buffer.errorf "seerr: fulfilment of request #%d failed: %s" request_id
            (Printexc.to_string exn);
          Lwt.return_unit))

(** Approve or decline one request. *)
let set_request_status (state : App_state.t) ~(request_id : int) ~(approve : bool) :
    (Yojson.Safe.t, string) result Lwt.t =
  let cfg = App_state.config state in
  let s = cfg.seerr in
  if not (configured s) then Lwt.return (Error (unconfigured_reason s))
  else
    let base_url = s.seerr_url and api_key = s.seerr_api_key in
    let* updated =
      if approve then Seerr.approve ~base_url ~api_key request_id
      else Seerr.decline ~base_url ~api_key request_id
    in
    match updated with
    | Error e -> Lwt.return (Error (Pickarr_arr.Http.error_to_string e))
    | Ok r ->
        Log_buffer.infof "seerr: request #%d %s" request_id
          (if approve then "approved" else "declined");
        Lwt.return (Ok (request_to_compact r))

(** One page of requests for the UI, enriched with titles. *)
let list_requests (state : App_state.t) ~(filter : Seerr.request_filter) ~(take : int) :
    (Yojson.Safe.t, string) result Lwt.t =
  let cfg = App_state.config state in
  let s = cfg.seerr in
  if not (configured s) then Lwt.return (Error (unconfigured_reason s))
  else
    let* page =
      Seerr.requests ~base_url:s.seerr_url ~api_key:s.seerr_api_key ~filter ~take ~sort:"added"
        ~sort_direction:"desc" ()
    in
    match page with
    | Error e -> Lwt.return (Error (Pickarr_arr.Http.error_to_string e))
    | Ok page ->
        let cache = title_cache () in
        let* items =
          Lwt_list.map_s
            (fun (r : Seerr.request) ->
              let* title = title_of_request s cache r in
              Lwt.return (request_to_compact ?title r))
            page.rp_results
        in
        Lwt.return
          (Ok
             (`Assoc
               [
                 ("filter", `String (Seerr.filter_to_string filter));
                 ("total", `Int page.rp_page_info.pi_results);
                 ("results", `List items);
               ]))

(** Connection test for the saved configuration. *)
let test (state : App_state.t) : (Yojson.Safe.t, string) result Lwt.t =
  let s = (App_state.config state).seerr in
  if String.trim s.seerr_url = "" then Lwt.return (Error "no Seerr URL is configured")
  else if String.trim s.seerr_api_key = "" then Lwt.return (Error "no Seerr API key is configured")
  else
    let* status = Seerr.status ~base_url:s.seerr_url ~api_key:s.seerr_api_key () in
    match status with
    | Error e -> Lwt.return (Error (Pickarr_arr.Http.error_to_string e))
    | Ok st ->
        let* counts = Seerr.request_count ~base_url:s.seerr_url ~api_key:s.seerr_api_key () in
        let pending, processing =
          match counts with Ok c -> (c.ct_pending, c.ct_processing) | Error _ -> (0, 0)
        in
        Lwt.return
          (Ok
             (`Assoc
               [
                 ("ok", `Bool true);
                 ("version", `String st.sv_version);
                 ("update_available", `Bool st.sv_update_available);
                 ("pending", `Int pending);
                 ("processing", `Int processing);
               ]))

(* ------------------------------------------------------------------ *)
(* Status and background loop                                          *)
(* ------------------------------------------------------------------ *)

let status (state : App_state.t) : Yojson.Safe.t =
  let cfg = App_state.config state in
  let s = cfg.seerr in
  `Assoc
    [
      ("enabled", `Bool s.seerr_enabled);
      ("configured", `Bool (configured s));
      ("detail", `String (unconfigured_reason s));
      ("url", `String s.seerr_url);
      ("auto_approve", `Bool s.seerr_auto_approve);
      ("process_approved", `Bool s.seerr_process_approved);
      ("grab", `Bool s.seerr_grab);
      ("interval_seconds", `Int (interval_of cfg));
      ("max_requests_per_run", `Int s.seerr_max_requests_per_run);
      ("runs", `Int sync.runs);
      ("running", `Bool (Lwt_mutex.is_locked sync.mutex));
      ("last_run_at", opt_str sync.last_run_at);
      ("next_run_at", opt_str sync.next_run_at);
      ("last_error", opt_str sync.last_error);
      ("last_approved", `Int sync.last_approved);
      ("last_fulfilled", `Int sync.last_fulfilled);
      ("cooldown_entries", `Int (Hashtbl.length sync.attempted));
      ("last_results", `List sync.last_results);
    ]

(** Start the Seerr poller. Like the automatic scheduler it runs for the
    lifetime of the process and re-reads the configuration every tick, so the
    integration can be switched on and off from the UI without a restart. *)
let start (state : App_state.t) =
  let rec loop () =
    let cfg = App_state.config state in
    let interval = interval_of cfg in
    sync.next_run_at <-
      Some (Automatic.rfc3339_of_unix (Unix.gettimeofday () +. float_of_int interval));
    let* () = Lwt_unix.sleep (float_of_int interval) in
    let cfg = App_state.config state in
    let* () =
      if not (configured cfg.seerr) then Lwt.return_unit
      else
        Lwt.catch
          (fun () -> Lwt.map (fun (_ : Yojson.Safe.t) -> ()) (run_once state))
          (fun exn ->
            let msg = Printexc.to_string exn in
            sync.last_error <- Some msg;
            Log_buffer.errorf "seerr: pass failed: %s" msg;
            Lwt.return_unit)
    in
    loop ()
  in
  Lwt.async (fun () ->
      Lwt.catch loop (fun exn ->
          Log_buffer.errorf "seerr: poller stopped: %s" (Printexc.to_string exn);
          Lwt.return_unit))
