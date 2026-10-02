(* STUB (queue-integration worktree) — discard at merge; the real module comes
   from the queue-core stream.  Signatures are exactly the shared contract. *)

type status = Queued | Running | Succeeded | Failed | Cancelled

val status_to_string : status -> string
val status_of_string : string -> status option

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

val register : string -> (App_state.t -> Yojson.Safe.t -> (prepared, string) result) -> unit

val enqueue :
  App_state.t -> ?source:string -> string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result

val start : App_state.t -> unit

val list :
  ?statuses:status list -> ?kind:string -> ?limit:int -> ?include_result:bool -> unit -> Yojson.Safe.t

val get : int -> Yojson.Safe.t option
val wait : int -> timeout:float -> Yojson.Safe.t option Lwt.t
val cancel : int -> (Yojson.Safe.t, string) result
val retry : App_state.t -> int -> (Yojson.Safe.t, string) result
val clear_finished : unit -> int
val counts : unit -> Yojson.Safe.t
