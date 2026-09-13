(* Stage 3: deterministic scoring.  Pure module. *)

let position_weight (base : float) (index : int) : float =
  let factor = 1.0 -. (0.1 *. float_of_int index) in
  base *. Float.max 0.5 factor

(* Index of the first entry of [list] that satisfies [eq], if any. *)
let find_index (eq : string -> bool) (list : string list) : int option =
  let rec go i = function
    | [] -> None
    | x :: tl -> if eq x then Some i else go (i + 1) tl
  in
  go 0 list

let find_index_int (value : int) (list : int list) : int option =
  let rec go i = function
    | [] -> None
    | x :: tl -> if x = value then Some i else go (i + 1) tl
  in
  go 0 list

let component (component : string) (points : float) (detail : string) :
    Types.score_component =
  { Types.component; points; detail }

let fmt_gib (g : float) : string = Printf.sprintf "%.2f GiB" g

(* ------------------------------------------------------------------------ *)
(* Individual contributions                                                  *)
(* ------------------------------------------------------------------------ *)

let custom_format_component (w : Config.weights) (r : Types.release) =
  match r.Types.custom_format_score with
  | Some s when s <> 0 && w.Config.w_custom_format <> 0. ->
      [
        component "custom_format"
          (float_of_int s *. w.Config.w_custom_format)
          (Printf.sprintf "Sonarr/Radarr Custom Format score of %d" s);
      ]
  | _ -> []

let quality_weight_component (w : Config.weights) (r : Types.release) =
  match r.Types.quality_weight with
  | Some qw when qw <> 0 && w.Config.w_quality_weight <> 0. ->
      [
        component "quality_weight"
          (float_of_int qw *. w.Config.w_quality_weight)
          (Printf.sprintf "Sonarr/Radarr quality weight of %d" qw);
      ]
  | _ -> []

(* Intrinsic source quality: Blu-ray/Remux > WEB-DL > WEBRip and friends. *)
let source_component (w : Config.weights) (r : Types.release) =
  let source =
    match r.Types.source with
    | Some s -> Some (Filter.normalise_source s)
    | None -> (
        match r.Types.quality_source with
        | Some qs -> Some (Filter.normalise_source qs)
        | None -> None)
  in
  match source with
  | Some "WEB-DL" ->
      [
        component "source" w.Config.w_web_dl_over_webrip
          "WEB-DL is preferred over WEBRip";
      ]
  | Some ("Bluray" | "Remux") ->
      let pts = w.Config.w_web_dl_over_webrip +. w.Config.w_bluray_over_web in
      [ component "source" pts "Blu-ray source is preferred over web sources" ]
  | Some _ | None -> []

let preferred_source_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match r.Types.source with
  | None -> []
  | Some s ->
      let s = Filter.normalise_source s in
      let remux = Filter.is_remux r in
      (* A remux also counts as a match for a "Remux" preference entry. *)
      let eq entry =
        let e = Filter.normalise_source entry in
        e = s || (remux && e = "Remux")
      in
      (match find_index eq p.Config.preferred_sources with
      | Some i ->
          let pts = position_weight w.Config.w_preferred_source i in
          [
            component "source_preferred" pts
              (Printf.sprintf "%s is in your preferred sources" s);
          ]
      | None -> [])

let codec_components (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match r.Types.codec with
  | None -> []
  | Some c ->
      let c = Filter.normalise_codec c in
      let eq entry = Filter.normalise_codec entry = c in
      let preferred =
        match find_index eq p.Config.preferred_codecs with
        | Some i ->
            [
              component "codec_preferred"
                (position_weight w.Config.w_preferred_codec i)
                (Printf.sprintf "%s is in your preferred codecs" c);
            ]
        | None -> []
      in
      let disliked =
        match find_index eq p.Config.disliked_codecs with
        | Some i ->
            [
              component "codec_disliked"
                (position_weight w.Config.w_disliked_codec i)
                (Printf.sprintf "%s is in your disliked codecs" c);
            ]
        | None -> []
      in
      preferred @ disliked

let group_components (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match r.Types.release_group with
  | None -> []
  | Some g ->
      let eq entry = String.lowercase_ascii entry = String.lowercase_ascii g in
      let preferred =
        match find_index eq p.Config.preferred_groups with
        | Some i ->
            [
              component "group_preferred"
                (position_weight w.Config.w_preferred_group i)
                (Printf.sprintf "%s is in your preferred groups" g);
            ]
        | None -> []
      in
      let disliked =
        match find_index eq p.Config.disliked_groups with
        | Some i ->
            [
              component "group_disliked"
                (position_weight w.Config.w_disliked_group i)
                (Printf.sprintf "%s is in your disliked groups" g);
            ]
        | None -> []
      in
      preferred @ disliked

let language_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  (* Best (lowest) position among the release's languages. *)
  let best =
    List.fold_left
      (fun acc l ->
        let eq entry =
          String.lowercase_ascii entry = String.lowercase_ascii l
        in
        match find_index eq p.Config.preferred_languages with
        | Some i -> (
            match acc with
            | Some (bi, _) when bi <= i -> acc
            | _ -> Some (i, l))
        | None -> acc)
      None r.Types.languages
  in
  match best with
  | Some (i, l) ->
      [
        component "language"
          (position_weight w.Config.w_preferred_language i)
          (Printf.sprintf "%s is in your preferred languages" l);
      ]
  | None -> []

let resolution_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match r.Types.resolution with
  | None -> []
  | Some res -> (
      match find_index_int res p.Config.preferred_resolutions with
      | Some i ->
          [
            component "resolution"
              (position_weight w.Config.w_preferred_resolution i)
              (Printf.sprintf "%dp is in your preferred resolutions" res);
          ]
      | None -> [])

let audio_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match r.Types.audio with
  | None -> []
  | Some a -> (
      let eq entry =
        String.lowercase_ascii entry = String.lowercase_ascii a
        || Filter.normalise_codec entry = Filter.normalise_codec a
      in
      match find_index eq p.Config.preferred_audio with
      | Some i ->
          [
            component "audio"
              (position_weight w.Config.w_preferred_audio i)
              (Printf.sprintf "%s is in your preferred audio formats" a);
          ]
      | None -> [])

let hdr_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  if r.Types.hdr = [] then []
  else
    let formats = String.concat ", " r.Types.hdr in
    match String.lowercase_ascii p.Config.hdr_preference with
    | "prefer" ->
        [
          component "hdr" w.Config.w_hdr
            (Printf.sprintf "%s matches your HDR preference" formats);
        ]
    | "avoid" ->
        [
          component "hdr" (-.w.Config.w_hdr)
            (Printf.sprintf "%s is penalised because you prefer to avoid HDR"
               formats);
        ]
    | _ -> []

let dolby_vision_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  if not r.Types.dolby_vision then []
  else
    match String.lowercase_ascii p.Config.dolby_vision_preference with
    | "prefer" ->
        [
          component "dolby_vision" w.Config.w_dolby_vision
            "Dolby Vision matches your preference";
        ]
    | "avoid" ->
        [
          component "dolby_vision" (-.w.Config.w_dolby_vision)
            "Dolby Vision is penalised because you prefer to avoid it";
        ]
    | _ -> []

let remux_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  if p.Config.prefer_remux && Filter.is_remux r then
    [ component "remux" w.Config.w_remux "Remux matches your preference for remuxes" ]
  else []

let repack_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  if p.Config.prefer_repacks && (r.Types.is_repack || r.Types.is_proper) then
    [
      component "repack" w.Config.w_repack
        (if r.Types.is_repack then "Repack releases are preferred"
         else "Proper releases are preferred");
    ]
  else []

let seeders_component (w : Config.weights) (r : Types.release) =
  match (r.Types.protocol, r.Types.seeders) with
  | Types.Torrent, Some s when s > 0 && w.Config.w_seeders <> 0. ->
      let raw = w.Config.w_seeders *. (log (float_of_int (s + 1)) /. log 2.) in
      let pts =
        if w.Config.w_seeders_cap > 0. then Float.min w.Config.w_seeders_cap raw
        else raw
      in
      [ component "seeders" pts (Printf.sprintf "%d seeders" s) ]
  | _ -> []

(* Penalty for being outside the preferred size window
   [ideal - tolerance, ideal + tolerance]. *)
let size_component (p : Config.preferences) (w : Config.weights)
    (r : Types.release) =
  match p.Config.ideal_size_gib with
  | None -> []
  | Some ideal ->
      let gib = Types.gib_of_bytes r.Types.size_bytes in
      let tolerance = Float.abs p.Config.size_tolerance_gib in
      let excess = Float.abs (gib -. ideal) -. tolerance in
      if excess <= 0. then
        [
          component "size" 0.
            (Printf.sprintf "%s is within your preferred size range (%s ± %s)"
               (fmt_gib gib) (fmt_gib ideal) (fmt_gib tolerance));
        ]
      else
        [
          component "size"
            (-.(excess *. w.Config.w_size_penalty_per_gib))
            (Printf.sprintf "%s is %s outside your preferred size range"
               (fmt_gib gib) (fmt_gib excess));
        ]

let arr_approved_component (w : Config.weights) (r : Types.release) =
  if r.Types.arr_approved && w.Config.w_arr_approved <> 0. then
    [
      component "arr_approved" w.Config.w_arr_approved
        "Approved by Sonarr/Radarr";
    ]
  else []

(* Only reachable when respect_arr_rejections is off (otherwise the filter
   has already removed these releases). *)
let arr_rejected_component (w : Config.weights) (r : Types.release) =
  if (r.Types.arr_rejected || r.Types.arr_temporarily_rejected)
     && w.Config.w_arr_rejected <> 0.
  then
    let why =
      match r.Types.arr_rejection_reasons with
      | [] -> "no reason given"
      | rs -> String.concat "; " rs
    in
    [
      component "arr_rejected" w.Config.w_arr_rejected
        (Printf.sprintf "Sonarr/Radarr rejected it (%s) but you chose not to respect their rejections" why);
    ]
  else []

let age_component (w : Config.weights) (r : Types.release) =
  match r.Types.age_hours with
  | Some h when h > 0. && w.Config.w_age_penalty_per_day > 0. ->
      let days = h /. 24. in
      let raw = days *. w.Config.w_age_penalty_per_day in
      let penalty =
        if w.Config.w_age_penalty_cap > 0. then
          Float.min w.Config.w_age_penalty_cap raw
        else raw
      in
      [
        component "age" (-.penalty)
          (Printf.sprintf "Release is %.0f day(s) old" days);
      ]
  | _ -> []

(* ------------------------------------------------------------------------ *)
(* Public API                                                                *)
(* ------------------------------------------------------------------------ *)

let score (p : Config.preferences) (w : Config.weights) (_media : Types.media)
    (r : Types.release) : Types.scored_release =
  let components =
    List.concat
      [
        custom_format_component w r;
        quality_weight_component w r;
        source_component w r;
        preferred_source_component p w r;
        codec_components p w r;
        group_components p w r;
        language_component p w r;
        resolution_component p w r;
        audio_component p w r;
        hdr_component p w r;
        dolby_vision_component p w r;
        remux_component p w r;
        repack_component p w r;
        seeders_component w r;
        size_component p w r;
        arr_approved_component w r;
        arr_rejected_component w r;
        age_component w r;
      ]
  in
  let total =
    List.fold_left (fun acc c -> acc +. c.Types.points) 0. components
  in
  { Types.scored = r; score = total; components }

let compare_scored (a : Types.scored_release) (b : Types.scored_release) : int =
  (* Best first: highest score, then Custom Format score, then seeders, then
     title for a fully deterministic order. *)
  let cmp = compare b.Types.score a.Types.score in
  if cmp <> 0 then cmp
  else
    let cf s = Option.value s.Types.scored.Types.custom_format_score ~default:0 in
    let cmp = compare (cf b) (cf a) in
    if cmp <> 0 then cmp
    else
      let sd s = Option.value s.Types.scored.Types.seeders ~default:0 in
      let cmp = compare (sd b) (sd a) in
      if cmp <> 0 then cmp
      else String.compare a.Types.scored.Types.title b.Types.scored.Types.title

let rank (p : Config.preferences) (w : Config.weights) (media : Types.media)
    (releases : Types.release list) : Types.scored_release list =
  List.map (score p w media) releases |> List.stable_sort compare_scored
