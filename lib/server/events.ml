(* Structured event log.  See events.mli.

   In memory: a ring of the last [capacity] events, ascending by id.
   On disk: DATA_DIR/events.jsonl, one JSON object per line, written by a
   single background writer so concurrent emits never interleave. *)

type level = Info | Warn | Error

let level_to_string = function Info -> "info" | Warn -> "warn" | Error -> "error"

let level_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "info" -> Some Info
  | "warn" | "warning" -> Some Warn
  | "error" -> Some Error
  | _ -> None

let level_rank = function Info -> 0 | Warn -> 1 | Error -> 2

type event = {
  id : int;
  level : level;
  typ : string;
  message : string;
  job_id : int option;
  media : string option;
  json : Yojson.Safe.t;
}

let capacity = 5000
let file_name = "events.jsonl"
let rotated_name = "events.1.jsonl"

(* ------------------------------------------------------------------ *)
(* State                                                               *)
(* ------------------------------------------------------------------ *)

let ring : event option array = Array.make capacity None
let ring_start = ref 0 (* index of the oldest event *)
let ring_count = ref 0
let last_id = ref 0
let data_dir : string option ref = ref None
let rotate_bytes = ref (10 * 1024 * 1024)
let set_rotate_bytes n = rotate_bytes := max 1 n

(* Events emitted before [init]: renumbered and written once the file's last
   id is known. *)
let pre_init : event list ref = ref []
let pre_init_count = ref 0

(* Lines waiting for the writer. *)
let pending : string Queue.t = Queue.create ()
let writing = ref false
let flush_waiters : unit Lwt.u list ref = ref []
let write_error_reported = ref false

let ring_clear () =
  Array.fill ring 0 capacity None;
  ring_start := 0;
  ring_count := 0

let ring_push (e : event) =
  if !ring_count < capacity then (
    ring.((!ring_start + !ring_count) mod capacity) <- Some e;
    incr ring_count)
  else (
    ring.(!ring_start) <- Some e;
    ring_start := (!ring_start + 1) mod capacity)

(* Ascending by id. *)
let ring_to_list () =
  let rec go i acc =
    if i < 0 then acc
    else
      match ring.((!ring_start + i) mod capacity) with
      | Some e -> go (i - 1) (e :: acc)
      | None -> go (i - 1) acc
  in
  go (!ring_count - 1) []

(* ------------------------------------------------------------------ *)
(* JSON                                                                *)
(* ------------------------------------------------------------------ *)

let timestamp () = Ptime.to_rfc3339 ~tz_offset_s:0 (Ptime_clock.now ())
let opt_string = function None -> `Null | Some s -> `String s
let opt_int = function None -> `Null | Some i -> `Int i

let make_json ~id ~ts ~level ~typ ~message ~job_id ~instance_id ~media ~data :
    Yojson.Safe.t =
  `Assoc
    [
      ("id", `Int id);
      ("ts", `String ts);
      ("level", `String (level_to_string level));
      ("type", `String typ);
      ("message", `String message);
      ("job_id", opt_int job_id);
      ("instance_id", opt_string instance_id);
      ("media", opt_string media);
      ("data", `Assoc data);
    ]

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None

let string_member k j = match member k j with Some (`String s) -> Some s | _ -> None
let int_member k j = match member k j with Some (`Int i) -> Some i | _ -> None

(* Rebuild an event from a stored line; [None] for anything malformed. *)
let event_of_json (j : Yojson.Safe.t) : event option =
  match (int_member "id" j, string_member "type" j) with
  | Some id, Some typ when id > 0 ->
      Some
        {
          id;
          typ;
          level =
            Option.value ~default:Info
              (Option.bind (string_member "level" j) level_of_string);
          message = Option.value ~default:"" (string_member "message" j);
          job_id = int_member "job_id" j;
          media = string_member "media" j;
          json = j;
        }
  | _ -> None

(* Same event with a new id (pre-init renumbering). *)
let with_id (e : event) (id : int) : event =
  let json =
    match e.json with
    | `Assoc l -> `Assoc (List.map (fun (k, v) -> if k = "id" then (k, `Int id) else (k, v)) l)
    | j -> j
  in
  { e with id; json }

(* ------------------------------------------------------------------ *)
(* Writer                                                              *)
(* ------------------------------------------------------------------ *)

let ( let* ) = Lwt.bind

let report_write_error dir exn =
  if not !write_error_reported then (
    write_error_reported := true;
    prerr_endline
      (Printf.sprintf "pickarr: cannot write %s: %s (events are kept in memory only)"
         (Filename.concat dir file_name) (Printexc.to_string exn)))

let wake_flush_waiters () =
  let ws = !flush_waiters in
  flush_waiters := [];
  List.iter (fun w -> try Lwt.wakeup_later w () with Invalid_argument _ -> ()) ws

let append_to_file dir (text : string) =
  let path = Filename.concat dir file_name in
  let* fd =
    Lwt_unix.openfile path [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o644
  in
  let bytes = Bytes.unsafe_of_string text in
  let len = Bytes.length bytes in
  let rec write_all off =
    if off >= len then Lwt.return_unit
    else
      let* n = Lwt_unix.write fd bytes off (len - off) in
      write_all (off + n)
  in
  Lwt.finalize (fun () -> write_all 0) (fun () -> Lwt_unix.close fd)

let rotate_if_needed dir =
  let path = Filename.concat dir file_name in
  let* st = Lwt_unix.stat path in
  if st.Unix.st_size >= !rotate_bytes then
    Lwt_unix.rename path (Filename.concat dir rotated_name)
  else Lwt.return_unit

let rec writer () =
  match !data_dir with
  | None ->
      writing := false;
      wake_flush_waiters ();
      Lwt.return_unit
  | Some dir ->
      if Queue.is_empty pending then (
        writing := false;
        wake_flush_waiters ();
        Lwt.return_unit)
      else
        let buf = Buffer.create 4096 in
        Queue.iter (Buffer.add_string buf) pending;
        Queue.clear pending;
        let* () =
          Lwt.catch
            (fun () ->
              let* () = append_to_file dir (Buffer.contents buf) in
              rotate_if_needed dir)
            (fun exn ->
              report_write_error dir exn;
              Lwt.return_unit)
        in
        writer ()

let kick_writer () =
  if not !writing then (
    writing := true;
    Lwt.async (fun () ->
        Lwt.catch writer (fun _ ->
            writing := false;
            wake_flush_waiters ();
            Lwt.return_unit)))

let queue_line (e : event) =
  Queue.add (Yojson.Safe.to_string e.json ^ "\n") pending;
  kick_writer ()

let flush () =
  if (not !writing) && (Queue.is_empty pending || !data_dir = None) then Lwt.return_unit
  else (
    let p, w = Lwt.wait () in
    flush_waiters := w :: !flush_waiters;
    kick_writer ();
    p)

(* ------------------------------------------------------------------ *)
(* Emit                                                                *)
(* ------------------------------------------------------------------ *)

let emit ?(level = Info) ?job_id ?instance_id ?media ?(data = []) typ message =
  try
    incr last_id;
    let id = !last_id in
    let json =
      make_json ~id ~ts:(timestamp ()) ~level ~typ ~message ~job_id ~instance_id ~media ~data
    in
    let e = { id; level; typ; message; job_id; media; json } in
    ring_push e;
    match !data_dir with
    | Some _ -> queue_line e
    | None ->
        (* Bounded: a process that never calls [init] (unit tests of other
           modules) must not grow without limit. *)
        pre_init := e :: !pre_init;
        incr pre_init_count;
        if !pre_init_count > 2 * capacity then (
          pre_init := List.filteri (fun i _ -> i < capacity) !pre_init;
          pre_init_count := capacity)
  with _ -> ()

(* ------------------------------------------------------------------ *)
(* Init                                                                *)
(* ------------------------------------------------------------------ *)

let read_lines path : string list =
  try
    if not (Sys.file_exists path) then []
    else
      In_channel.with_open_bin path In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun l -> String.trim l <> "")
  with _ -> []

(* The last [n] valid events of a file, ascending. *)
let tail_events path n : event list =
  let rec go acc k = function
    | [] -> acc
    | _ when k >= n -> acc
    | line :: rest -> (
        match
          try Some (Yojson.Safe.from_string line) with _ -> None
        with
        | None -> go acc k rest
        | Some j -> (
            match event_of_json j with
            | None -> go acc k rest
            | Some e -> go (e :: acc) (k + 1) rest))
  in
  go [] 0 (List.rev (read_lines path))

let init ~data_dir:dir =
  let* () = flush () in
  data_dir := None;
  let before = List.rev !pre_init in
  pre_init := [];
  pre_init_count := 0;
  ring_clear ();
  let current = tail_events (Filename.concat dir file_name) capacity in
  let older =
    if List.length current >= capacity then []
    else tail_events (Filename.concat dir rotated_name) (capacity - List.length current)
  in
  let loaded = older @ current in
  List.iter ring_push loaded;
  last_id := List.fold_left (fun acc (e : event) -> max acc e.id) 0 loaded;
  data_dir := Some dir;
  write_error_reported := false;
  List.iter
    (fun e ->
      incr last_id;
      let e = with_id e !last_id in
      ring_push e;
      queue_line e)
    before;
  Lwt.return_unit

(* ------------------------------------------------------------------ *)
(* Query                                                               *)
(* ------------------------------------------------------------------ *)

let contains_ci ~needle haystack =
  let needle = String.lowercase_ascii needle and haystack = String.lowercase_ascii haystack in
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let rec take n = function [] -> [] | _ when n <= 0 -> [] | x :: tl -> x :: take (n - 1) tl

let query ?since_id ?(limit = 200) ?type_prefix ?min_level ?job_id ?text () =
  let limit = min capacity (max 1 limit) in
  let type_prefix = match type_prefix with Some p when String.trim p <> "" -> Some (String.trim p) | _ -> None in
  let text = match text with Some t when String.trim t <> "" -> Some (String.trim t) | _ -> None in
  let matches (e : event) =
    (match type_prefix with Some prefix -> starts_with ~prefix e.typ | None -> true)
    && (match min_level with Some l -> level_rank e.level >= level_rank l | None -> true)
    && (match job_id with Some j -> e.job_id = Some j | None -> true)
    &&
    match text with
    | Some needle ->
        contains_ci ~needle e.message || contains_ci ~needle e.typ
        || (match e.media with Some m -> contains_ci ~needle m | None -> false)
    | None -> true
  in
  let all = ring_to_list () in
  let selected =
    match since_id with
    | Some since -> take limit (List.filter (fun e -> e.id > since && matches e) all)
    | None ->
        let m = List.filter matches all in
        let drop = List.length m - limit in
        if drop > 0 then List.filteri (fun i _ -> i >= drop) m else m
  in
  (List.map (fun e -> e.json) selected, !last_id)
