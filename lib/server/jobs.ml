(* STUB (queue-integration worktree) — discard at merge.

   A deliberately small in-memory queue: FIFO, two workers, at most one
   running job per instance, no persistence.  Enough to drive the job kinds
   and the smoke tests until the real module from the queue-core stream is
   merged. *)

let ( let* ) = Lwt.bind

type status = Queued | Running | Succeeded | Failed | Cancelled

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let status_of_string = function
  | "queued" -> Some Queued
  | "running" -> Some Running
  | "succeeded" -> Some Succeeded
  | "failed" -> Some Failed
  | "cancelled" -> Some Cancelled
  | _ -> None

type ctx = {
  job_id : int;
  progress : string -> unit;
  set_label : string -> unit;
  event : ?level:Events.level -> ?data:(string * Yojson.Safe.t) list -> string -> string -> unit;
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
  prep : prepared;
  mutable label_ : string;
  mutable status : status;
  mutable progress_ : string option;
  mutable error : string option;
  mutable result : Yojson.Safe.t option;
  created : float;
  mutable started : float option;
  mutable finished : float option;
  done_ : unit Lwt_condition.t;
  mutable runner : unit Lwt.t option;
}

let kinds : (string, App_state.t -> Yojson.Safe.t -> (prepared, string) result) Hashtbl.t =
  Hashtbl.create 8

let jobs : (int, job) Hashtbl.t = Hashtbl.create 64
let order : int list ref = ref []
let next_id = ref 1
let wakeup = Lwt_condition.create ()
let workers = 2
let per_instance = 1
let running = ref 0

let register kind parser = Hashtbl.replace kinds kind parser

let ts t =
  match Ptime.of_float_s t with Some p -> `String (Ptime.to_rfc3339 ~tz_offset_s:0 p) | None -> `Null

let queued_ids () =
  List.filter (fun id -> (Hashtbl.find jobs id).status = Queued) (List.rev !order)

let to_json ?(include_result = true) (j : job) : Yojson.Safe.t =
  let opt_s = function None -> `Null | Some s -> `String s in
  let position =
    if j.status <> Queued then `Null
    else
      let rec idx i = function
        | [] -> `Null
        | x :: tl -> if x = j.id then `Int i else idx (i + 1) tl
      in
      idx 1 (queued_ids ())
  in
  `Assoc
    ([
       ("id", `Int j.id);
       ("kind", `String j.kind);
       ("status", `String (status_to_string j.status));
       ("label", `String j.label_);
       ("source", `String j.source);
       ("instance_id", opt_s j.prep.instance_id);
       ("params", j.params);
       ("created_at", ts j.created);
       ("started_at", (match j.started with None -> `Null | Some t -> ts t));
       ("finished_at", (match j.finished with None -> `Null | Some t -> ts t));
       ( "duration_ms",
         match (j.started, j.finished) with
         | Some a, Some b -> `Int (int_of_float ((b -. a) *. 1000.))
         | _ -> `Null );
       ("position", position);
       ("progress", opt_s j.progress_);
       ("attempt", `Int 1);
       ("retry_of", `Null);
       ("error", opt_s j.error);
     ]
    @ if include_result then [ ("result", Option.value j.result ~default:`Null) ] else [])

let finished_status = function Succeeded | Failed | Cancelled -> true | _ -> false

let finish (j : job) status ?error ?result () =
  if not (finished_status j.status) then (
    if j.status = Running then decr running;
    j.status <- status;
    j.error <- error;
    j.result <- result;
    j.finished <- Some (Unix.gettimeofday ());
    Lwt_condition.broadcast j.done_ ();
    Lwt_condition.broadcast wakeup ())

let running_on instance =
  Hashtbl.fold
    (fun _ (j : job) acc ->
      if j.status = Running && j.prep.instance_id = Some instance then acc + 1 else acc)
    jobs 0

let runnable () =
  List.find_opt
    (fun id ->
      let j = Hashtbl.find jobs id in
      match j.prep.instance_id with
      | None -> true
      | Some i -> running_on i < per_instance)
    (queued_ids ())

let run_job (j : job) =
  j.status <- Running;
  incr running;
  j.started <- Some (Unix.gettimeofday ());
  let ctx =
    {
      job_id = j.id;
      progress = (fun s -> j.progress_ <- Some s);
      set_label = (fun s -> j.label_ <- s);
      event =
        (fun ?level ?data t m ->
          Events.emit ?level ?data ~job_id:j.id ?instance_id:j.prep.instance_id t m);
    }
  in
  let p =
    Lwt.catch
      (fun () ->
        let* r = j.prep.run ctx in
        (match r with
        | Ok result -> finish j Succeeded ~result ()
        | Error e -> finish j Failed ~error:e ());
        Lwt.return_unit)
      (function
        | Lwt.Canceled ->
            finish j Cancelled ~error:"cancelled" ();
            Lwt.return_unit
        | exn ->
            finish j Failed ~error:(Printexc.to_string exn) ();
            Lwt.return_unit)
  in
  j.runner <- Some p

let started = ref false

let start (_ : App_state.t) =
  if not !started then (
    started := true;
    let rec loop () =
      (if !running < workers then
         match runnable () with Some id -> run_job (Hashtbl.find jobs id) | None -> ());
      let* () =
        if !running < workers && runnable () <> None then Lwt.return_unit
        else Lwt_condition.wait wakeup
      in
      loop ()
    in
    Lwt.async loop)

let enqueue state ?(source = "api") kind params =
  match Hashtbl.find_opt kinds kind with
  | None -> Error (Printf.sprintf "unknown job kind \"%s\"" kind)
  | Some parser -> (
      match parser state params with
      | Error e -> Error e
      | Ok prep -> (
          let existing =
            match prep.dedupe_key with
            | None -> None
            | Some key ->
                Hashtbl.fold
                  (fun _ (j : job) acc ->
                    match acc with
                    | Some _ -> acc
                    | None ->
                        if (j.status = Queued || j.status = Running) && j.prep.dedupe_key = Some key
                        then Some j
                        else None)
                  jobs None
          in
          match existing with
          | Some j -> Ok (to_json ~include_result:false j)
          | None ->
              let id = !next_id in
              incr next_id;
              let j =
                {
                  id;
                  kind;
                  source;
                  params;
                  prep;
                  label_ = prep.label;
                  status = Queued;
                  progress_ = None;
                  error = None;
                  result = None;
                  created = Unix.gettimeofday ();
                  started = None;
                  finished = None;
                  done_ = Lwt_condition.create ();
                  runner = None;
                }
              in
              Hashtbl.replace jobs id j;
              order := id :: !order;
              Lwt_condition.broadcast wakeup ();
              Ok (to_json ~include_result:false j)))

let counts () =
  let c s = Hashtbl.fold (fun _ (j : job) n -> if j.status = s then n + 1 else n) jobs 0 in
  `Assoc
    (List.map (fun s -> (status_to_string s, `Int (c s))) [ Queued; Running; Succeeded; Failed; Cancelled ])

let list ?statuses ?kind ?(limit = 100) ?(include_result = false) () =
  let keep (j : job) =
    (match statuses with None -> true | Some l -> List.mem j.status l)
    && match kind with None -> true | Some k -> j.kind = k
  in
  let selected =
    List.filter_map
      (fun id -> match Hashtbl.find_opt jobs id with Some j when keep j -> Some j | _ -> None)
      !order
  in
  let selected = List.filteri (fun i _ -> i < limit) selected in
  `Assoc
    [ ("jobs", `List (List.map (to_json ~include_result) selected)); ("counts", counts ()) ]

let get id = Option.map (to_json ~include_result:true) (Hashtbl.find_opt jobs id)

let wait id ~timeout =
  match Hashtbl.find_opt jobs id with
  | None -> Lwt.return None
  | Some j ->
      if finished_status j.status then Lwt.return (Some (to_json j))
      else
        let rec until () =
          if finished_status j.status then Lwt.return (Some (to_json j))
          else
            let* () = Lwt_condition.wait j.done_ in
            until ()
        in
        Lwt.pick [ until (); Lwt.map (fun () -> None) (Lwt_unix.sleep timeout) ]

let cancel id =
  match Hashtbl.find_opt jobs id with
  | None -> Error "no such job"
  | Some j -> (
      match j.status with
      | Queued ->
          finish j Cancelled ~error:"cancelled" ();
          Ok (to_json j)
      | Running ->
          (match j.runner with Some p -> Lwt.cancel p | None -> ());
          finish j Cancelled ~error:"cancelled" ();
          Ok (to_json j)
      | _ -> Error "the job has already finished")

let retry state id =
  match Hashtbl.find_opt jobs id with
  | None -> Error "no such job"
  | Some j when j.status = Failed || j.status = Cancelled -> enqueue state ~source:"ui" j.kind j.params
  | Some _ -> Error "only failed or cancelled jobs can be retried"

let clear_finished () =
  let ids =
    Hashtbl.fold (fun id (j : job) acc -> if finished_status j.status then id :: acc else acc) jobs []
  in
  List.iter (Hashtbl.remove jobs) ids;
  order := List.filter (fun id -> not (List.mem id ids)) !order;
  List.length ids
