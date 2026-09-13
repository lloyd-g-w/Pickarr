(** The selection pipeline: hard filtering, deterministic scoring, optional
    AI ranking and explainability.

    The pipeline never talks to Sonarr/Radarr or to the LLM itself: the HTTP
    client is injected as [llm] so that the pipeline stays testable and the
    server keeps ownership of I/O.  Grabbing is likewise the server's job;
    results always come back with [grabbed = false]. *)

(** The injected LLM call.  [Error reason] makes the pipeline fall back to
    deterministic scoring, recording [reason]. *)
type llm_fn =
  system:string -> user:string -> (Yojson.Safe.t, string) result Lwt.t

(** [run ~config ~instance ~media ~releases ?instruction ?llm ?use_ai ()]
    executes the pipeline.

    - [use_ai] defaults to [config.llm.llm_enabled]; AI is only used when it
      is [true] {i and} [llm] was provided.
    - [instruction] is a temporary natural-language instruction for this
      selection only; it is not persisted.
    - When the model answers with a valid decision the candidates are
      re-ordered to follow its ranking (the selected release first, then the
      ranked ones, then the unranked ones in deterministic order).
    - Any LLM or validation failure yields
      {!Types.By_deterministic_fallback} and the top deterministic
      candidate.
    - When no candidate survives the hard rules, [selected] is [None] and
      [reason] explains why. *)
val run :
  config:Config.t ->
  instance:Config.instance option ->
  media:Types.media ->
  releases:Types.release list ->
  ?instruction:string ->
  ?llm:llm_fn ->
  ?use_ai:bool ->
  unit ->
  Types.selection_result Lwt.t
