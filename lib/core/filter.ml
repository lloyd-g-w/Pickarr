(* Stage 2: deterministic hard filtering.  Pure module. *)

(* ------------------------------------------------------------------------ *)
(* String helpers                                                            *)
(* ------------------------------------------------------------------------ *)

let lower = String.lowercase_ascii

(* Keep only letters and digits, lowercased: "H.265" -> "h265". *)
let alnum_key (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' -> Buffer.add_char b c
      | 'A' .. 'Z' -> Buffer.add_char b (Char.lowercase_ascii c)
      | _ -> ())
    s;
  Buffer.contents b

(* Case-insensitive substring test. *)
let contains_ci ~(needle : string) ~(haystack : string) : bool =
  let n = lower needle and h = lower haystack in
  let ln = String.length n and lh = String.length h in
  if ln = 0 then false
  else if ln > lh then false
  else (
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= lh - ln do
      if String.sub h !i ln = n then found := true else incr i
    done;
    !found)

let equal_ci a b = lower (String.trim a) = lower (String.trim b)

(* ------------------------------------------------------------------------ *)
(* Normalisation                                                             *)
(* ------------------------------------------------------------------------ *)

let normalise_codec (s : string) : string =
  match alnum_key s with
  | "x265" | "h265" | "hevc" | "hx265" -> "x265"
  | "x264" | "h264" | "avc" -> "x264"
  | "av1" -> "AV1"
  | "vp9" -> "VP9"
  | "xvid" -> "XviD"
  | "divx" -> "DivX"
  | "vc1" -> "VC-1"
  | "mpeg2" | "mpeg2video" -> "MPEG-2"
  | "mpeg4" -> "MPEG-4"
  | "" -> String.trim s
  | _ -> String.trim s

let normalise_source (s : string) : string =
  match alnum_key s with
  | "webdl" | "web" | "webdlrip" -> "WEB-DL"
  | "webrip" -> "WEBRip"
  | "bluray" | "blu" | "bd" | "bdrip" | "brrip" | "bluraydisc" | "blurayraw" ->
      "Bluray"
  | "remux" | "blurayremux" | "bdremux" -> "Remux"
  | "hdtv" | "television" | "televisionraw" -> "HDTV"
  | "dvd" | "dvdrip" -> "DVD"
  | "sdtv" -> "SDTV"
  | "cam" | "camrip" | "hdcam" -> "CAM"
  | "" -> String.trim s
  | _ -> String.trim s

let is_remux (r : Types.release) : bool =
  let by_modifier =
    match r.Types.quality_modifier with
    | Some m -> equal_ci m "remux"
    | None -> false
  in
  let by_source =
    match r.Types.source with Some s -> normalise_source s = "Remux" | None -> false
  in
  let by_quality =
    match r.Types.quality with
    | Some q -> contains_ci ~needle:"remux" ~haystack:q
    | None -> false
  in
  by_modifier || by_source || by_quality

(* ------------------------------------------------------------------------ *)
(* Hard rules                                                                *)
(* ------------------------------------------------------------------------ *)

let hard (rule : string) (message : string) : Types.rejection =
  { Types.rule; message; stage = Types.Hard_rule }

let arr (rule : string) (message : string) : Types.rejection =
  { Types.rule; message; stage = Types.Arr_rejection }

let fmt_gib (g : float) : string = Printf.sprintf "%.2f GiB" g

(* Reject on a title pattern.  Patterns that look like regular expressions are
   compiled with Re.Perl; anything that fails to compile (and anything that
   looks like plain text) is matched as a case-insensitive substring. *)
let title_matches_pattern ~(pattern : string) ~(title : string) : bool =
  let looks_like_regex =
    String.exists
      (fun c ->
        match c with
        | '[' | ']' | '(' | ')' | '{' | '}' | '|' | '*' | '+' | '?' | '^' | '$'
        | '\\' ->
            true
        | _ -> false)
      pattern
  in
  if looks_like_regex then
    match
      (try Some (Re.compile (Re.Perl.re ~opts:[ `Caseless ] pattern))
       with _ -> None)
    with
    | Some re -> ( try Re.execp re title with _ -> false)
    | None -> contains_ci ~needle:pattern ~haystack:title
  else contains_ci ~needle:pattern ~haystack:title

let check_size (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  let gib = Types.gib_of_bytes r.Types.size_bytes in
  let too_big =
    match h.Config.max_size_gib with
    | Some max when gib > max ->
        [
          hard "max_size"
            (Printf.sprintf "Size %s exceeds the maximum of %s" (fmt_gib gib)
               (fmt_gib max));
        ]
    | _ -> []
  in
  let too_small =
    match h.Config.min_size_gib with
    | Some min when gib < min ->
        [
          hard "min_size"
            (Printf.sprintf "Size %s is below the minimum of %s" (fmt_gib gib)
               (fmt_gib min));
        ]
    | _ -> []
  in
  too_big @ too_small

(* Seeders only make sense for torrents; usenet releases are exempt.  An
   unknown seeder count cannot be checked and therefore passes. *)
let check_seeders (h : Config.hard_rules) (r : Types.release) : Types.rejection list
    =
  match (h.Config.min_seeders, r.Types.protocol, r.Types.seeders) with
  | Some min, Types.Torrent, Some s when s < min ->
      [
        hard "min_seeders"
          (Printf.sprintf "Only %d seeder(s), minimum is %d" s min);
      ]
  | _ -> []

let check_group (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  match r.Types.release_group with
  | Some g when List.exists (fun b -> equal_ci b g) h.Config.blocked_groups ->
      [ hard "blocked_group" (Printf.sprintf "Release group %s is blocked" g) ]
  | _ -> []

let check_codec (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  let codec = Option.map normalise_codec r.Types.codec in
  let blocked =
    match codec with
    | Some c
      when List.exists
             (fun b -> normalise_codec b = c)
             h.Config.blocked_codecs ->
        [ hard "blocked_codec" (Printf.sprintf "Codec %s is blocked" c) ]
    | _ -> []
  in
  let not_allowed =
    match (h.Config.allowed_codecs, codec) with
    | [], _ -> []
    | allowed, Some c
      when not (List.exists (fun a -> normalise_codec a = c) allowed) ->
        [
          hard "codec_not_allowed"
            (Printf.sprintf "Codec %s is not in the allowed codecs (%s)" c
               (String.concat ", " (List.map normalise_codec allowed)));
        ]
    | _ -> []
  in
  let unknown =
    match codec with
    | None when h.Config.reject_unknown_codec ->
        [ hard "unknown_codec" "The codec could not be determined" ]
    | Some "" when h.Config.reject_unknown_codec ->
        [ hard "unknown_codec" "The codec could not be determined" ]
    | _ -> []
  in
  blocked @ not_allowed @ unknown

let check_languages (h : Config.hard_rules) (r : Types.release) :
    Types.rejection list =
  let blocked =
    List.filter
      (fun l -> List.exists (fun b -> equal_ci b l) h.Config.blocked_languages)
      r.Types.languages
  in
  let blocked =
    match blocked with
    | [] -> []
    | ls ->
        [
          hard "blocked_language"
            (Printf.sprintf "Language %s is blocked" (String.concat ", " ls));
        ]
  in
  let required =
    match h.Config.required_languages with
    | [] -> []
    | req ->
        if
          List.exists
            (fun l -> List.exists (fun rq -> equal_ci rq l) r.Types.languages)
            req
        then []
        else
          [
            hard "missing_required_language"
              (Printf.sprintf "None of the required languages (%s) were found%s"
                 (String.concat ", " req)
                 (if r.Types.languages = [] then
                    "; the release declares no language"
                  else "; release languages: " ^ String.concat ", " r.Types.languages));
          ]
  in
  blocked @ required

let check_hdr (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  let remux =
    if (not h.Config.allow_remux) && is_remux r then
      [ hard "remux_not_allowed" "Remux releases are not allowed" ]
    else []
  in
  let dv =
    if (not h.Config.allow_dolby_vision) && r.Types.dolby_vision then
      [ hard "dolby_vision_not_allowed" "Dolby Vision releases are not allowed" ]
    else []
  in
  let dv_fallback =
    if
      h.Config.require_hdr10_fallback_for_dv && r.Types.dolby_vision
      && (r.Types.hdr = [] || r.Types.dv_profile = Some "P5")
    then
      [
        hard "dv_no_hdr10_fallback"
          (Printf.sprintf
             "Dolby Vision without an HDR10 fallback%s is not allowed"
             (match r.Types.dv_profile with
             | Some p -> " (profile " ^ p ^ ")"
             | None -> ""));
      ]
    else []
  in
  let hdr =
    if (not h.Config.allow_hdr) && r.Types.hdr <> [] then
      [
        hard "hdr_not_allowed"
          (Printf.sprintf "HDR releases are not allowed (%s)"
             (String.concat ", " r.Types.hdr));
      ]
    else []
  in
  let blocked_formats =
    let hit =
      List.filter
        (fun f ->
          List.exists (fun b -> equal_ci b f) h.Config.blocked_hdr_formats)
        r.Types.hdr
    in
    match hit with
    | [] -> []
    | fs ->
        [
          hard "blocked_hdr_format"
            (Printf.sprintf "HDR format %s is blocked" (String.concat ", " fs));
        ]
  in
  remux @ dv @ dv_fallback @ hdr @ blocked_formats

let check_resolution (h : Config.hard_rules) (r : Types.release) :
    Types.rejection list =
  match (h.Config.allowed_resolutions, r.Types.resolution) with
  | [], _ -> []
  | allowed, Some res when not (List.mem res allowed) ->
      [
        hard "resolution_not_allowed"
          (Printf.sprintf "Resolution %dp is not allowed (allowed: %s)" res
             (String.concat ", "
                (List.map (fun a -> string_of_int a ^ "p") allowed)));
      ]
  | _ -> []

let check_protocol (h : Config.hard_rules) (r : Types.release) :
    Types.rejection list =
  match h.Config.allowed_protocols with
  | [] -> []
  | allowed when not (List.mem r.Types.protocol allowed) ->
      [
        hard "protocol_not_allowed"
          (Printf.sprintf "Protocol %s is not allowed (allowed: %s)"
             (Types.protocol_to_string r.Types.protocol)
             (String.concat ", "
                (List.map Types.protocol_to_string allowed)));
      ]
  | _ -> []

let check_title (h : Config.hard_rules) (r : Types.release) : Types.rejection list
    =
  List.filter_map
    (fun pattern ->
      if pattern = "" then None
      else if title_matches_pattern ~pattern ~title:r.Types.title then
        Some
          (hard "blocked_title_pattern"
             (Printf.sprintf "Title matches the blocked pattern %S" pattern))
      else None)
    h.Config.blocked_title_patterns

(* Sonarr/Radarr's own verdict.  A hard rejection from the *arr application is
   the highest-priority rule and is always honoured.  A temporary rejection
   (e.g. "release is still seeding", retry later) only rejects when the user
   asked us to respect *arr rejections. *)
(* Rejections that mean Sonarr/Radarr could not map the release to the
   series/movie (the grab would 404) or has blocklisted it.  These stay hard
   even when the user chose not to respect *arr rejections.  Wording from
   vendor/sonarr-DownloadDecisionMaker.cs and the Radarr equivalent. *)
let unrecoverable_arr_rejection (message : string) : bool =
  let m = String.lowercase_ascii message in
  List.exists
    (fun needle -> contains_ci ~needle ~haystack:m)
    [
      "unknown series";
      "unknown movie";
      "unable to identify";
      "unable to parse";
      "matches an alias";
      "unexpected error";
      "blocklist";
    ]

let check_arr (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  let reasons_of kind =
    match r.Types.arr_rejection_reasons with
    | [] ->
        [
          arr "arr_rejection"
            (Printf.sprintf "%s rejected this release" kind);
        ]
    | rs -> List.map (fun m -> arr "arr_rejection" m) rs
  in
  if h.Config.respect_arr_rejections then
    if r.Types.arr_rejected then reasons_of "Sonarr/Radarr"
    else if r.Types.arr_temporarily_rejected then reasons_of "Sonarr/Radarr temporarily"
    else []
  else if r.Types.arr_rejected || r.Types.arr_temporarily_rejected then
    (* Soft mode: only the unrecoverable reasons still reject. *)
    r.Types.arr_rejection_reasons
    |> List.filter unrecoverable_arr_rejection
    |> List.map (fun m -> arr "arr_rejection_unrecoverable" m)
  else []

let check (h : Config.hard_rules) (r : Types.release) : Types.rejection list =
  check_arr h r @ check_size h r @ check_seeders h r @ check_group h r
  @ check_codec h r @ check_languages h r @ check_hdr h r @ check_resolution h r
  @ check_protocol h r @ check_title h r

let partition (h : Config.hard_rules) (releases : Types.release list) :
    Types.release list * Types.rejected_release list =
  let rec go acc_ok acc_bad = function
    | [] -> (List.rev acc_ok, List.rev acc_bad)
    | r :: tl -> (
        match check h r with
        | [] -> go (r :: acc_ok) acc_bad tl
        | reasons ->
            go acc_ok ({ Types.release = r; reasons } :: acc_bad) tl)
  in
  go [] [] releases

(* ------------------------------------------------------------------------ *)
(* Season packs                                                              *)
(* ------------------------------------------------------------------------ *)

(* A season search ([GET /api/v3/release?seriesId=&seasonNumber=]) also
   returns single episodes of that season, so a season selection has to drop
   everything that is not a pack for the season being filled. *)
let season_pack_reasons (wanted_season : int option) (r : Types.release) :
    Types.rejection list =
  if not r.Types.full_season then
    [
      hard "not_season_pack"
        "Not a season pack: this release covers single episodes";
    ]
  else
    match (wanted_season, r.Types.season_number) with
    | Some wanted, Some got when wanted <> got ->
        [
          hard "not_season_pack"
            (Printf.sprintf "Season pack for season %d, not season %d" got wanted);
        ]
    | _ -> []

let season_pack_partition (media : Types.media) (releases : Types.release list) :
    Types.release list * Types.rejected_release list =
  match media.Types.media_kind with
  | "season" ->
      let rec go acc_ok acc_bad = function
        | [] -> (List.rev acc_ok, List.rev acc_bad)
        | r :: tl -> (
            match season_pack_reasons media.Types.season_number r with
            | [] -> go (r :: acc_ok) acc_bad tl
            | reasons -> go acc_ok ({ Types.release = r; reasons } :: acc_bad) tl)
      in
      go [] [] releases
  | _ -> (releases, [])
