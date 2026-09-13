(** "Convert to structured rules": ask the model to translate the user's
    natural-language preferences into concrete structured settings.

    Nothing here changes the configuration.  {!parse} only produces a
    configuration patch and a human-readable summary that must be shown to
    the user for explicit approval first. *)

(** System message: convert prose into structured settings, never invent hard
    rules the user did not ask for, answer with strict JSON. *)
val system_prompt : string

(** [build_prompt config text] renders the user message: the current
    structured settings plus the prose to convert and the whitelist of
    fields the model may propose. *)
val build_prompt : Config.t -> string -> string

(** [parse json] validates
    [{"proposals": [{"section", "field", "value", "rationale"}]}] and returns
    a patch shaped like {!Config.to_yojson}
    ([{"preferences": {...}, "hard_rules": {...}, "weights": {...}}]) that can
    be fed to {!Config.patch}, together with one summary line per proposal
    such as ["Preferred codecs: x265, x264"] or ["Preferred codec bonus:
    +15"].

    Unknown sections, unknown fields and values of the wrong JSON type are
    rejected with an explanatory message.  Never raises. *)
val parse : Yojson.Safe.t -> (Yojson.Safe.t * string list, string) result
