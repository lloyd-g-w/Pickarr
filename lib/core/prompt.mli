(** Stage 4 input: the prompt sent to an OpenAI-compatible LLM.

    The user message is a single JSON object with exactly these keys:
    [hard_constraints], [structured_preferences],
    [natural_language_preferences], [temporary_instruction], [media] and
    [candidates].  Releases rejected by the hard rules are never included. *)

(** Instructions given as the [system] message.  States that the hard
    constraints have already been enforced and cannot be violated, the
    priority order of the different preference kinds, and the strict JSON
    response schema. *)
val system_prompt : string

(** [candidates_for_llm llm scored] is the bounded prefix of [scored] that is
    sent to the model ([llm_max_candidates] entries, best first).  The
    pipeline uses it to know which ids the model was allowed to pick. *)
val candidates_for_llm :
  Config.llm -> Types.scored_release list -> Types.scored_release list

(** [candidate_to_yojson scored] is the compact per-candidate JSON used in the
    prompt. *)
val candidate_to_yojson : Types.scored_release -> Yojson.Safe.t

(** [build ~config ~instance ~media ?instruction candidates] renders the user
    message.  [instance] contributes its per-instance natural-language
    preferences; [instruction] is a temporary per-request instruction that is
    not persisted. *)
val build :
  config:Config.t ->
  instance:Config.instance option ->
  media:Types.media ->
  ?instruction:string ->
  Types.scored_release list ->
  string
