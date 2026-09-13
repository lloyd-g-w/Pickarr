(* Explainability.  Pure module. *)

let contains_ci ~needle ~haystack = Filter.contains_ci ~needle ~haystack

let dedup (items : string list) : string list =
  let rec go seen = function
    | [] -> []
    | x :: tl ->
        let key = String.trim x in
        if key = "" || List.mem key seen then go seen tl
        else key :: go (key :: seen) tl
  in
  go [] items

let fmt_gib (g : float) : string = Printf.sprintf "%.2f GiB" g

(* Spellings the user might use for a codec, so that "prefer HEVC" is
   recognised as a mention of a blocked "x265". *)
let codec_aliases (codec : string) : string list =
  match Filter.normalise_codec codec with
  | "x265" -> [ "x265"; "h265"; "h.265"; "hevc" ]
  | "x264" -> [ "x264"; "h264"; "h.264"; "avc" ]
  | "AV1" -> [ "av1" ]
  | "VP9" -> [ "vp9" ]
  | "XviD" -> [ "xvid" ]
  | "DivX" -> [ "divx" ]
  | "VC-1" -> [ "vc-1"; "vc1" ]
  | "MPEG-2" -> [ "mpeg-2"; "mpeg2" ]
  | other -> [ other ]

let mentions (text : string) (needles : string list) : bool =
  List.exists (fun needle -> contains_ci ~needle ~haystack:text) needles

(* ------------------------------------------------------------------------ *)
(* Conflicts between natural-language wishes and hard rules                  *)
(* ------------------------------------------------------------------------ *)

let hard_rule_conflicts ~(config : Config.t)
    ~(instance : Config.instance option) : string list =
  let text = Config.effective_nl_preferences config instance in
  if String.trim text = "" then []
  else
    let h = config.Config.hard_rules in
    let codec_conflicts =
      List.filter_map
        (fun blocked ->
          let name = Filter.normalise_codec blocked in
          if mentions text (codec_aliases blocked) then
            Some
              (Printf.sprintf
                 "You said you prefer %s, but %s is blocked by a hard codec \
                  rule."
                 name name)
          else None)
        h.Config.blocked_codecs
    in
    let allowed_codec_conflicts =
      match h.Config.allowed_codecs with
      | [] -> []
      | allowed ->
          (* A codec the user asks for that is not on the allow-list. *)
          let known =
            [ "x265"; "x264"; "AV1"; "VP9"; "XviD"; "DivX"; "VC-1"; "MPEG-2" ]
          in
          List.filter_map
            (fun codec ->
              let is_allowed =
                List.exists
                  (fun a -> Filter.normalise_codec a = codec)
                  allowed
              in
              if
                (not is_allowed)
                && (not
                      (List.exists
                         (fun b -> Filter.normalise_codec b = codec)
                         h.Config.blocked_codecs))
                && mentions text (codec_aliases codec)
              then
                Some
                  (Printf.sprintf
                     "You mentioned %s, but only these codecs are allowed by a \
                      hard rule: %s."
                     codec
                     (String.concat ", "
                        (List.map Filter.normalise_codec allowed)))
              else None)
            known
    in
    let group_conflicts =
      List.filter_map
        (fun blocked ->
          if mentions text [ blocked ] then
            Some
              (Printf.sprintf
                 "You mentioned %s, but %s is in your blocked release groups."
                 blocked blocked)
          else None)
        h.Config.blocked_groups
    in
    let remux_conflict =
      if (not h.Config.allow_remux) && mentions text [ "remux" ] then
        [
          "You mentioned remuxes, but remuxes are blocked by a hard rule.";
        ]
      else []
    in
    let dv_conflict =
      if
        (not h.Config.allow_dolby_vision)
        && mentions text [ "dolby vision"; "dovi"; "dv " ]
      then
        [
          "You mentioned Dolby Vision, but Dolby Vision is blocked by a hard \
           rule.";
        ]
      else []
    in
    let hdr_conflict =
      if (not h.Config.allow_hdr) && mentions text [ "hdr" ] then
        [ "You mentioned HDR, but HDR releases are blocked by a hard rule." ]
      else []
    in
    let size_conflict =
      match h.Config.max_size_gib with
      | Some max
        when mentions text
               [
                 "regardless of size";
                 "ignore size";
                 "no matter the size";
                 "largest";
                 "biggest";
                 "best possible quality";
               ] ->
          [
            Printf.sprintf
              "You asked for the best quality regardless of size, but a hard \
               maximum size of %s applies."
              (fmt_gib max);
          ]
      | _ -> []
    in
    dedup
      (codec_conflicts @ allowed_codec_conflicts @ group_conflicts
      @ remux_conflict @ dv_conflict @ hdr_conflict @ size_conflict)

(* ------------------------------------------------------------------------ *)
(* Why this release                                                          *)
(* ------------------------------------------------------------------------ *)

(* The scoring components already carry user-facing wording; only meaningful
   contributions are shown. *)
let component_bullets (selected : Types.scored_release) : string list =
  List.filter_map
    (fun (c : Types.score_component) ->
      if Float.abs c.Types.points < 0.5 && c.Types.component <> "size" then None
      else Some c.Types.detail)
    selected.Types.components

let size_bullet (config : Config.t) (selected : Types.scored_release) :
    string list =
  let gib = Types.gib_of_bytes selected.Types.scored.Types.size_bytes in
  let has_size_component =
    List.exists
      (fun (c : Types.score_component) -> c.Types.component = "size")
      selected.Types.components
  in
  if has_size_component then []
  else
    match config.Config.hard_rules.Config.max_size_gib with
    | Some max ->
        [
          Printf.sprintf "%s is within your maximum size of %s" (fmt_gib gib)
            (fmt_gib max);
        ]
    | None -> []

(* "larger alternatives offered little expected quality benefit" *)
let size_tradeoff_bullet (selected : Types.scored_release)
    (candidates : Types.scored_release list) : string list =
  let size s = s.Types.scored.Types.size_bytes in
  let larger =
    List.filter (fun c -> size c > size selected) candidates |> List.length
  in
  if larger > 0 then
    [
      Printf.sprintf
        "%d larger alternative(s) offered little expected quality benefit"
        larger;
    ]
  else []

let upgrade_bullet (media : Types.media) : string list =
  match (media.Types.has_file, media.Types.existing_quality) with
  | true, Some q -> [ Printf.sprintf "replaces the existing %s file" q ]
  | true, None -> [ "replaces the file already in your library" ]
  | false, _ -> []

let rejected_bullet (rejected : Types.rejected_release list) : string list =
  match List.length rejected with
  | 0 -> []
  | n ->
      [
        Printf.sprintf "%d other release(s) were rejected by hard rules or by \
                        Sonarr/Radarr"
          n;
      ]

let explain ~(config : Config.t) ~(instance : Config.instance option)
    ~(media : Types.media) ~(selected : Types.scored_release)
    ~(candidates : Types.scored_release list)
    ~(rejected : Types.rejected_release list)
    ~(llm : Types.llm_decision option) : string list * string list =
  let llm_influences =
    match llm with Some d -> d.Types.influences | None -> []
  in
  let explanation =
    dedup
      (llm_influences @ component_bullets selected
      @ size_bullet config selected
      @ size_tradeoff_bullet selected candidates
      @ upgrade_bullet media @ rejected_bullet rejected)
  in
  let llm_conflicts = match llm with Some d -> d.Types.conflicts | None -> [] in
  let conflicts = dedup (hard_rule_conflicts ~config ~instance @ llm_conflicts) in
  (explanation, conflicts)
