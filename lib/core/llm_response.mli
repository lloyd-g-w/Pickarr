(** Stage 4 validation: turn the model's JSON into a trusted
    {!Types.llm_decision}.

    Validation is deliberately strict — a malformed answer must make the
    pipeline fall back to deterministic scoring rather than act on garbage —
    but it never raises: every failure is an [Error] with a human-readable
    message.

    Accepted input: [{"selected_id", "confidence", "reason", "ranking":
    [{"id", "score", "reason"}], "influences": [...], "conflicts": [...]}].
    Numbers may be given as JSON numbers or as numeric strings.  [reason],
    [influences] and [conflicts] are optional; everything else is required.

    Rejected: unknown [selected_id], unknown ranking id, duplicate ranking
    ids, ranking score outside 0..100, confidence outside 0..1, wrong JSON
    types.  Out-of-range values are errors, never clamped. *)

val parse :
  candidate_ids:string list -> Yojson.Safe.t -> (Types.llm_decision, string) result
