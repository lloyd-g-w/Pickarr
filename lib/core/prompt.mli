(** Stage 4 input: the prompt sent to an OpenAI-compatible LLM.

    The user message is a single JSON object with exactly these keys, in this
    order: [media], [hard_constraints], [structured_preferences],
    [natural_language_preferences], [temporary_instruction] and [candidates].
    Releases rejected by the hard rules are never included.

    Candidates are identified by {b short ids} ([r1], [r2], ...), never by
    their real release id: a torrent guid is often a magnet link of several
    hundred characters, which models truncate or re-encode, making their
    answer unusable.  {!build_with_ids} returns the mapping so the caller can
    translate the model's answer back. *)

(** Instructions given as the [system] message: the priority order of the
    different preference kinds, that the hard constraints are already
    enforced and cannot be violated, that ids are short tokens which must be
    copied verbatim, and the strict JSON response schema. *)
val system_prompt : string

(** [candidates_for_llm llm scored] is the bounded prefix of [scored] that is
    sent to the model ([llm_max_candidates] entries, best first). *)
val candidates_for_llm :
  Config.llm -> Types.scored_release list -> Types.scored_release list

(** [short_ids sent] pairs each candidate with the short id it is given in the
    prompt: the first is ["r1"], the second ["r2"], and so on. *)
val short_ids :
  Types.scored_release list -> (string * Types.scored_release) list

(** [candidate_to_yojson ~id ~rank scored] is the compact per-candidate JSON
    used in the prompt.  [id] is the short id and [rank] the 1-based
    deterministic rank.  Absent and empty fields are omitted; [is_repack],
    [is_proper] and [dolby_vision] appear only when true, [arr_rejections]
    only when non-empty.  No guid, URL, magnet link or info hash is ever
    included. *)
val candidate_to_yojson :
  id:string -> rank:int -> Types.scored_release -> Yojson.Safe.t

(** [build_with_ids ~config ~instance ~media ?instruction candidates] renders
    the user message and returns it with the association list
    [(short id, real release id)] for the candidates that were sent, in
    prompt order.  [instance] contributes its per-instance natural-language
    preferences; [instruction] is a temporary per-request instruction that is
    not persisted. *)
val build_with_ids :
  config:Config.t ->
  instance:Config.instance option ->
  media:Types.media ->
  ?instruction:string ->
  Types.scored_release list ->
  string * (string * string) list

(** [build] is {!build_with_ids} without the id mapping. *)
val build :
  config:Config.t ->
  instance:Config.instance option ->
  media:Types.media ->
  ?instruction:string ->
  Types.scored_release list ->
  string
