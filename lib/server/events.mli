(* STUB (queue-integration worktree) — discard at merge; the real module comes
   from the queue-core stream.  Signatures are exactly the shared contract. *)

type level = Info | Warn | Error

val level_to_string : level -> string
val level_of_string : string -> level option
val init : data_dir:string -> unit Lwt.t

val emit :
  ?level:level ->
  ?job_id:int ->
  ?instance_id:string ->
  ?media:string ->
  ?data:(string * Yojson.Safe.t) list ->
  string ->
  string ->
  unit

val query :
  ?since_id:int ->
  ?limit:int ->
  ?type_prefix:string ->
  ?min_level:level ->
  ?job_id:int ->
  ?text:string ->
  unit ->
  Yojson.Safe.t list * int
