(* In-memory ring buffer of recent log lines, surfaced by GET /api/logs, plus
   the logging entry points used by the server modules.

   Every message is both written to the process log (via Dream's sub-log,
   which is backed by [Logs]) and retained in the ring buffer so the UI can
   show recent activity without shell access to the container. *)

type level = Debug | Info | Warning | Error

let level_to_string = function
  | Debug -> "debug"
  | Info -> "info"
  | Warning -> "warning"
  | Error -> "error"

type entry = { at : string; level : level; message : string }

let capacity = 500
let buffer : entry array = Array.make capacity { at = ""; level = Info; message = "" }
let next = ref 0
let count = ref 0
let log = Dream.sub_log "pickarr"

let timestamp () = Ptime.to_rfc3339 ~tz_offset_s:0 (Ptime_clock.now ())

let push level message =
  buffer.(!next) <- { at = timestamp (); level; message };
  next := (!next + 1) mod capacity;
  if !count < capacity then incr count

let emit level message =
  push level message;
  match level with
  | Debug -> log.debug (fun l -> l "%s" message)
  | Info -> log.info (fun l -> l "%s" message)
  | Warning -> log.warning (fun l -> l "%s" message)
  | Error -> log.error (fun l -> l "%s" message)

let debugf fmt = Printf.ksprintf (emit Debug) fmt
let infof fmt = Printf.ksprintf (emit Info) fmt
let warnf fmt = Printf.ksprintf (emit Warning) fmt
let errorf fmt = Printf.ksprintf (emit Error) fmt

(** Recent entries, newest first, at most [limit]. *)
let recent ~limit =
  let n = min limit !count in
  List.init n (fun i ->
      let idx = ((!next - 1 - i) + (2 * capacity)) mod capacity in
      buffer.(idx))

let entry_to_yojson (e : entry) : Yojson.Safe.t =
  `Assoc
    [
      ("at", `String e.at);
      ("level", `String (level_to_string e.level));
      ("message", `String e.message);
    ]
