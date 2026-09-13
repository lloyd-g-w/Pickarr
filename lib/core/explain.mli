(** Explainability: why was this release chosen, and which of the user's
    wishes could not be honoured. *)

(** [hard_rule_conflicts ~config ~instance] scans the effective
    natural-language preferences for wishes that a hard rule makes
    impossible, e.g. "I really like AV1 releases" while AV1 is in
    [blocked_codecs] yields
    ["You said you prefer AV1, but AV1 is blocked by a hard codec rule."].

    The scan is a deliberately simple mention-based heuristic: hard rules
    always win, so the user is told about the clash rather than the rule
    being relaxed. *)
val hard_rule_conflicts :
  config:Config.t -> instance:Config.instance option -> string list

(** [explain ~config ~instance ~media ~selected ~candidates ~rejected ~llm]
    returns [(explanation, conflicts)]: a bullet list of the reasons the
    selected release won (deterministic score components, structured
    preference matches and, when present, the model's own [influences]), and
    the wishes that could not be followed ([llm.conflicts] merged with
    {!hard_rule_conflicts}).  Both lists are de-duplicated and stable. *)
val explain :
  config:Config.t ->
  instance:Config.instance option ->
  media:Types.media ->
  selected:Types.scored_release ->
  candidates:Types.scored_release list ->
  rejected:Types.rejected_release list ->
  llm:Types.llm_decision option ->
  string list * string list
