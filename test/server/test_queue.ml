(* Tests for the job queue (Jobs) and the structured event log (Events).

   Both modules hold process-wide state, so every test starts with
   [fresh ()]: a new temp data dir, Events.init on it, Jobs.reset_for_tests
   and a new App_state with the queue limits under test. *)

module Config = Pickarr_core.Config
module Store = Pickarr_server.Store
module Auth = Pickarr_server.Auth
module App_state = Pickarr_server.App_state
module Jobs = Pickarr_server.Jobs
module Events = Pickarr_server.Events

let ( let* ) = Lwt.bind
let run = Lwt_main.run

let temp_dir prefix =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.int 1_000_000_000))
  in
  Unix.mkdir dir 0o755;
  dir

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None

let str k j =
  match member k j with Some (`String s) -> s | _ -> Alcotest.failf "missing string %s" k

let int k j = match member k j with Some (`Int i) -> i | _ -> Alcotest.failf "missing int %s" k
let status j = str "status" j
let opt_int k j = match member k j with Some (`Int i) -> Some i | _ -> None

let state_of ?(queue = Config.default_queue) dir =
  let store =
    match run (Store.create ~data_dir:dir ~getenv:(fun _ -> None) ()) with
    | Ok s -> s
    | Error e -> Alcotest.failf "store: %s" e
  in
  (match run (Store.update store (fun c -> Ok { c with Config.queue })) with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "config: %s" e);
  let auth =
    match run (Auth.create ~getenv:(fun _ -> None) ~data_dir:dir ()) with
    | Ok a -> a
    | Error e -> Alcotest.failf "auth: %s" e
  in
  App_state.create ~getenv:(fun _ -> None) store auth

(* ------------------------------------------------------------------ *)
(* A fake job kind                                                     *)
(* ------------------------------------------------------------------ *)

(* Observations made by the fake runner. *)
let started_order : string list ref = ref []
let running_now = ref 0
let max_running = ref 0
let running_per_instance : (string, int) Hashtbl.t = Hashtbl.create 4
let max_per_instance : (string, int) Hashtbl.t = Hashtbl.create 4
let finished_order : string list ref = ref []

let reset_observations () =
  started_order := [];
  finished_order := [];
  running_now := 0;
  max_running := 0;
  Hashtbl.reset running_per_instance;
  Hashtbl.reset max_per_instance

let bump_instance inst delta =
  let v = delta + Option.value ~default:0 (Hashtbl.find_opt running_per_instance inst) in
  Hashtbl.replace running_per_instance inst v;
  if v > Option.value ~default:0 (Hashtbl.find_opt max_per_instance inst) then
    Hashtbl.replace max_per_instance inst v

(* params: {tag, ms?, outcome?: ok|fail|raise|hang|progress, instance_id?, dedupe?} *)
let fake_kind (_ : App_state.t) (params : Yojson.Safe.t) : (Jobs.prepared, string) result =
  let s k = match member k params with Some (`String v) -> Some v | _ -> None in
  match s "tag" with
  | None -> Error "tag is required"
  | Some tag ->
      let ms = match member "ms" params with Some (`Int i) -> i | _ -> 20 in
      let outcome = Option.value ~default:"ok" (s "outcome") in
      let instance_id = s "instance_id" in
      Ok
        {
          Jobs.label = "Fake · " ^ tag;
          instance_id;
          dedupe_key = Option.map (fun d -> "fake:" ^ d) (s "dedupe");
          run =
            (fun ctx ->
              started_order := tag :: !started_order;
              incr running_now;
              if !running_now > !max_running then max_running := !running_now;
              Option.iter (fun i -> bump_instance i 1) instance_id;
              let finish () =
                decr running_now;
                Option.iter (fun i -> bump_instance i (-1)) instance_id;
                finished_order := tag :: !finished_order
              in
              let body () =
                match outcome with
                | "hang" ->
                    (* Not cancelable: Lwt.wait promises ignore Lwt.cancel. *)
                    let p, _ = Lwt.wait () in
                    p
                | "progress" ->
                    for i = 1 to 10 do
                      ctx.Jobs.progress (Printf.sprintf "step %d" i)
                    done;
                    ctx.Jobs.set_label ("Fake · renamed " ^ tag);
                    ctx.Jobs.event "fake.custom" "custom event";
                    Lwt.return (Ok (`Assoc [ ("tag", `String tag) ]))
                | _ -> (
                    let* () = Lwt_unix.sleep (float_of_int ms /. 1000.) in
                    match outcome with
                    | "fail" -> Lwt.return (Error ("fake failure " ^ tag))
                    | "fail502" ->
                        (* A runner reporting the HTTP status of its failure
                           (lib/server/status_error.ml). *)
                        Lwt.return (Error ("[502] Radarr: release search failed for " ^ tag))
                    | "raise" -> failwith ("boom " ^ tag)
                    | _ -> Lwt.return (Ok (`Assoc [ ("tag", `String tag) ])))
              in
              Lwt.finalize body (fun () ->
                  finish ();
                  Lwt.return_unit));
        }

let () = Jobs.register "fake" fake_kind

let fresh ?queue () =
  Jobs.reset_for_tests ();
  reset_observations ();
  let dir = temp_dir "pickarr-queue" in
  run (Events.init ~data_dir:dir);
  let state = state_of ?queue dir in
  Jobs.start state;
  (dir, state)

let params ?ms ?outcome ?instance_id ?dedupe tag : Yojson.Safe.t =
  `Assoc
    ([ ("tag", `String tag) ]
    @ (match ms with Some m -> [ ("ms", `Int m) ] | None -> [])
    @ (match outcome with Some o -> [ ("outcome", `String o) ] | None -> [])
    @ (match instance_id with Some i -> [ ("instance_id", `String i) ] | None -> [])
    @ match dedupe with Some d -> [ ("dedupe", `String d) ] | None -> [])

let enqueue state ?source p =
  match Jobs.enqueue state ?source "fake" p with
  | Ok j -> int "id" j
  | Error e -> Alcotest.failf "enqueue failed: %s" e

let wait_done id =
  match run (Jobs.wait id ~timeout:10.) with
  | Some j -> j
  | None -> Alcotest.failf "job %d did not finish" id

let get id = match Jobs.get id with Some j -> j | None -> Alcotest.failf "no job %d" id
let sleep s = run (Lwt_unix.sleep s)
let queue ?(workers = 2) ?(per_instance = 1) ?(keep = 500) () =
  { Config.queue_workers = workers; queue_per_instance = per_instance; queue_keep_finished = keep }

(* ------------------------------------------------------------------ *)
(* Jobs                                                                *)
(* ------------------------------------------------------------------ *)

let test_fifo_single_worker () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let ids = List.map (fun t -> enqueue state (params ~ms:30 t)) [ "a"; "b"; "c"; "d" ] in
  List.iter (fun id -> ignore (wait_done id)) ids;
  Alcotest.(check (list string)) "FIFO order" [ "a"; "b"; "c"; "d" ] (List.rev !started_order);
  Alcotest.(check int) "never more than one running" 1 !max_running;
  List.iter (fun id -> Alcotest.(check string) "succeeded" "succeeded" (status (get id))) ids

let test_workers_limit () =
  let _, state = fresh ~queue:(queue ~workers:2 ()) () in
  let ids = List.map (fun t -> enqueue state (params ~ms:80 t)) [ "a"; "b"; "c"; "d"; "e" ] in
  List.iter (fun id -> ignore (wait_done id)) ids;
  Alcotest.(check int) "two at a time" 2 !max_running;
  Alcotest.(check (list string)) "started in FIFO order" [ "a"; "b"; "c"; "d"; "e" ]
    (List.rev !started_order)

let test_per_instance_limit () =
  let _, state = fresh ~queue:(queue ~workers:3 ~per_instance:1 ()) () in
  let a1 = enqueue state (params ~ms:300 ~instance_id:"a" "a1") in
  let a2 = enqueue state (params ~ms:20 ~instance_id:"a" "a2") in
  let b1 = enqueue state (params ~ms:20 ~instance_id:"b" "b1") in
  sleep 0.1;
  Alcotest.(check string) "a2 waits for a1" "queued" (status (get a2));
  Alcotest.(check (option int)) "a2 is first in the queue" (Some 1) (opt_int "position" (get a2));
  ignore (wait_done b1);
  Alcotest.(check string) "a1 still running when b1 is done" "running" (status (get a1));
  ignore (wait_done a2);
  Alcotest.(check (list string)) "b1 was not blocked by a's limit" [ "a1"; "b1"; "a2" ]
    (List.rev !started_order);
  Alcotest.(check (option int)) "never two on instance a" (Some 1)
    (Hashtbl.find_opt max_per_instance "a")

let test_positions_and_counts () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let long = enqueue state (params ~ms:400 "long") in
  let q1 = enqueue state (params ~ms:10 "q1") in
  let q2 = enqueue state (params ~ms:10 "q2") in
  let q3 = enqueue state (params ~ms:10 "q3") in
  sleep 0.05;
  Alcotest.(check string) "long runs" "running" (status (get long));
  Alcotest.(check (option int)) "no position while running" None (opt_int "position" (get long));
  Alcotest.(check (list (option int))) "positions" [ Some 1; Some 2; Some 3 ]
    (List.map (fun id -> opt_int "position" (get id)) [ q1; q2; q3 ]);
  let counts = member "counts" (Jobs.list ()) |> Option.get in
  Alcotest.(check int) "queued count" 3 (int "queued" counts);
  Alcotest.(check int) "running count" 1 (int "running" counts);
  (match Jobs.cancel q1 with Ok j -> Alcotest.(check string) "cancelled" "cancelled" (status j) | Error e -> Alcotest.fail e);
  Alcotest.(check (list (option int))) "positions recomputed" [ Some 1; Some 2 ]
    (List.map (fun id -> opt_int "position" (get id)) [ q2; q3 ]);
  ignore (wait_done q3);
  Alcotest.(check bool) "cancelled job never started" false (List.mem "q1" !started_order)

let test_dedupe () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let first = enqueue state (params ~ms:100 ~dedupe:"k" "x") in
  let again = enqueue state (params ~ms:100 ~dedupe:"k" "x") in
  Alcotest.(check int) "same job while active" first again;
  let other = enqueue state (params ~ms:10 ~dedupe:"other" "y") in
  Alcotest.(check bool) "different key, new job" true (other <> first);
  ignore (wait_done first);
  ignore (wait_done other);
  let later = enqueue state (params ~ms:10 ~dedupe:"k" "x") in
  Alcotest.(check bool) "new job once the first finished" true (later <> first);
  ignore (wait_done later)

let test_cancel_running () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let sleeper = enqueue state (params ~ms:5000 "sleeper") in
  let next = enqueue state (params ~ms:10 "next") in
  sleep 0.05;
  Alcotest.(check string) "running" "running" (status (get sleeper));
  (match Jobs.cancel sleeper with
  | Ok j -> Alcotest.(check string) "cancelled at once" "cancelled" (status j)
  | Error e -> Alcotest.fail e);
  ignore (wait_done next);
  Alcotest.(check string) "next job ran" "succeeded" (status (get next));
  Alcotest.(check int) "runner was really cancelled (finaliser ran)" 0 !running_now;
  match Jobs.cancel sleeper with
  | Ok _ -> Alcotest.fail "cancelling a finished job must fail"
  | Error _ -> ()

let test_cancel_uncancelable_runner () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let hang = enqueue state (params ~outcome:"hang" "hang") in
  let next = enqueue state (params ~ms:10 "next") in
  sleep 0.05;
  (match Jobs.cancel hang with
  | Ok j -> Alcotest.(check string) "cancelled even though the runner ignores it" "cancelled" (status j)
  | Error e -> Alcotest.fail e);
  ignore (wait_done next);
  Alcotest.(check string) "slot was freed" "succeeded" (status (get next));
  Alcotest.(check string) "still cancelled" "cancelled" (status (get hang))

let test_fail_and_raise () =
  let _, state = fresh () in
  let f = enqueue state (params ~outcome:"fail" "f") in
  let r = enqueue state (params ~outcome:"raise" "r") in
  let fj = wait_done f and rj = wait_done r in
  Alcotest.(check string) "fail -> failed" "failed" (status fj);
  Alcotest.(check string) "error message" "fake failure f" (str "error" fj);
  Alcotest.(check string) "raise -> failed" "failed" (status rj);
  Alcotest.(check bool) "exception text kept" true
    (let e = str "error" rj in
     let n = String.length "boom r" in
     let rec go i = i + n <= String.length e && (String.sub e i n = "boom r" || go (i + 1)) in
     go 0)

(* A failed runner's "[ddd] " prefix becomes "error_status"; "error" is
   served (and persisted) without it, and the sync endpoints read the status
   back through Responses.job_error_status. *)
let test_error_status () =
  let dir, state = fresh () in
  let f = enqueue state (params ~outcome:"fail502" "Come and See") in
  let plain = enqueue state (params ~outcome:"fail" "p") in
  let fj = wait_done f and pj = wait_done plain in
  Alcotest.(check string) "failed" "failed" (status fj);
  Alcotest.(check string) "error without the prefix"
    "Radarr: release search failed for Come and See" (str "error" fj);
  Alcotest.(check (option int)) "error_status" (Some 502) (opt_int "error_status" fj);
  Alcotest.(check (option int)) "no prefix -> error_status null" None (opt_int "error_status" pj);
  Alcotest.(check bool) "error_status is present as null" true
    (member "error_status" pj = Some `Null);
  Alcotest.(check (pair int string)) "sync status from error_status"
    (502, "Radarr: release search failed for Come and See")
    (Pickarr_server.Responses.job_error_status fj);
  Alcotest.(check (pair int string)) "sync status default" (500, "fake failure p")
    (Pickarr_server.Responses.job_error_status pj);
  (* The job.failed event carries the bare message and the status. *)
  let contains ~needle h =
    let n = String.length needle in
    let rec go i = i + n <= String.length h && (String.sub h i n = needle || go (i + 1)) in
    go 0
  in
  let failed, _ = Events.query ~type_prefix:"job.failed" ~job_id:f () in
  Alcotest.(check int) "one job.failed event" 1 (List.length failed);
  let ev = List.hd failed in
  Alcotest.(check bool) "event message has no prefix" false (contains ~needle:"[502]" (str "message" ev));
  Alcotest.(check (option int)) "event data error_status" (Some 502)
    (match member "data" ev with Some d -> opt_int "error_status" d | None -> None);
  (* Persisted without the prefix, and status survives a restart. *)
  run (Jobs.flush ());
  let snapshot =
    In_channel.with_open_bin (Filename.concat dir "jobs.json") In_channel.input_all
  in
  Alcotest.(check bool) "jobs.json has no [502] prefix" false
    (let needle = "[502]" in
     let n = String.length needle in
     let rec go i = i + n <= String.length snapshot && (String.sub snapshot i n = needle || go (i + 1)) in
     go 0);
  Jobs.reset_for_tests ();
  run (Events.init ~data_dir:dir);
  Jobs.start (state_of dir);
  Alcotest.(check (option int)) "error_status after restart" (Some 502)
    (opt_int "error_status" (get f))

(* jobs.json written before "error_status" existed: the prefix still on
   "error" is split off when it is loaded. *)
let test_error_status_legacy_snapshot () =
  let dir = temp_dir "pickarr-queue-legacy" in
  let snapshot =
    {|{"version":1,"next_id":4,"jobs":[{"id":3,"kind":"fake","status":"failed","label":"Old","source":"ui","instance_id":null,"params":{"tag":"x"},"attempt":1,"retry_of":null,"error":"[404] no instance \"gone\" is configured","created_unix":1.0,"finished_unix":2.0}]}|}
  in
  Out_channel.with_open_bin (Filename.concat dir "jobs.json") (fun oc ->
      Out_channel.output_string oc snapshot);
  Jobs.reset_for_tests ();
  run (Events.init ~data_dir:dir);
  Jobs.start (state_of dir);
  let j = get 3 in
  Alcotest.(check string) "prefix split off" "no instance \"gone\" is configured" (str "error" j);
  Alcotest.(check (option int)) "status kept" (Some 404) (opt_int "error_status" j)

let test_retry () =
  let _, state = fresh () in
  let f = enqueue state ~source:"api" (params ~outcome:"fail" "f") in
  ignore (wait_done f);
  (match Jobs.retry state f with
  | Error e -> Alcotest.fail e
  | Ok j ->
      Alcotest.(check int) "attempt 2" 2 (int "attempt" j);
      Alcotest.(check (option int)) "retry_of" (Some f) (opt_int "retry_of" j);
      Alcotest.(check string) "source ui" "ui" (str "source" j);
      Alcotest.(check string) "same kind" "fake" (str "kind" j);
      ignore (wait_done (int "id" j)));
  let ok = enqueue state (params "ok") in
  ignore (wait_done ok);
  match Jobs.retry state ok with
  | Ok _ -> Alcotest.fail "a succeeded job cannot be retried"
  | Error _ -> ()

let test_wait () =
  let _, state = fresh () in
  let id = enqueue state (params ~ms:100 "w") in
  let both =
    run
      (Lwt.both (Jobs.wait id ~timeout:5.) (Jobs.wait id ~timeout:5.))
  in
  (match both with
  | Some a, Some b ->
      Alcotest.(check string) "first waiter" "succeeded" (status a);
      Alcotest.(check string) "second waiter" "succeeded" (status b);
      Alcotest.(check bool) "result included" true (member "result" a <> Some `Null)
  | _ -> Alcotest.fail "both waiters must resolve");
  Alcotest.(check bool) "unknown id" true (run (Jobs.wait 999_999 ~timeout:0.1) = None);
  let slow = enqueue state (params ~ms:2000 "slow") in
  Alcotest.(check bool) "timeout" true (run (Jobs.wait slow ~timeout:0.05) = None);
  ignore (Jobs.cancel slow)

let test_clear_and_list_json () =
  let _, state = fresh () in
  let a = enqueue state (params "a") in
  let b = enqueue state (params ~outcome:"fail" "b") in
  ignore (wait_done a);
  ignore (wait_done b);
  let listed = Jobs.list () in
  (match member "jobs" listed with
  | Some (`List (newest :: _ as all)) ->
      Alcotest.(check int) "newest first" b (int "id" newest);
      Alcotest.(check int) "both listed" 2 (List.length all);
      List.iter
        (fun k -> Alcotest.(check bool) ("has " ^ k) true (member k newest <> None))
        [ "id"; "kind"; "status"; "label"; "source"; "instance_id"; "params"; "created_at";
          "started_at"; "finished_at"; "duration_ms"; "position"; "progress"; "attempt";
          "retry_of"; "error" ];
      Alcotest.(check bool) "no result in list" true (member "result" newest = None)
  | _ -> Alcotest.fail "jobs list");
  (match member "jobs" (Jobs.list ~include_result:true ()) with
  | Some (`List (j :: _)) -> Alcotest.(check bool) "result with include" true (member "result" j <> None)
  | _ -> Alcotest.fail "list with results");
  (match member "jobs" (Jobs.list ~statuses:[ Jobs.Failed ] ()) with
  | Some (`List [ j ]) -> Alcotest.(check int) "status filter" b (int "id" j)
  | _ -> Alcotest.fail "status filter");
  Alcotest.(check int) "cleared" 2 (Jobs.clear_finished ());
  Alcotest.(check bool) "gone" true (Jobs.get a = None)

let test_unknown_kind_and_bad_params () =
  let _, state = fresh () in
  (match Jobs.enqueue state "no_such_kind" (`Assoc []) with
  | Ok _ -> Alcotest.fail "unknown kind accepted"
  | Error _ -> ());
  match Jobs.enqueue state "fake" (`Assoc []) with
  | Ok _ -> Alcotest.fail "invalid params accepted"
  | Error e -> Alcotest.(check string) "validator message" "tag is required" e

let test_progress_label_and_events () =
  let _, state = fresh () in
  let id = enqueue state (params ~outcome:"progress" "p") in
  let j = wait_done id in
  Alcotest.(check string) "label refined" "Fake · renamed p" (str "label" j);
  let progress, _ = Events.query ~type_prefix:"job.progress" ~job_id:id () in
  Alcotest.(check int) "progress events rate limited" 1 (List.length progress);
  let job_events, _ = Events.query ~job_id:id () in
  let types = List.map (fun e -> str "type" e) job_events in
  List.iter
    (fun t -> Alcotest.(check bool) ("emitted " ^ t) true (List.mem t types))
    [ "job.queued"; "job.started"; "job.succeeded"; "fake.custom" ]

let test_keep_finished () =
  let _, state = fresh ~queue:(queue ~workers:8 ~keep:10 ()) () in
  (* keep_finished is clamped to 50 by the config decoder, but the record can
     carry any value: the queue honours what it is given. *)
  let ids = List.init 25 (fun i -> enqueue state (params ~ms:1 (string_of_int i))) in
  List.iter (fun id -> ignore (run (Jobs.wait id ~timeout:10.))) ids;
  sleep 0.05;
  let counts = member "counts" (Jobs.list ()) |> Option.get in
  Alcotest.(check int) "only the newest finished kept" 10 (int "succeeded" counts);
  Alcotest.(check bool) "oldest dropped" true (Jobs.get (List.hd ids) = None);
  Alcotest.(check bool) "newest kept" true (Jobs.get (List.nth ids 24) <> None)

let test_restart () =
  let dir, state = fresh ~queue:(queue ~workers:1 ()) () in
  let running = enqueue state (params ~ms:5000 "running") in
  let q1 = enqueue state (params ~ms:10 "q1") in
  let q2 = enqueue state (params ~ms:10 "q2") in
  let done_ = enqueue state ~source:"api" (params ~ms:1 ~instance_id:"zzz" "unused") in
  ignore done_;
  sleep 0.05;
  Alcotest.(check string) "first is running" "running" (status (get running));
  run (Jobs.flush ());
  (* "Restart": forget everything and load jobs.json from the same dir. *)
  Jobs.reset_for_tests ();
  reset_observations ();
  run (Events.init ~data_dir:dir);
  let state2 = state_of ~queue:(queue ~workers:1 ()) dir in
  Jobs.start state2;
  let r = get running in
  Alcotest.(check string) "running -> failed" "failed" (status r);
  Alcotest.(check string) "interrupted" "interrupted by restart" (str "error" r);
  let q1j = wait_done q1 and q2j = wait_done q2 in
  Alcotest.(check string) "queued job re-queued and run" "succeeded" (status q1j);
  Alcotest.(check string) "second too" "succeeded" (status q2j);
  Alcotest.(check (list string)) "in their original order" [ "q1"; "q2"; "unused" ]
    (List.rev !started_order);
  let interrupted, _ = Events.query ~type_prefix:"job.interrupted" () in
  Alcotest.(check int) "job.interrupted event" 1 (List.length interrupted);
  let fresh_id = enqueue state2 (params "after") in
  Alcotest.(check bool) "ids continue" true (fresh_id > done_);
  ignore (wait_done fresh_id)

let test_restart_unknown_kind () =
  let dir = temp_dir "pickarr-queue-unknown" in
  let snapshot =
    {|{"version":1,"next_id":8,"jobs":[{"id":7,"kind":"vanished","status":"queued","label":"Old","source":"api","instance_id":null,"params":{},"attempt":1,"retry_of":null,"error":null,"created_unix":1.0}]}|}
  in
  Out_channel.with_open_bin (Filename.concat dir "jobs.json") (fun oc ->
      Out_channel.output_string oc snapshot);
  Jobs.reset_for_tests ();
  run (Events.init ~data_dir:dir);
  let state = state_of dir in
  Jobs.start state;
  let j = get 7 in
  Alcotest.(check string) "unregistered kind fails" "failed" (status j);
  let id = enqueue state (params "x") in
  Alcotest.(check int) "next_id honoured" 8 id;
  ignore (wait_done id)

let test_live_worker_change () =
  let _, state = fresh ~queue:(queue ~workers:1 ()) () in
  let ids = List.map (fun t -> enqueue state (params ~ms:300 t)) [ "a"; "b"; "c" ] in
  sleep 0.05;
  Alcotest.(check int) "one running" 1 !running_now;
  (match
     run
       (Store.update state.App_state.store (fun c ->
            Ok { c with Config.queue = queue ~workers:3 () }))
   with
  | Ok _ -> ()
  | Error e -> Alcotest.fail e);
  sleep 1.2;
  Alcotest.(check bool) "more workers picked up live" true (!max_running >= 2);
  List.iter (fun id -> ignore (wait_done id)) ids

(* ------------------------------------------------------------------ *)
(* Events                                                              *)
(* ------------------------------------------------------------------ *)

let read_lines path =
  if not (Sys.file_exists path) then []
  else
    In_channel.with_open_bin path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun l -> String.trim l <> "")

let ids_of events = List.map (int "id") events

let test_events_query () =
  let dir = temp_dir "pickarr-events" in
  run (Events.init ~data_dir:dir);
  Events.emit "grab.sent" "Sent release to Radarr" ~instance_id:"radarr" ~media:"Come and See (1985)";
  Events.emit ~level:Events.Warn "grab.retry" "Retrying with shouldOverride";
  Events.emit ~level:Events.Error ~job_id:42 "job.failed" "Failed: Grab";
  Events.emit ~job_id:42 ~data:[ ("x", `Int 1) ] "job.queued" "Queued: Grab";
  let all, last = Events.query () in
  Alcotest.(check int) "four events" 4 (List.length all);
  Alcotest.(check int) "last id" last (List.nth (ids_of all) 3);
  let first = List.hd (ids_of all) in
  let since, _ = Events.query ~since_id:first () in
  Alcotest.(check int) "since_id excludes the boundary" 3 (List.length since);
  let limited, _ = Events.query ~since_id:first ~limit:1 () in
  Alcotest.(check (list int)) "since_id + limit = oldest after" [ first + 1 ] (ids_of limited);
  let recent, _ = Events.query ~limit:2 () in
  Alcotest.(check (list int)) "no since: most recent, ascending" [ first + 2; first + 3 ]
    (ids_of recent);
  let grabs, _ = Events.query ~type_prefix:"grab." () in
  Alcotest.(check int) "type prefix" 2 (List.length grabs);
  let warn, _ = Events.query ~min_level:Events.Warn () in
  Alcotest.(check int) "min level warn" 2 (List.length warn);
  let errors, _ = Events.query ~min_level:Events.Error () in
  Alcotest.(check int) "min level error" 1 (List.length errors);
  let job, _ = Events.query ~job_id:42 () in
  Alcotest.(check int) "job filter" 2 (List.length job);
  let text, _ = Events.query ~text:"COME AND" () in
  Alcotest.(check int) "text matches media, case-insensitive" 1 (List.length text);
  let text2, _ = Events.query ~text:"shouldoverride" () in
  Alcotest.(check int) "text matches message" 1 (List.length text2);
  let e = List.nth all 3 in
  List.iter
    (fun k -> Alcotest.(check bool) ("event has " ^ k) true (member k e <> None))
    [ "id"; "ts"; "level"; "type"; "message"; "job_id"; "instance_id"; "media"; "data" ];
  Alcotest.(check string) "ts format" "Z" (let ts = str "ts" e in String.sub ts (String.length ts - 1) 1);
  Alcotest.(check (option string)) "level strings" (Some Events.(level_to_string Warn)) (Some "warn");
  Alcotest.(check bool) "level parse" true (Events.level_of_string "warning" = Some Events.Warn)

let test_events_persist_and_continue () =
  let dir = temp_dir "pickarr-events-persist" in
  run (Events.init ~data_dir:dir);
  for i = 1 to 5 do
    Events.emit "test.persist" (Printf.sprintf "event %d" i)
  done;
  run (Events.flush ());
  let _, last = Events.query () in
  Alcotest.(check int) "written to the file" 5
    (List.length (read_lines (Filename.concat dir "events.jsonl")));
  (* Re-init on the same dir: ids continue, history is back. *)
  run (Events.init ~data_dir:dir);
  let loaded, last2 = Events.query () in
  Alcotest.(check int) "same last id after reload" last last2;
  Alcotest.(check int) "history loaded" 5 (List.length loaded);
  Events.emit "test.persist" "after restart";
  let _, last3 = Events.query () in
  Alcotest.(check int) "monotonic" (last + 1) last3

let test_events_rotation () =
  let dir = temp_dir "pickarr-events-rotate" in
  Events.set_rotate_bytes 600;
  run (Events.init ~data_dir:dir);
  for i = 1 to 30 do
    Events.emit "test.rotate" (Printf.sprintf "rotating event number %d" i);
    run (Events.flush ())
  done;
  Events.set_rotate_bytes (10 * 1024 * 1024);
  Alcotest.(check bool) "rotated file exists" true
    (Sys.file_exists (Filename.concat dir "events.1.jsonl"));
  let _, last = Events.query () in
  run (Events.init ~data_dir:dir);
  let _, last2 = Events.query () in
  Alcotest.(check int) "ids continue across rotation" last last2

let test_events_concurrent_emits () =
  let dir = temp_dir "pickarr-events-concurrent" in
  run (Events.init ~data_dir:dir);
  run
    (Lwt_list.iter_p
       (fun i ->
         let* () = Lwt.pause () in
         Events.emit ~data:[ ("i", `Int i) ] "test.concurrent" (String.make 200 'x');
         let* () = Lwt.pause () in
         Events.emit "test.concurrent" (Printf.sprintf "second %d" i);
         Lwt.return_unit)
       (List.init 300 Fun.id));
  run (Events.flush ());
  let lines = read_lines (Filename.concat dir "events.jsonl") in
  Alcotest.(check int) "every event written once" 600 (List.length lines);
  let ids =
    List.map
      (fun l ->
        match Yojson.Safe.from_string l with
        | j -> int "id" j
        | exception _ -> Alcotest.failf "invalid JSONL line: %s" l)
      lines
  in
  Alcotest.(check bool) "ids strictly ascending in the file" true
    (let rec ok = function a :: (b :: _ as tl) -> a < b && ok tl | _ -> true in
     ok ids)

let () =
  Random.self_init ();
  Alcotest.run "pickarr-queue"
    [
      ( "jobs",
        [
          Alcotest.test_case "FIFO with one worker" `Quick test_fifo_single_worker;
          Alcotest.test_case "workers limit" `Quick test_workers_limit;
          Alcotest.test_case "per-instance limit" `Quick test_per_instance_limit;
          Alcotest.test_case "positions and counts" `Quick test_positions_and_counts;
          Alcotest.test_case "dedupe" `Quick test_dedupe;
          Alcotest.test_case "cancel running" `Quick test_cancel_running;
          Alcotest.test_case "cancel an uncancelable runner" `Quick test_cancel_uncancelable_runner;
          Alcotest.test_case "fail and raise" `Quick test_fail_and_raise;
          Alcotest.test_case "error status" `Quick test_error_status;
          Alcotest.test_case "error status from an old jobs.json" `Quick
            test_error_status_legacy_snapshot;
          Alcotest.test_case "retry" `Quick test_retry;
          Alcotest.test_case "wait" `Quick test_wait;
          Alcotest.test_case "clear and list JSON" `Quick test_clear_and_list_json;
          Alcotest.test_case "unknown kind and bad params" `Quick test_unknown_kind_and_bad_params;
          Alcotest.test_case "progress, label and events" `Quick test_progress_label_and_events;
          Alcotest.test_case "keep finished" `Quick test_keep_finished;
          Alcotest.test_case "restart" `Quick test_restart;
          Alcotest.test_case "restart with an unknown kind" `Quick test_restart_unknown_kind;
          Alcotest.test_case "live worker change" `Quick test_live_worker_change;
        ] );
      ( "events",
        [
          Alcotest.test_case "query and filters" `Quick test_events_query;
          Alcotest.test_case "persist and continue" `Quick test_events_persist_and_continue;
          Alcotest.test_case "rotation" `Quick test_events_rotation;
          Alcotest.test_case "concurrent emits" `Quick test_events_concurrent_emits;
        ] );
    ]
