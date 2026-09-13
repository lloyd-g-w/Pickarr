(** Stage 4 validation: turn the model's JSON into a trusted
    {!Types.llm_decision}.

    The one thing that must never happen is acting on a release the model
    invented, so [selected_id] has to resolve to one of the candidates that
    were sent; anything else makes the pipeline fall back to deterministic
    scoring.  Everything else in the answer is advisory (it orders and
    annotates the list the user sees), so sloppiness there is repaired and
    reported as a warning instead of throwing the whole answer away — small
    local models very often mangle one ranking id while picking correctly.

    Never raises: every failure is an [Error] with a human-readable message.

    Accepted input: [{"selected_id", "confidence", "reason", "ranking":
    [{"id", "score", "reason"}], "influences": [...], "conflicts": [...]}].
    Only [selected_id] is required.

    Ids are matched leniently: surrounding quotes, backticks, asterisks and
    brackets are stripped, trailing punctuation is ignored, case and spaces
    do not matter, and ["#3"], ["candidate 3"] or ["3"] all resolve to
    ["r3"].  A candidate's exact title is accepted as an id when it is
    unambiguous (pass it through [aliases]).

    Repairs, each reported as a warning:
    - a missing or unreadable [confidence] becomes 0.5; a value in 1..100 is
      read as a percentage; anything outside 0..1 is clamped;
    - ranking entries whose id cannot be resolved are dropped;
    - a repeated id keeps the first entry;
    - a missing or unreadable score falls back to the entry's position;
    - scores outside 0..100 are clamped;
    - a missing, empty or malformed ranking becomes a single entry for the
      selected release;
    - non-string entries of [influences] and [conflicts] are dropped. *)

val parse_with_warnings :
  candidate_ids:string list ->
  ?aliases:(string * string) list ->
  Yojson.Safe.t ->
  (Types.llm_decision * string list, string) result
(** [parse_with_warnings ~candidate_ids ?aliases json] validates [json].
    [aliases] maps extra accepted spellings (typically a candidate's title)
    to the candidate id they stand for; an alias pointing at two different
    candidates is ignored.  The returned strings describe what had to be
    repaired, in order, and are capped at six. *)

val parse :
  candidate_ids:string list -> Yojson.Safe.t -> (Types.llm_decision, string) result
(** {!parse_with_warnings} without the warnings and without aliases. *)
