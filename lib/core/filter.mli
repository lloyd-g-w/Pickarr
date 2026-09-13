(** Stage 2 of the selection pipeline: deterministic hard rules.

    Hard rules decide what Pickarr is *allowed* to choose.  They are pure
    and are never overridable by the LLM, by natural-language preferences or
    by deterministic scoring.  Priority order (highest first):

    {ol
     {- Sonarr/Radarr hard rejection}
     {- Pickarr hard rules}
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
    reasons are returned, not just the first one.

    Notes on individual rules:
    - [min_seeders] only applies to torrents, and an unknown seeder count
      cannot be checked and therefore passes.
    - [allowed_codecs]/[allowed_resolutions] only reject releases whose codec
      or resolution is known; an undetectable codec is rejected only when
      [reject_unknown_codec] is set.
    - a hard rejection from Sonarr/Radarr always rejects; a temporary *arr
      rejection only rejects when [respect_arr_rejections] is set. *)
val check : Config.hard_rules -> Types.release -> Types.rejection list

(** [partition rules releases] splits [releases] into the candidates that
    pass every hard rule (order preserved) and the rejected ones with their
    structured reasons. *)
val partition :
  Config.hard_rules ->
  Types.release list ->
  Types.release list * Types.rejected_release list

(** [season_pack_partition media releases] keeps only releases that can fill
    a whole season when [media.media_kind = "season"]: a release that is not
    a full-season pack, or is a pack for a different season, is rejected with
    the rule ["not_season_pack"] (stage {!Types.Hard_rule}).  Sonarr's season
    search returns single episodes of the season as well, which is why this
    is needed.  For every other media kind both lists pass through unchanged.

    Applied before {!partition} so that the user still sees why a release was
    dropped. *)
val season_pack_partition :
  Types.media ->
  Types.release list ->
  Types.release list * Types.rejected_release list
