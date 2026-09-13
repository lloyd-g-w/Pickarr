(** Stage 2 of the selection pipeline: deterministic hard rules.

    Hard rules decide what Selectarr is *allowed* to choose.  They are pure
    and are never overridable by the LLM, by natural-language preferences or
    by deterministic scoring.  Priority order (highest first):

    {ol
     {- Sonarr/Radarr hard rejection}
     {- Selectarr hard rules}
     {- structured preferences}
     {- natural-language preferences}
     {- deterministic scoring}
     {- the model's own defaults}} *)

(** [contains_ci ~needle ~haystack] is a case-insensitive substring test.  It
    is exposed because the hard rules, the explainability layer and the
    natural-language preference scan must agree on what "mentions" means. *)
val contains_ci : needle:string -> haystack:string -> bool

(** [normalise_codec s] maps the common spellings of a video codec onto a
    single canonical name, e.g. ["hevc"], ["H.265"] and ["x265"] all become
    ["x265"], and ["h264"]/["AVC"] become ["x264"].  Unknown codecs are
    returned trimmed and otherwise unchanged. *)
val normalise_codec : string -> string

(** [normalise_source s] maps the common spellings of a release source onto a
    canonical name: ["WEB-DL"], ["WEBRip"], ["Bluray"], ["Remux"], ["HDTV"],
    ["DVD"], ["SDTV"], ["CAM"].  Unknown sources are returned trimmed and
    otherwise unchanged. *)
val normalise_source : string -> string

(** [is_remux release] is [true] when the release is a remux according to the
    Sonarr/Radarr quality modifier, the quality name or the parsed source. *)
val is_remux : Types.release -> bool

(** [check rules release] returns every hard rule the release violates.  An
    empty list means the release is a valid candidate.  All applicable
    reasons are returned, not just the first one. *)
val check : Config.hard_rules -> Types.release -> Types.rejection list

(** [partition rules releases] splits [releases] into the candidates that
    pass every hard rule (order preserved) and the rejected ones with their
    structured reasons. *)
val partition :
  Config.hard_rules ->
  Types.release list ->
  Types.release list * Types.rejected_release list
