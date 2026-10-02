(** Structured event log: what Pickarr did, as data.

    Every job transition, search, grab, Seerr decision, webhook, login and
    every warning/error log line becomes one event.  Events have monotonic ids
    (continuing across restarts), are kept in memory (the last 5000) for
    [GET /api/events], and are appended to [DATA_DIR/events.jsonl] (rotated
    to [events.1.jsonl] at 10 MB).

    This module must not depend on {!Log_buffer}: Log_buffer mirrors its
    warning/error lines into here. *)

type level = Info | Warn | Error

val level_to_string : level -> string
(** ["info"] | ["warn"] | ["error"] *)

val level_of_string : string -> level option
(** Accepts ["info"], ["warn"]/["warning"], ["error"] (case-insensitive). *)

val init : data_dir:string -> unit Lwt.t
(** Load the tail of [data_dir/events.jsonl] (and [events.1.jsonl] when the
    current file holds fewer than 5000 events), so ids continue after the
    last stored one, then append every later event to the file.  Events
    emitted before [init] are renumbered after the loaded ones and written
    too.  Calling [init] again (tests) starts over from the files in the new
    directory. *)

val set_rotate_bytes : int -> unit
(** Size at which events.jsonl is rotated to events.1.jsonl.  Default 10 MB;
    tests use a tiny value. *)

val emit :
  ?level:level ->
  ?job_id:int ->
  ?instance_id:string ->
  ?media:string ->
  ?data:(string * Yojson.Safe.t) list ->
  string ->
  string ->
  unit
(** [emit event_type message].  Never raises and never blocks: the file
    append is queued and written by a single background writer, so
    concurrent emits never interleave.  [event_type] is dotted, e.g.
    ["job.queued"]. *)

val query :
  ?since_id:int ->
  ?limit:int ->
  ?type_prefix:string ->
  ?min_level:level ->
  ?job_id:int ->
  ?text:string ->
  unit ->
  Yojson.Safe.t list * int
(** Matching events, ascending by id.  With [since_id]: the first [limit]
    events with [id > since_id].  Without: the most recent [limit] events.
    [limit] defaults to 200 (clamped to 1..5000).  [type_prefix] matches the
    start of the type, [min_level] keeps that level and above, [text] is a
    case-insensitive substring match on message, media and type.  The second
    component is the latest event id overall (0 when there is none). *)

val flush : unit -> unit Lwt.t
(** Resolve once every event emitted so far has been written to the file.
    Used by tests and on shutdown. *)
