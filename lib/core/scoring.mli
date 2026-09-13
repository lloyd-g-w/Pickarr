(** Stage 3 of the selection pipeline: deterministic scoring.

    Scoring runs on the candidates that survived {!Filter}.  It is pure so
    that it is easy to unit test, and every contribution is recorded as a
    {!Types.score_component} with a user-facing [detail] string that the
    explainability layer reuses.

    Structured preference lists are ordered: the first entry earns the full
    configured weight and later entries earn slightly less (10% less per
    position, never below 50%). *)

(** [position_weight base index] is the weight earned by the entry at
    [index] (0-based) of an ordered preference list. *)
val position_weight : float -> int -> float

(** [score prefs weights media release] computes the deterministic score of a
    single candidate.  [media] is accepted so that callers do not need to
    special-case movies and episodes; the deterministic score itself is
    media-independent (media-specific nuance is handled by the LLM through
    natural-language preferences). *)
val score :
  Config.preferences ->
  Config.weights ->
  Types.media ->
  Types.release ->
  Types.scored_release

(** [rank prefs weights media releases] scores every release and sorts them
    best-first.  Ties are broken deterministically by Custom Format score,
    then seeders, then title. *)
val rank :
  Config.preferences ->
  Config.weights ->
  Types.media ->
  Types.release list ->
  Types.scored_release list
