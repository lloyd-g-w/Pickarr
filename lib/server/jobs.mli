(** The server-side job queue.

    Every user or automatic action (search, grab, Seerr request selection,
    automatic pass, Seerr pass, webhook work) runs as a job: it is queued,
    started by a small worker pool, and finishes as succeeded, failed or
    cancelled.  The UI lists jobs live through [GET /api/jobs]; every
    transition is also an {!Events} event ([job.queued], [job.started],
    [job.progress], [job.succeeded], [job.failed], [job.cancelled],
    [job.interrupted]).

    Scheduling is FIFO by job id with two limits read live from
    [config.queue]: at most [queue_workers] jobs run at once, and at most
    [queue_per_instance] of them against one [instance_id].  A job held back
    by its instance limit does not hold back later jobs for other instances.

    The list is persisted to [DATA_DIR/jobs.json] (debounced, at most one
    write per second, write-temp-then-rename).  After a restart, jobs that
    were running are marked failed ("interrupted by restart") and queued jobs
    are queued again — their kind must be registered before {!start}. *)

type status = Queued | Running | Succeeded | Failed | Cancelled

val status_to_string : status -> string
(** ["queued"] | ["running"] | ["succeeded"] | ["failed"] | ["cancelled"] *)

val status_of_string : string -> status option

(** What a running job can do. *)
type ctx = {
  job_id : int;
  progress : string -> unit;
      (** Set the job's progress line; also emits [job.progress] (at most one
          event per second per job). *)
  set_label : string -> unit;  (** Replace the label once the title is known. *)
  event :
    ?level:Events.level -> ?data:(string * Yojson.Safe.t) list -> string -> string -> unit;
      (** {!Events.emit} tagged with this job's id and instance id. *)
}

(** A validated job, ready to run. *)
type prepared = {
  label : string;  (** e.g. ["Grab · Radarr movie 440"] *)
  instance_id : string option;
  dedupe_key : string option;
      (** While a queued or running job has the same key, enqueueing returns
          that job instead of adding another. *)
  run : ctx -> (Yojson.Safe.t, string) result Lwt.t;
      (** [Ok result] | [Error message]; exceptions are caught -> failed. *)
}

val register : string -> (App_state.t -> Yojson.Safe.t -> (prepared, string) result) -> unit
(** Register a job kind with a synchronous parser/validator of its params (no
    I/O).  Registering the same kind again replaces it. *)

val enqueue :
  App_state.t -> ?source:string -> string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** [enqueue state ~source kind params] -> [Ok job_json] (queued, or the
    existing job with the same dedupe key) | [Error] (unknown kind, invalid
    params).  [source]: "ui" | "api" | "automatic" | "seerr" | "webhook"
    (default "api"). *)

val start : App_state.t -> unit
(** Load [jobs.json] (restart semantics above) and start the dispatcher.
    Idempotent.  When the environment has [PICKARR_TEST_JOBS=1] a test kind
    ["test_sleep"] [{ms, fail?, raise?, instance_id?, dedupe?}] is
    registered first. *)

val list :
  ?statuses:status list ->
  ?kind:string ->
  ?limit:int ->
  ?include_result:bool ->
  unit ->
  Yojson.Safe.t
(** [{"jobs":[...newest first], "counts":{...}}].  [limit] defaults to 100.
    Counts cover every job, not just the listed ones. *)

val get : int -> Yojson.Safe.t option
(** One job, including its result. *)

val wait : int -> timeout:float -> Yojson.Safe.t option Lwt.t
(** The job (with its result) once it has finished; [None] on timeout or for
    an unknown id.  Every waiter is woken. *)

val cancel : int -> (Yojson.Safe.t, string) result
(** Queued -> cancelled at once; running -> its runner is cancelled and the
    job is marked cancelled (it never stays "running"); finished or unknown
    -> [Error]. *)

val retry : App_state.t -> int -> (Yojson.Safe.t, string) result
(** A new job with the same kind and params (source "ui"), for failed or
    cancelled jobs only. *)

val clear_finished : unit -> int
(** Remove succeeded, failed and cancelled jobs; returns how many. *)

val counts : unit -> Yojson.Safe.t
(** [{"queued":n,"running":n,"succeeded":n,"failed":n,"cancelled":n}] *)

(** {2 Extras (not part of the HTTP contract)} *)

val is_registered : string -> bool

val flush : unit -> unit Lwt.t
(** Write [jobs.json] now if anything changed.  Tests and shutdown. *)

val reset_for_tests : unit -> unit
(** Forget every job and kind-independent state and stop the dispatcher, as
    if the process had restarted.  Registered kinds are kept.  Tests only. *)
