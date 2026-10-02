(* The server-side job queue.  See jobs.mli for the behaviour.

   All state is process-wide (one queue per process).  Lwt is cooperative,
   so the scheduler's bookkeeping needs no locks: every mutation below runs
   to completion before another promise can observe the state. *)

module Config = Pickarr_core.Config

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Types                                                               *)
(* ------------------------------------------------------------------ *)

type status = Queued | Running | Succeeded | Failed | Cancelled

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let status_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "queued" -> Some Queued
  | "running" -> Some Running
  | "succeeded" -> Some Succeeded
  | "failed" -> Some Failed
  | "cancelled" | "canceled" -> Some Cancelled
  | _ -> None

let is_finished = function Succeeded | Failed | Cancelled -> true | Queued | Running -> false

type ctx = {
  job_id : int;
  progress : string -> unit;
  set_label : string -> unit;
  event :
    ?level:Events.level -> ?data:(string * Yojson.Safe.t) list -> string -> string -> unit;
}

type prepared = {
  label : string;
  instance_id : string option;
  dedupe_key : string option;
  run : ctx -> (Yojson.Safe.t, string) result Lwt.t;
}

type job = {
  id : int;
  kind : string;
  source : string;
  params : Yojson.Safe.t;
  mutable label : string;
  instance_id : string option;
  dedupe_key : string option;
  created_at : float;
  mutable started_at : float option;
  mutable finished_at : float option;
  mutable status : status;
  mutable progress : string option;
  attempt : int;
  retry_of : int option;
  mutable error : string option;
      (** Without any "[ddd] " status prefix; see [error_status]. *)
  mutable error_status : int option;
      (** The HTTP status a failed runner reported through a "[ddd] " prefix
          (lib/server/status_error.ml), for the endpoints that wait on a job. *)
  mutable result : Yojson.Safe.t option;
  mutable run : (ctx -> (Yojson.Safe.t, string) result Lwt.t) option;
      (** Present while queued; dropped once the job has started. *)
  mutable runner : (Yojson.Safe.t, string) result Lwt.t option;
      (** The running promise, for cancellation. *)
  mutable last_progress_event : float;
}

(* ------------------------------------------------------------------ *)
(* State                                                               *)
(* ------------------------------------------------------------------ *)

let kinds : (string, App_state.t -> Yojson.Safe.t -> (prepared, string) result) Hashtbl.t =
  Hashtbl.create 16

let jobs : (int, job) Hashtbl.t = Hashtbl.create 64
let next_id = ref 1
let app : App_state.t option ref = ref None
let started = ref false

(* Bumped by [reset_for_tests]: dispatcher loops, savers and runners of an
   older generation stop touching the state. *)
let generation = ref 0

let wake : unit Lwt_condition.t = Lwt_condition.create ()
let need_pump = ref false
let finished_cond : int Lwt_condition.t = Lwt_condition.create ()

(* Persistence *)
let snapshot_file = "jobs.json"
let dirty = ref false
let saving = ref false
let last_save = ref 0.

(* Finished jobs whose result is written to jobs.json: results can be large
   (a selection with all its candidates), so only the newest are kept across
   a restart. *)
let persisted_results = 50

let register kind parse = Hashtbl.replace kinds kind parse
let is_registered kind = Hashtbl.mem kinds kind
let now () = Unix.gettimeofday ()

let queue_config () =
  match !app with Some s -> (App_state.config s).Config.queue | None -> Config.default_queue

(* Ascending by id = FIFO order. *)
let sorted_jobs () =
  Hashtbl.fold (fun _ j acc -> j :: acc) jobs []
  |> List.sort (fun (a : job) (b : job) -> compare a.id b.id)

(* ------------------------------------------------------------------ *)
(* JSON                                                                *)
(* ------------------------------------------------------------------ *)

let ts_of_unix (f : float) : Yojson.Safe.t =
  match Ptime.of_float_s f with
  | Some t -> `String (Ptime.to_rfc3339 ~tz_offset_s:0 t)
  | None -> `Null

let opt_ts = function None -> `Null | Some f -> ts_of_unix f
let opt_string = function None -> `Null | Some s -> `String s
let opt_int = function None -> `Null | Some i -> `Int i
let opt_float = function None -> `Null | Some f -> `Float f

(* 1-based place among the queued jobs. *)
let position (j : job) =
  if j.status <> Queued then None
  else
    Some
      (Hashtbl.fold
         (fun _ (o : job) n -> if o.status = Queued && o.id < j.id then n + 1 else n)
         jobs 1)

let duration_ms (j : job) =
  match (j.started_at, j.finished_at) with
  | Some s, Some f -> Some (int_of_float (Float.round ((f -. s) *. 1000.)))
  | Some s, None when j.status = Running -> Some (int_of_float (Float.round ((now () -. s) *. 1000.)))
  | _ -> None

let job_to_json ?(include_result = true) (j : job) : Yojson.Safe.t =
  `Assoc
    ([
       ("id", `Int j.id);
       ("kind", `String j.kind);
       ("status", `String (status_to_string j.status));
       ("label", `String j.label);
       ("source", `String j.source);
       ("instance_id", opt_string j.instance_id);
       ("params", j.params);
       ("created_at", ts_of_unix j.created_at);
       ("started_at", opt_ts j.started_at);
       ("finished_at", opt_ts j.finished_at);
       ("duration_ms", opt_int (duration_ms j));
       ("position", opt_int (position j));
       ("progress", opt_string j.progress);
       ("attempt", `Int j.attempt);
       ("retry_of", opt_int j.retry_of);
       ("error", opt_string j.error);
       ("error_status", opt_int j.error_status);
     ]
    @ if include_result then [ ("result", match j.result with Some r -> r | None -> `Null) ] else [])

let counts () : Yojson.Safe.t =
  let c = Hashtbl.create 5 in
  Hashtbl.iter
    (fun _ (j : job) ->
      let k = status_to_string j.status in
      Hashtbl.replace c k (1 + Option.value ~default:0 (Hashtbl.find_opt c k)))
    jobs;
  `Assoc
    (List.map
       (fun s ->
         let k = status_to_string s in
         (k, `Int (Option.value ~default:0 (Hashtbl.find_opt c k))))
       [ Queued; Running; Succeeded; Failed; Cancelled ])

(* ------------------------------------------------------------------ *)
(* Events                                                              *)
(* ------------------------------------------------------------------ *)

let job_event ?(level = Events.Info) ?(data = []) (j : job) typ message =
  Events.emit ~level ~job_id:j.id ?instance_id:j.instance_id
    ~data:
      ([ ("kind", `String j.kind); ("label", `String j.label); ("source", `String j.source) ]
      @ data)
    typ message

let seconds (j : job) =
  match duration_ms j with
  | Some ms -> Printf.sprintf " (%.1f s)" (float_of_int ms /. 1000.)
  | None -> ""

(* ------------------------------------------------------------------ *)
(* Persistence                                                         *)
(* ------------------------------------------------------------------ *)

let data_dir () = Option.map (fun s -> Store.data_dir s.App_state.store) !app

let snapshot () : string =
  let all = sorted_jobs () in
  (* The newest finished jobs keep their result. *)
  let finished_newest =
    List.filter (fun (j : job) -> is_finished j.status) all
    |> List.rev
    |> List.filteri (fun i _ -> i < persisted_results)
    |> List.map (fun (j : job) -> j.id)
  in
  let job_json (j : job) =
    let keep_result = List.mem j.id finished_newest in
    match job_to_json ~include_result:keep_result j with
    | `Assoc fields ->
        `Assoc
          (fields
          @ [
              ("dedupe_key", opt_string j.dedupe_key);
              ("created_unix", `Float j.created_at);
              ("started_unix", opt_float j.started_at);
              ("finished_unix", opt_float j.finished_at);
            ])
    | other -> other
  in
  Yojson.Safe.to_string
    (`Assoc
      [ ("version", `Int 1); ("next_id", `Int !next_id); ("jobs", `List (List.map job_json all)) ])

let tmp_counter = ref 0

let write_snapshot () =
  match data_dir () with
  | None -> Lwt.return_unit
  | Some dir ->
      let path = Filename.concat dir snapshot_file in
      (* A unique temp name: [flush] may write while a debounced save is in
         flight, and the two must not share a temp file. *)
      incr tmp_counter;
      let tmp = Printf.sprintf "%s.%d.tmp" path !tmp_counter in
      let contents = snapshot () in
      Lwt.catch
        (fun () ->
          let* () =
            Lwt_io.with_file ~mode:Lwt_io.Output ~flags:[ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
              tmp (fun oc -> Lwt_io.write oc contents)
          in
          Lwt_unix.rename tmp path)
        (fun exn ->
          Log_buffer.debugf "cannot write %s: %s" path (Printexc.to_string exn);
          Lwt.return_unit)

(* Debounced: at most one write per second; the latest state always ends up
   on disk. *)
let rec schedule_save () =
  dirty := true;
  if (not !saving) && !app <> None then (
    saving := true;
    let gen = !generation in
    Lwt.async (fun () ->
        Lwt.catch
          (fun () ->
            let wait = Float.max 0. (!last_save +. 1.0 -. now ()) in
            let* () = Lwt_unix.sleep wait in
            if gen <> !generation then (
              saving := false;
              Lwt.return_unit)
            else (
              dirty := false;
              let* () = write_snapshot () in
              last_save := now ();
              saving := false;
              if !dirty then schedule_save ();
              Lwt.return_unit))
          (fun _ ->
            saving := false;
            Lwt.return_unit)))

let flush () =
  if !dirty || !saving then (
    dirty := false;
    let* () = write_snapshot () in
    last_save := now ();
    Lwt.return_unit)
  else Lwt.return_unit

(* ------------------------------------------------------------------ *)
(* Scheduling                                                          *)
(* ------------------------------------------------------------------ *)

let request_pump () =
  need_pump := true;
  Lwt_condition.signal wake ()

(* Drop the oldest finished jobs beyond [queue_keep_finished]. *)
let trim () =
  let keep = (queue_config ()).Config.queue_keep_finished in
  let finished =
    sorted_jobs () |> List.filter (fun (j : job) -> is_finished j.status) |> List.rev
  in
  List.iteri (fun i (j : job) -> if i >= keep then Hashtbl.remove jobs j.id) finished

(* Shared tail of every transition to a finished state. *)
let after_finish (j : job) =
  j.run <- None;
  j.runner <- None;
  Lwt_condition.broadcast finished_cond j.id;
  trim ();
  schedule_save ();
  request_pump ()

let on_done (j : job) outcome =
  if j.status = Running then (
    j.finished_at <- Some (now ());
    (match outcome with
    | `Ok result ->
        j.status <- Succeeded;
        j.result <- Some result;
        job_event j "job.succeeded" (Printf.sprintf "Done: %s%s" j.label (seconds j))
    | `Error raw ->
        let status, message = Status_error.split raw in
        j.status <- Failed;
        j.error <- Some message;
        j.error_status <- status;
        Log_buffer.infof "job #%d (%s) failed: %s" j.id j.label message;
        job_event ~level:Events.Error
          ~data:[ ("error", `String message); ("error_status", opt_int status) ]
          j "job.failed"
          (Printf.sprintf "Failed: %s: %s" j.label message)
    | `Cancelled ->
        j.status <- Cancelled;
        j.error <- Some "cancelled while running";
        job_event ~level:Events.Warn j "job.cancelled" (Printf.sprintf "Cancelled: %s" j.label));
    after_finish j)

let make_ctx (j : job) : ctx =
  {
    job_id = j.id;
    progress =
      (fun message ->
        if j.status = Running then (
          j.progress <- Some message;
          let t = now () in
          if t -. j.last_progress_event >= 1.0 then (
            j.last_progress_event <- t;
            job_event j "job.progress" message);
          schedule_save ()));
    set_label =
      (fun label ->
        if String.trim label <> "" then (
          j.label <- label;
          schedule_save ()));
    event =
      (fun ?level ?data typ message ->
        Events.emit ?level ~job_id:j.id ?instance_id:j.instance_id ?data typ message);
  }

let start_job (j : job) =
  match j.run with
  | None ->
      (* Only a queued job restored without a runner could get here. *)
      j.status <- Running;
      j.started_at <- Some (now ());
      on_done j (`Error "job has nothing to run")
  | Some run ->
      j.status <- Running;
      j.started_at <- Some (now ());
      j.progress <- None;
      j.run <- None;
      job_event j "job.started" (Printf.sprintf "Started: %s" j.label);
      schedule_save ();
      let gen = !generation in
      let p =
        Lwt.catch
          (fun () -> run (make_ctx j))
          (function
            | Lwt.Canceled -> Lwt.fail Lwt.Canceled
            | exn -> Lwt.return (Error (Printexc.to_string exn)))
      in
      j.runner <- Some p;
      Lwt.on_any p
        (fun r ->
          if gen = !generation then
            on_done j (match r with Ok v -> `Ok v | Error e -> `Error e))
        (fun exn ->
          if gen = !generation then
            on_done j
              (match exn with
              | Lwt.Canceled -> `Cancelled
              | e -> `Error (Printexc.to_string e)))

(* Start every queued job the limits allow, oldest first.  A job held back by
   its instance limit does not hold back later jobs for other instances. *)
let pump () =
  if !started then (
    let q = queue_config () in
    let all = sorted_jobs () in
    let running_total = ref 0 in
    let per_instance : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let count_of i = Option.value ~default:0 (Hashtbl.find_opt per_instance i) in
    List.iter
      (fun (j : job) ->
        if j.status = Running then (
          incr running_total;
          match j.instance_id with
          | Some i -> Hashtbl.replace per_instance i (count_of i + 1)
          | None -> ()))
      all;
    List.iter
      (fun (j : job) ->
        if j.status = Queued && !running_total < q.Config.queue_workers then
          let allowed =
            match j.instance_id with
            | None -> true
            | Some i -> count_of i < q.Config.queue_per_instance
          in
          if allowed then (
            incr running_total;
            (match j.instance_id with
            | Some i -> Hashtbl.replace per_instance i (count_of i + 1)
            | None -> ());
            start_job j))
      all)

(* The dispatcher: wakes on enqueue/finish/cancel, and once a second so a
   config change (more workers) applies without any other trigger. *)
let rec dispatcher gen =
  if gen <> !generation then Lwt.return_unit
  else (
    need_pump := false;
    pump ();
    if !need_pump then
      let* () = Lwt.pause () in
      dispatcher gen
    else
      let* () =
        Lwt.pick [ Lwt_condition.wait wake; Lwt_unix.sleep 1.0 ]
      in
      dispatcher gen)

(* ------------------------------------------------------------------ *)
(* Enqueue                                                             *)
(* ------------------------------------------------------------------ *)

let find_active_by_key key =
  Hashtbl.fold
    (fun _ (j : job) acc ->
      match acc with
      | Some _ -> acc
      | None ->
          if (j.status = Queued || j.status = Running) && j.dedupe_key = Some key then Some j
          else None)
    jobs None

let add_job ~kind ~source ~params ~attempt ~retry_of (p : prepared) : job =
  let id = !next_id in
  incr next_id;
  let j =
    {
      id;
      kind;
      source;
      params;
      label = p.label;
      instance_id = p.instance_id;
      dedupe_key = p.dedupe_key;
      created_at = now ();
      started_at = None;
      finished_at = None;
      status = Queued;
      progress = None;
      attempt;
      retry_of;
      error = None;
      error_status = None;
      result = None;
      run = Some p.run;
      runner = None;
      last_progress_event = 0.;
    }
  in
  Hashtbl.replace jobs id j;
  job_event
    ~data:[ ("position", opt_int (position j)) ]
    j "job.queued"
    (Printf.sprintf "Queued: %s" j.label);
  schedule_save ();
  request_pump ();
  j

let prepare state kind params =
  match Hashtbl.find_opt kinds kind with
  | None -> Error (Printf.sprintf "unknown job kind %S" kind)
  | Some parse -> (
      try parse state params
      with exn -> Error (Printf.sprintf "invalid params for %s: %s" kind (Printexc.to_string exn)))

let submit state ~kind ~source ~params ~attempt ~retry_of =
  if !app = None then app := Some state;
  match prepare state kind params with
  | Error e -> Error e
  | Ok p -> (
      match Option.bind p.dedupe_key find_active_by_key with
      | Some existing -> Ok (job_to_json existing)
      | None -> Ok (job_to_json (add_job ~kind ~source ~params ~attempt ~retry_of p)))

let enqueue state ?(source = "api") kind params =
  let source = if String.trim source = "" then "api" else String.trim source in
  submit state ~kind ~source ~params ~attempt:1 ~retry_of:None

(* ------------------------------------------------------------------ *)
(* Queries and actions                                                 *)
(* ------------------------------------------------------------------ *)

let list ?statuses ?kind ?(limit = 100) ?(include_result = false) () =
  let limit = max 1 (min 5000 limit) in
  let selected =
    sorted_jobs () |> List.rev
    |> List.filter (fun (j : job) ->
           (match statuses with Some (_ :: _ as l) -> List.mem j.status l | _ -> true)
           && match kind with Some k when String.trim k <> "" -> j.kind = k | _ -> true)
    |> List.filteri (fun i _ -> i < limit)
  in
  `Assoc
    [
      ("jobs", `List (List.map (job_to_json ~include_result) selected));
      ("counts", counts ());
    ]

let get id = Option.map (job_to_json ~include_result:true) (Hashtbl.find_opt jobs id)

let wait id ~timeout =
  match Hashtbl.find_opt jobs id with
  | None -> Lwt.return_none
  | Some j when is_finished j.status -> Lwt.return (get id)
  | Some _ ->
      let rec until_finished () =
        let* finished_id = Lwt_condition.wait finished_cond in
        if finished_id = id then Lwt.return_unit else until_finished ()
      in
      let* finished =
        Lwt.pick
          [
            (let* () = until_finished () in
             Lwt.return true);
            (let* () = Lwt_unix.sleep (Float.max 0. timeout) in
             Lwt.return false);
          ]
      in
      Lwt.return (if finished then get id else None)

let cancel id =
  match Hashtbl.find_opt jobs id with
  | None -> Error (Printf.sprintf "no job %d" id)
  | Some j -> (
      match j.status with
      | Queued ->
          j.status <- Cancelled;
          j.finished_at <- Some (now ());
          j.error <- Some "cancelled before it started";
          job_event ~level:Events.Warn j "job.cancelled" (Printf.sprintf "Cancelled: %s" j.label);
          after_finish j;
          Ok (job_to_json j)
      | Running ->
          (match j.runner with Some p -> Lwt.cancel p | None -> ());
          (* A runner that ignores cancellation must not keep the job (and its
             worker slot) "running": mark it cancelled now and ignore its
             eventual result. *)
          if j.status = Running then on_done j `Cancelled;
          Ok (job_to_json j)
      | Succeeded | Failed | Cancelled ->
          Error (Printf.sprintf "job %d has already %s" id (status_to_string j.status)))

let retry state id =
  match Hashtbl.find_opt jobs id with
  | None -> Error (Printf.sprintf "no job %d" id)
  | Some j -> (
      match j.status with
      | Failed | Cancelled ->
          submit state ~kind:j.kind ~source:"ui" ~params:j.params ~attempt:(j.attempt + 1)
            ~retry_of:(Some j.id)
      | other ->
          Error
            (Printf.sprintf "only failed or cancelled jobs can be retried (job %d is %s)" id
               (status_to_string other)))

let clear_finished () =
  let ids =
    Hashtbl.fold (fun id (j : job) acc -> if is_finished j.status then id :: acc else acc) jobs []
  in
  List.iter (Hashtbl.remove jobs) ids;
  if ids <> [] then schedule_save ();
  List.length ids

(* ------------------------------------------------------------------ *)
(* Restart                                                             *)
(* ------------------------------------------------------------------ *)

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None
let str k j = match member k j with Some (`String s) -> Some s | _ -> None
let int k j = match member k j with Some (`Int i) -> Some i | _ -> None

let float k j =
  match member k j with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let load state =
  match data_dir () with
  | None -> ()
  | Some dir -> (
      let path = Filename.concat dir snapshot_file in
      let json =
        try
          if Sys.file_exists path then
            Some (Yojson.Safe.from_string (In_channel.with_open_bin path In_channel.input_all))
          else None
        with exn ->
          Log_buffer.warnf "ignoring unreadable %s: %s" path (Printexc.to_string exn);
          None
      in
      match json with
      | None -> ()
      | Some json ->
          let restored = ref 0 and interrupted = ref 0 in
          (match member "jobs" json with
          | Some (`List items) ->
              List.iter
                (fun item ->
                  match (int "id" item, str "kind" item, Option.bind (str "status" item) status_of_string) with
                  | Some id, Some kind, Some status when not (Hashtbl.mem jobs id) ->
                      let params = Option.value ~default:`Null (member "params" item) in
                      let j =
                        {
                          id;
                          kind;
                          source = Option.value ~default:"api" (str "source" item);
                          params;
                          label = Option.value ~default:kind (str "label" item);
                          instance_id = str "instance_id" item;
                          dedupe_key = str "dedupe_key" item;
                          created_at = Option.value ~default:(now ()) (float "created_unix" item);
                          started_at = float "started_unix" item;
                          finished_at = float "finished_unix" item;
                          status;
                          progress = str "progress" item;
                          attempt = Option.value ~default:1 (int "attempt" item);
                          retry_of = int "retry_of" item;
                          (* Jobs written before "error_status" existed may
                             still carry the prefix on "error". *)
                          error = Option.map (fun e -> snd (Status_error.split e)) (str "error" item);
                          error_status =
                            (match int "error_status" item with
                            | Some s -> Some s
                            | None -> Option.bind (str "error" item) (fun e -> fst (Status_error.split e)));
                          result =
                            (match member "result" item with
                            | None | Some `Null -> None
                            | Some r -> Some r);
                          run = None;
                          runner = None;
                          last_progress_event = 0.;
                        }
                      in
                      Hashtbl.replace jobs id j;
                      next_id := max !next_id (id + 1);
                      (match status with
                      | Running ->
                          incr interrupted;
                          j.status <- Failed;
                          j.finished_at <- Some (now ());
                          j.error <- Some "interrupted by restart";
                          job_event ~level:Events.Warn j "job.interrupted"
                            (Printf.sprintf "Interrupted by restart: %s" j.label)
                      | Queued -> (
                          incr restored;
                          match prepare state kind params with
                          | Ok p -> j.run <- Some p.run
                          | Error raw ->
                              let status, e = Status_error.split raw in
                              j.status <- Failed;
                              j.finished_at <- Some (now ());
                              j.error <- Some ("could not be restarted: " ^ e);
                              j.error_status <- status;
                              job_event ~level:Events.Error j "job.failed"
                                (Printf.sprintf "Failed: %s: could not be restarted: %s" j.label e))
                      | Succeeded | Failed | Cancelled -> ())
                  | _ -> ())
                items
          | _ -> ());
          (match int "next_id" json with Some n -> next_id := max !next_id n | None -> ());
          if !restored > 0 || !interrupted > 0 then
            Log_buffer.infof "job queue: %d queued job(s) restored, %d interrupted by the restart"
              !restored !interrupted)

(* ------------------------------------------------------------------ *)
(* Test kind                                                           *)
(* ------------------------------------------------------------------ *)

let test_sleep_kind (_ : App_state.t) (params : Yojson.Safe.t) : (prepared, string) result =
  let bool_param k = match member k params with Some (`Bool b) -> Ok b | None | Some `Null -> Ok false | Some _ -> Error (k ^ " must be a boolean") in
  let ms =
    match member "ms" params with
    | None | Some `Null -> Ok 100
    | Some (`Int i) -> Ok (max 0 (min 600_000 i))
    | Some _ -> Error "ms must be an integer"
  in
  match (ms, bool_param "fail", bool_param "raise") with
  | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e
  | Ok ms, Ok fail, Ok raise_ ->
      Ok
        {
          label = Printf.sprintf "Test sleep · %d ms" ms;
          instance_id = str "instance_id" params;
          dedupe_key = Option.map (fun d -> "test_sleep:" ^ d) (str "dedupe" params);
          run =
            (fun ctx ->
              ctx.progress (Printf.sprintf "sleeping %d ms" ms);
              let* () = Lwt_unix.sleep (float_of_int ms /. 1000.) in
              if raise_ then failwith "test runner raised"
              else if fail then Lwt.return (Error "test failure requested")
              else Lwt.return (Ok (`Assoc [ ("slept_ms", `Int ms) ])));
        }

(* ------------------------------------------------------------------ *)
(* Start / reset                                                       *)
(* ------------------------------------------------------------------ *)

let start state =
  if not !started then (
    started := true;
    app := Some state;
    if Sys.getenv_opt "PICKARR_TEST_JOBS" = Some "1" then register "test_sleep" test_sleep_kind;
    load state;
    trim ();
    schedule_save ();
    let gen = !generation in
    Lwt.async (fun () ->
        Lwt.catch
          (fun () -> dispatcher gen)
          (fun exn ->
            Log_buffer.errorf "job dispatcher stopped: %s" (Printexc.to_string exn);
            Lwt.return_unit)))

let reset_for_tests () =
  incr generation;
  Hashtbl.iter (fun _ (j : job) -> match j.runner with Some p -> Lwt.cancel p | None -> ()) jobs;
  Hashtbl.reset jobs;
  next_id := 1;
  started := false;
  app := None;
  dirty := false;
  saving := false;
  last_save := 0.;
  need_pump := false;
  (* Release a dispatcher waiting on the old generation. *)
  Lwt_condition.broadcast wake ()
