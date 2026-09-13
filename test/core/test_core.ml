(* Tests for the Pickarr selection pipeline (lib/core). *)

module Types = Pickarr_core.Types
module Config = Pickarr_core.Config
module Filter = Pickarr_core.Filter
module Scoring = Pickarr_core.Scoring
module Prompt = Pickarr_core.Prompt
module Llm_response = Pickarr_core.Llm_response
module Explain = Pickarr_core.Explain
module Pipeline = Pickarr_core.Pipeline
module Rules_proposal = Pickarr_core.Rules_proposal

(* ------------------------------------------------------------------------ *)
(* Fixtures                                                                  *)
(* ------------------------------------------------------------------------ *)

let mk_release ?(id = "r1") ?(title = "Movie.2026.1080p.WEB-DL.x265-FLUX")
    ?(size_gib = 6.2) ?(seeders = Some 40) ?(protocol = Types.Torrent)
    ?(quality = Some "WEBDL-1080p") ?(quality_source = Some "web")
    ?(resolution = Some 1080) ?(quality_modifier = None) ?(quality_weight = None)
    ?(source = Some "WEB-DL") ?(codec = Some "x265") ?(audio = Some "DDP")
    ?(hdr = []) ?(dolby_vision = false) ?(dv_profile = None)
    ?(release_group = Some "FLUX") ?(languages = [ "English" ])
    ?(custom_formats = []) ?(custom_format_score = Some 0)
    ?(arr_approved = true) ?(arr_rejected = false)
    ?(arr_temporarily_rejected = false) ?(arr_rejection_reasons = [])
    ?(is_repack = false) ?(is_proper = false) ?(age_hours = Some 12.)
    ?(indexer = Some "TestIndexer") () : Types.release =
  {
    Types.id;
    guid = Some ("guid-" ^ id);
    indexer_id = Some 1;
    indexer;
    title;
    size_bytes = Types.bytes_of_gib size_gib;
    seeders;
    leechers = Some 2;
    protocol;
    age_hours;
    publish_date = Some "2026-01-01T00:00:00Z";
    quality;
    quality_source;
    resolution;
    quality_modifier;
    quality_weight;
    is_repack;
    is_proper;
    source;
    codec;
    audio;
    hdr;
    dolby_vision;
    dv_profile;
    release_group;
    languages;
    custom_formats;
    custom_format_score;
    arr_approved;
    arr_rejected;
    arr_temporarily_rejected;
    arr_rejection_reasons;
    download_allowed = true;
    full_season = false;
    season_number = None;
    mapped_episode_ids = [];
    raw = `Null;
  }

let movie : Types.media =
  {
    Types.app = Types.Radarr;
    media_id = 123;
    title = "Movie";
    year = Some 2026;
    media_kind = "movie";
    series_type = None;
    season_number = None;
    episode_number = None;
    episode_title = None;
    genres = [ "Drama" ];
    runtime_minutes = Some 120;
    quality_profile_id = Some 1;
    quality_profile_name = Some "HD-1080p";
    tags = [];
    overview = None;
    original_language = Some "English";
    has_file = false;
    existing_quality = None;
    monitored = true;
    path = Some "/movies/Movie (2026)";
    extra = [];
  }

let config_with ?(hard_rules = Config.default_hard_rules)
    ?(preferences = Config.default_preferences)
    ?(weights = Config.default_weights) ?(llm = Config.default_llm)
    ?(nl_preferences = "") () : Config.t =
  { Config.default with hard_rules; preferences; weights; llm; nl_preferences }

let rules_of (r : Types.rejection list) = List.map (fun x -> x.Types.rule) r
let check = Filter.check

(* ------------------------------------------------------------------------ *)
(* Filter                                                                    *)
(* ------------------------------------------------------------------------ *)

let test_filter_passes () =
  let rules = { Config.default_hard_rules with min_seeders = Some 5 } in
  Alcotest.(check (list string))
    "clean release passes" [] (rules_of (check rules (mk_release ())))

let test_filter_max_size () =
  let rules = { Config.default_hard_rules with max_size_gib = Some 5.0 } in
  Alcotest.(check (list string))
    "oversized rejected" [ "max_size" ]
    (rules_of (check rules (mk_release ~size_gib:9.0 ())))

let test_filter_min_size () =
  let rules = { Config.default_hard_rules with min_size_gib = Some 2.0 } in
  Alcotest.(check (list string))
    "undersized rejected" [ "min_size" ]
    (rules_of (check rules (mk_release ~size_gib:0.5 ())))

let test_filter_min_seeders () =
  let rules = { Config.default_hard_rules with min_seeders = Some 10 } in
  Alcotest.(check (list string))
    "too few seeders" [ "min_seeders" ]
    (rules_of (check rules (mk_release ~seeders:(Some 3) ())));
  Alcotest.(check (list string))
    "usenet ignores seeders" []
    (rules_of
       (check rules
          (mk_release ~protocol:Types.Usenet ~seeders:None ())));
  Alcotest.(check (list string))
    "unknown seeder count passes" []
    (rules_of (check rules (mk_release ~seeders:None ())))

let test_filter_blocked_group () =
  let rules =
    { Config.default_hard_rules with blocked_groups = [ "yts"; "RARBG" ] }
  in
  Alcotest.(check (list string))
    "blocked group, case-insensitive" [ "blocked_group" ]
    (rules_of (check rules (mk_release ~release_group:(Some "YTS") ())));
  Alcotest.(check (list string))
    "other group passes" []
    (rules_of (check rules (mk_release ~release_group:(Some "FLUX") ())))

let test_filter_blocked_codec () =
  let rules = { Config.default_hard_rules with blocked_codecs = [ "AV1" ] } in
  Alcotest.(check (list string))
    "blocked codec" [ "blocked_codec" ]
    (rules_of (check rules (mk_release ~codec:(Some "av1") ())));
  (* alias: blocking "hevc" must also block "x265" *)
  let rules = { Config.default_hard_rules with blocked_codecs = [ "hevc" ] } in
  Alcotest.(check (list string))
    "codec aliases are normalised" [ "blocked_codec" ]
    (rules_of (check rules (mk_release ~codec:(Some "x265") ())))

let test_filter_allowed_codec () =
  let rules =
    { Config.default_hard_rules with allowed_codecs = [ "x265"; "x264" ] }
  in
  Alcotest.(check (list string))
    "codec not on allow list" [ "codec_not_allowed" ]
    (rules_of (check rules (mk_release ~codec:(Some "AV1") ())));
  Alcotest.(check (list string))
    "unknown codec passes unless rejected explicitly" []
    (rules_of (check rules (mk_release ~codec:None ())));
  let rules = { rules with reject_unknown_codec = true } in
  Alcotest.(check (list string))
    "unknown codec rejected when configured" [ "unknown_codec" ]
    (rules_of (check rules (mk_release ~codec:None ())))

let test_filter_languages () =
  let rules =
    { Config.default_hard_rules with blocked_languages = [ "german" ] }
  in
  Alcotest.(check (list string))
    "blocked language" [ "blocked_language" ]
    (rules_of (check rules (mk_release ~languages:[ "German" ] ())));
  let rules =
    { Config.default_hard_rules with required_languages = [ "English" ] }
  in
  Alcotest.(check (list string))
    "required language missing" [ "missing_required_language" ]
    (rules_of (check rules (mk_release ~languages:[ "French" ] ())));
  Alcotest.(check (list string))
    "required language present" []
    (rules_of (check rules (mk_release ~languages:[ "English" ] ())))

let test_filter_remux () =
  let rules = { Config.default_hard_rules with allow_remux = false } in
  Alcotest.(check (list string))
    "remux by modifier" [ "remux_not_allowed" ]
    (rules_of
       (check rules (mk_release ~quality_modifier:(Some "remux") ())));
  Alcotest.(check (list string))
    "remux by quality name" [ "remux_not_allowed" ]
    (rules_of
       (check rules (mk_release ~quality:(Some "Bluray-2160p Remux") ())));
  Alcotest.(check (list string))
    "remux by source" [ "remux_not_allowed" ]
    (rules_of (check rules (mk_release ~source:(Some "Remux") ())))

let test_filter_dolby_vision () =
  let rules = { Config.default_hard_rules with allow_dolby_vision = false } in
  Alcotest.(check (list string))
    "dv blocked" [ "dolby_vision_not_allowed" ]
    (rules_of (check rules (mk_release ~dolby_vision:true ())));
  let rules =
    { Config.default_hard_rules with require_hdr10_fallback_for_dv = true }
  in
  Alcotest.(check (list string))
    "dv without hdr10 fallback" [ "dv_no_hdr10_fallback" ]
    (rules_of (check rules (mk_release ~dolby_vision:true ~hdr:[] ())));
  Alcotest.(check (list string))
    "dv profile 5 has no fallback" [ "dv_no_hdr10_fallback" ]
    (rules_of
       (check rules
          (mk_release ~dolby_vision:true ~hdr:[ "HDR10" ]
             ~dv_profile:(Some "P5") ())));
  Alcotest.(check (list string))
    "dv with hdr10 fallback passes" []
    (rules_of
       (check rules
          (mk_release ~dolby_vision:true ~hdr:[ "HDR10" ]
             ~dv_profile:(Some "P8") ())))

let test_filter_hdr () =
  let rules = { Config.default_hard_rules with allow_hdr = false } in
  Alcotest.(check (list string))
    "hdr blocked" [ "hdr_not_allowed" ]
    (rules_of (check rules (mk_release ~hdr:[ "HDR10" ] ())));
  let rules =
    { Config.default_hard_rules with blocked_hdr_formats = [ "HDR10+" ] }
  in
  Alcotest.(check (list string))
    "specific hdr format blocked" [ "blocked_hdr_format" ]
    (rules_of (check rules (mk_release ~hdr:[ "HDR10"; "HDR10+" ] ())))

let test_filter_resolution_and_protocol () =
  let rules =
    { Config.default_hard_rules with allowed_resolutions = [ 1080; 2160 ] }
  in
  Alcotest.(check (list string))
    "resolution not allowed" [ "resolution_not_allowed" ]
    (rules_of (check rules (mk_release ~resolution:(Some 720) ())));
  let rules =
    { Config.default_hard_rules with allowed_protocols = [ Types.Usenet ] }
  in
  Alcotest.(check (list string))
    "protocol not allowed" [ "protocol_not_allowed" ]
    (rules_of (check rules (mk_release ~protocol:Types.Torrent ())))

let test_filter_title_patterns () =
  let rules =
    { Config.default_hard_rules with blocked_title_patterns = [ "hdcam" ] }
  in
  Alcotest.(check (list string))
    "substring pattern" [ "blocked_title_pattern" ]
    (rules_of (check rules (mk_release ~title:"Movie.2026.HDCAM.x264" ())));
  let rules =
    {
      Config.default_hard_rules with
      blocked_title_patterns = [ "(HDCAM|TS)\\." ];
    }
  in
  Alcotest.(check (list string))
    "regex pattern" [ "blocked_title_pattern" ]
    (rules_of (check rules (mk_release ~title:"Movie.2026.TS.x264" ())));
  let rules =
    { Config.default_hard_rules with blocked_title_patterns = [ "([unclosed" ] }
  in
  Alcotest.(check (list string))
    "broken regex falls back to substring" []
    (rules_of (check rules (mk_release ())))

let test_filter_arr_rejections () =
  let r =
    mk_release ~arr_rejected:true
      ~arr_rejection_reasons:[ "Not a preferred word"; "Size too big" ]
      ~arr_approved:false ()
  in
  let reasons = check Config.default_hard_rules r in
  Alcotest.(check int) "one rejection per arr reason" 2 (List.length reasons);
  Alcotest.(check bool)
    "stage is arr" true
    (List.for_all (fun x -> x.Types.stage = Types.Arr_rejection) reasons);
  (* temporary rejection honoured only when respect_arr_rejections *)
  let tmp =
    mk_release ~arr_temporarily_rejected:true
      ~arr_rejection_reasons:[ "Release is still seeding" ] ()
  in
  Alcotest.(check int)
    "temporary rejection respected" 1
    (List.length (check Config.default_hard_rules tmp));
  let lenient =
    { Config.default_hard_rules with respect_arr_rejections = false }
  in
  Alcotest.(check int)
    "temporary rejection ignored when configured" 0
    (List.length (check lenient tmp));
  (* permanent policy rejections become soft too *)
  Alcotest.(check int)
    "policy rejections ignored when configured" 0
    (List.length (check lenient r));
  (* ...but unrecoverable ones (mapping / blocklist) stay hard *)
  let unmappable =
    mk_release ~arr_rejected:true ~arr_approved:false
      ~arr_rejection_reasons:
        [ "Unable to identify correct episode(s) using release name and scene mappings";
          "Quality HDTV-1080p is not wanted in profile" ]
      ()
  in
  let kept = check lenient unmappable in
  Alcotest.(check int) "only the unrecoverable reason remains" 1 (List.length kept);
  Alcotest.(check string) "rule id" "arr_rejection_unrecoverable"
    (List.hd kept).Types.rule;
  Alcotest.(check int) "blocklisted stays hard" 1
    (List.length
       (check lenient
          (mk_release ~arr_rejected:true ~arr_approved:false
             ~arr_rejection_reasons:[ "Release is blocklisted" ] ())));
  (* and in soft mode the release is penalised by scoring instead *)
  let scored =
    Scoring.score Config.default_preferences Config.default_weights
      movie r
  in
  Alcotest.(check bool) "arr_rejected penalty component present" true
    (List.exists (fun c -> c.Types.component = "arr_rejected") scored.Types.components);
  let approved =
    Scoring.score Config.default_preferences Config.default_weights
      movie (mk_release ())
  in
  Alcotest.(check bool) "approved release scores higher than the rejected one" true
    (approved.Types.score > scored.Types.score)

let test_filter_multiple_reasons () =
  let rules =
    {
      Config.default_hard_rules with
      max_size_gib = Some 1.0;
      min_seeders = Some 100;
      blocked_groups = [ "FLUX" ];
      blocked_codecs = [ "x265" ];
    }
  in
  let reasons = rules_of (check rules (mk_release ())) in
  Alcotest.(check (list string))
    "all applicable reasons are reported"
    [ "max_size"; "min_seeders"; "blocked_group"; "blocked_codec" ]
    reasons

let test_filter_partition () =
  let good = mk_release ~id:"good" () in
  let bad = mk_release ~id:"bad" ~size_gib:99. () in
  let rules = { Config.default_hard_rules with max_size_gib = Some 10. } in
  let ok, rejected = Filter.partition rules [ good; bad ] in
  Alcotest.(check (list string))
    "valid ids" [ "good" ]
    (List.map (fun r -> r.Types.id) ok);
  Alcotest.(check (list string))
    "rejected ids" [ "bad" ]
    (List.map (fun r -> r.Types.release.Types.id) rejected)

(* ------------------------------------------------------------------------ *)
(* Scoring                                                                   *)
(* ------------------------------------------------------------------------ *)

let score_of prefs release =
  (Scoring.score prefs Config.default_weights movie release).Types.score

let test_scoring_webdl_beats_webrip () =
  let webdl = mk_release ~id:"webdl" ~source:(Some "WEB-DL") () in
  let webrip =
    mk_release ~id:"webrip" ~source:(Some "WEBRip")
      ~quality:(Some "WEBRip-1080p") ~quality_source:(Some "webRip") ()
  in
  Alcotest.(check bool)
    "WEB-DL scores higher than WEBRip" true
    (score_of Config.default_preferences webdl
    > score_of Config.default_preferences webrip)

let test_scoring_bluray_beats_web () =
  let bluray =
    mk_release ~id:"bd" ~source:(Some "Bluray") ~quality:(Some "Bluray-1080p")
      ~quality_source:(Some "bluray") ()
  in
  let webdl = mk_release ~id:"webdl" () in
  Alcotest.(check bool)
    "Blu-ray scores higher than WEB-DL" true
    (score_of Config.default_preferences bluray
    > score_of Config.default_preferences webdl)

let test_scoring_preferred_group_wins () =
  let prefs =
    { Config.default_preferences with preferred_groups = [ "FLUX"; "NTb" ] }
  in
  let flux = mk_release ~id:"flux" ~release_group:(Some "FLUX") () in
  let ntb = mk_release ~id:"ntb" ~release_group:(Some "NTb") () in
  let other = mk_release ~id:"other" ~release_group:(Some "NOBODY") () in
  let ranked = Scoring.rank prefs Config.default_weights movie [ other; ntb; flux ] in
  Alcotest.(check (list string))
    "ordered preference list decays with position"
    [ "flux"; "ntb"; "other" ]
    (List.map (fun s -> s.Types.scored.Types.id) ranked)

let test_scoring_preferred_codec () =
  let prefs =
    { Config.default_preferences with preferred_codecs = [ "x265" ] }
  in
  let x265 = mk_release ~id:"x265" ~codec:(Some "HEVC") () in
  let x264 = mk_release ~id:"x264" ~codec:(Some "H.264") () in
  Alcotest.(check bool)
    "preferred codec matched through aliases" true
    (score_of prefs x265 > score_of prefs x264)

let test_scoring_size_penalty () =
  let prefs =
    {
      Config.default_preferences with
      ideal_size_gib = Some 6.0;
      size_tolerance_gib = 1.0;
    }
  in
  let sensible = mk_release ~id:"ok" ~size_gib:6.2 () in
  let huge = mk_release ~id:"huge" ~size_gib:40. () in
  Alcotest.(check bool)
    "huge release is penalised" true
    (score_of prefs sensible > score_of prefs huge);
  let components =
    (Scoring.score prefs Config.default_weights movie sensible).Types.components
  in
  Alcotest.(check bool)
    "in-range size is reported as a component" true
    (List.exists
       (fun (c : Types.score_component) -> c.Types.component = "size")
       components)

let test_scoring_seeders_capped () =
  let w = { Config.default_weights with w_seeders = 3.; w_seeders_cap = 6. } in
  let many = mk_release ~seeders:(Some 5000) () in
  let seeders_points =
    (Scoring.score Config.default_preferences w movie many).Types.components
    |> List.filter (fun (c : Types.score_component) ->
           c.Types.component = "seeders")
    |> List.map (fun (c : Types.score_component) -> c.Types.points)
  in
  Alcotest.(check (list (float 0.001))) "seeder points capped" [ 6. ]
    seeders_points

let test_scoring_avoid_dolby_vision () =
  let prefs =
    { Config.default_preferences with dolby_vision_preference = "avoid" }
  in
  let dv = mk_release ~id:"dv" ~dolby_vision:true () in
  let plain = mk_release ~id:"plain" () in
  Alcotest.(check bool)
    "dv penalised when avoided" true
    (score_of prefs plain > score_of prefs dv)

let test_scoring_deterministic_tiebreak () =
  let a = mk_release ~id:"a" ~title:"AAA" ~custom_format_score:(Some 0) () in
  let b = mk_release ~id:"b" ~title:"BBB" ~custom_format_score:(Some 0) () in
  let ranked_1 =
    Scoring.rank Config.default_preferences Config.default_weights movie [ a; b ]
  in
  let ranked_2 =
    Scoring.rank Config.default_preferences Config.default_weights movie [ b; a ]
  in
  Alcotest.(check (list string))
    "tie broken by title, order-independent"
    (List.map (fun s -> s.Types.scored.Types.id) ranked_1)
    (List.map (fun s -> s.Types.scored.Types.id) ranked_2)

let test_scoring_custom_format_score () =
  let low = mk_release ~id:"low" ~custom_format_score:(Some 0) () in
  let high = mk_release ~id:"high" ~custom_format_score:(Some 50) () in
  Alcotest.(check bool)
    "custom format score counts" true
    (score_of Config.default_preferences high
    > score_of Config.default_preferences low)

(* ------------------------------------------------------------------------ *)
(* Prompt                                                                    *)
(* ------------------------------------------------------------------------ *)

let ranked_fixture ?(n = 3) () =
  let releases =
    List.init n (fun i ->
        mk_release ~id:(Printf.sprintf "r%d" i)
          ~title:(Printf.sprintf "Movie.2026.1080p.WEB-DL.x265-G%d" i)
          ~custom_format_score:(Some (100 - i))
          ())
  in
  Scoring.rank Config.default_preferences Config.default_weights movie releases

let test_prompt_structure () =
  let config =
    config_with ~nl_preferences:"Prefer x265 and sensible file sizes." ()
  in
  let json =
    Prompt.build ~config ~instance:None ~media:movie
      ~instruction:"pick the highest quality release" (ranked_fixture ())
    |> Yojson.Safe.from_string
  in
  let keys = match json with `Assoc l -> List.map fst l | _ -> [] in
  Alcotest.(check (list string))
    "exact top-level keys"
    [
      "hard_constraints";
      "structured_preferences";
      "natural_language_preferences";
      "temporary_instruction";
      "media";
      "candidates";
    ]
    keys;
  let member k = match json with `Assoc l -> List.assoc k l | _ -> `Null in
  Alcotest.(check string)
    "natural language preferences included"
    "Global:\nPrefer x265 and sensible file sizes."
    (match member "natural_language_preferences" with
    | `String s -> s
    | _ -> "");
  Alcotest.(check string)
    "temporary instruction included" "pick the highest quality release"
    (match member "temporary_instruction" with `String s -> s | _ -> "");
  let candidate_keys =
    match member "candidates" with
    | `List (`Assoc c :: _) -> List.map fst c
    | _ -> []
  in
  List.iter
    (fun k ->
      Alcotest.(check bool)
        (Printf.sprintf "candidate has %s" k)
        true (List.mem k candidate_keys))
    [
      "id";
      "title";
      "size_gib";
      "source";
      "codec";
      "audio";
      "hdr";
      "dolby_vision";
      "resolution";
      "release_group";
      "seeders";
      "custom_format_score";
      "custom_formats";
      "languages";
      "quality";
      "deterministic_score";
    ]

let test_prompt_no_instruction () =
  let json =
    Prompt.build ~config:(config_with ()) ~instance:None ~media:movie
      (ranked_fixture ())
    |> Yojson.Safe.from_string
  in
  let member k = match json with `Assoc l -> List.assoc k l | _ -> `Null in
  Alcotest.(check bool)
    "temporary instruction is null when absent" true
    (member "temporary_instruction" = `Null)

let test_prompt_limits_candidates () =
  let llm = { Config.default_llm with llm_max_candidates = 2 } in
  let config = config_with ~llm () in
  let json =
    Prompt.build ~config ~instance:None ~media:movie (ranked_fixture ~n:10 ())
    |> Yojson.Safe.from_string
  in
  let count =
    match json with
    | `Assoc l -> (
        match List.assoc "candidates" l with
        | `List items -> List.length items
        | _ -> -1)
    | _ -> -1
  in
  Alcotest.(check int) "candidates limited to llm_max_candidates" 2 count

let test_prompt_excludes_rejected () =
  (* Only scored (i.e. surviving) candidates can reach the prompt: build the
     ranked list through the filter to prove rejected releases are absent. *)
  let rules = { Config.default_hard_rules with blocked_codecs = [ "AV1" ] } in
  let av1 = mk_release ~id:"av1" ~codec:(Some "AV1") () in
  let ok = mk_release ~id:"ok" () in
  let valid, rejected = Filter.partition rules [ av1; ok ] in
  Alcotest.(check int) "one rejected" 1 (List.length rejected);
  let ranked =
    Scoring.rank Config.default_preferences Config.default_weights movie valid
  in
  let body =
    Prompt.build ~config:(config_with ~hard_rules:rules ()) ~instance:None
      ~media:movie ranked
  in
  let candidate_ids =
    match Yojson.Safe.from_string body with
    | `Assoc l -> (
        match List.assoc_opt "candidates" l with
        | Some (`List items) ->
            List.filter_map
              (function
                | `Assoc c -> (
                    match List.assoc_opt "id" c with
                    | Some (`String s) -> Some s
                    | _ -> None)
                | _ -> None)
              items
        | _ -> [])
    | _ -> []
  in
  Alcotest.(check (list string))
    "only surviving candidates are sent to the model" [ "ok" ] candidate_ids

let test_prompt_system_mentions_hard_constraints () =
  Alcotest.(check bool)
    "system prompt states hard constraints are enforced" true
    (Filter.contains_ci ~needle:"hard_constraints" ~haystack:Prompt.system_prompt
    && Filter.contains_ci ~needle:"STRICT JSON" ~haystack:Prompt.system_prompt)

(* ------------------------------------------------------------------------ *)
(* LLM response validation                                                   *)
(* ------------------------------------------------------------------------ *)

let ids = [ "a"; "b"; "c" ]
let parse s = Llm_response.parse ~candidate_ids:ids (Yojson.Safe.from_string s)

let is_error = function Ok _ -> false | Error _ -> true
let error_message = function Ok _ -> "" | Error e -> e

let test_llm_valid () =
  match
    parse
      {|{"selected_id":"b","confidence":0.91,"reason":"best balance",
         "ranking":[{"id":"b","score":94,"reason":"good"},
                    {"id":"a","score":80,"reason":"bigger"}],
         "influences":["matches your preference for WEB-DL"],
         "conflicts":[]}|}
  with
  | Ok d ->
      Alcotest.(check string) "selected" "b" d.Types.selected_id;
      Alcotest.(check (float 0.001)) "confidence" 0.91 d.Types.confidence;
      Alcotest.(check int) "ranking size" 2 (List.length d.Types.ranking);
      Alcotest.(check (list string))
        "influences"
        [ "matches your preference for WEB-DL" ]
        d.Types.influences
  | Error e -> Alcotest.failf "expected a valid decision, got: %s" e

let test_llm_numeric_strings () =
  match
    parse
      {|{"selected_id":"a","confidence":"0.5","reason":"ok",
         "ranking":[{"id":"a","score":"94.0","reason":"r"}]}|}
  with
  | Ok d -> Alcotest.(check int) "score parsed from string" 94
              (match d.Types.ranking with e :: _ -> e.Types.rank_score | [] -> -1)
  | Error e -> Alcotest.failf "expected numeric strings to be accepted: %s" e

let test_llm_unknown_selected_id () =
  Alcotest.(check bool)
    "unknown selected_id rejected" true
    (is_error
       (parse {|{"selected_id":"zzz","confidence":0.5,"reason":"","ranking":[]}|}))

let test_llm_unknown_ranking_id () =
  Alcotest.(check bool)
    "unknown ranking id rejected" true
    (is_error
       (parse
          {|{"selected_id":"a","confidence":0.5,"reason":"",
             "ranking":[{"id":"nope","score":10,"reason":""}]}|}))

let test_llm_duplicate_ids () =
  let r =
    parse
      {|{"selected_id":"a","confidence":0.5,"reason":"",
         "ranking":[{"id":"a","score":90,"reason":""},
                    {"id":"a","score":80,"reason":""}]}|}
  in
  Alcotest.(check bool) "duplicates rejected" true (is_error r);
  Alcotest.(check bool)
    "message mentions duplicates" true
    (Filter.contains_ci ~needle:"duplicate" ~haystack:(error_message r))

let test_llm_score_out_of_range () =
  Alcotest.(check bool)
    "score > 100 rejected" true
    (is_error
       (parse
          {|{"selected_id":"a","confidence":0.5,"reason":"",
             "ranking":[{"id":"a","score":140,"reason":""}]}|}));
  Alcotest.(check bool)
    "negative score rejected" true
    (is_error
       (parse
          {|{"selected_id":"a","confidence":0.5,"reason":"",
             "ranking":[{"id":"a","score":-1,"reason":""}]}|}))

let test_llm_confidence_out_of_range () =
  Alcotest.(check bool)
    "confidence > 1 rejected" true
    (is_error
       (parse {|{"selected_id":"a","confidence":42,"reason":"","ranking":[]}|}))

let test_llm_missing_fields () =
  Alcotest.(check bool)
    "missing selected_id" true
    (is_error (parse {|{"confidence":0.5,"ranking":[]}|}));
  Alcotest.(check bool)
    "missing confidence" true
    (is_error (parse {|{"selected_id":"a","ranking":[]}|}));
  Alcotest.(check bool)
    "missing ranking" true
    (is_error (parse {|{"selected_id":"a","confidence":0.5}|}))

let test_llm_malformed_types () =
  Alcotest.(check bool)
    "array instead of object" true
    (is_error (Llm_response.parse ~candidate_ids:ids (`List [])));
  Alcotest.(check bool)
    "null" true
    (is_error (Llm_response.parse ~candidate_ids:ids `Null));
  Alcotest.(check bool)
    "ranking not an array" true
    (is_error
       (parse {|{"selected_id":"a","confidence":0.5,"ranking":"nope"}|}));
  Alcotest.(check bool)
    "ranking entry not an object" true
    (is_error (parse {|{"selected_id":"a","confidence":0.5,"ranking":[1,2]}|}));
  Alcotest.(check bool)
    "influences not strings" true
    (is_error
       (parse
          {|{"selected_id":"a","confidence":0.5,"ranking":[],"influences":[{"x":1}]}|}))

let test_llm_optional_reason () =
  match parse {|{"selected_id":"a","confidence":0.5,"ranking":[]}|} with
  | Ok d ->
      Alcotest.(check string) "reason defaults to empty" "" d.Types.llm_reason;
      Alcotest.(check (list string)) "conflicts default" [] d.Types.conflicts
  | Error e -> Alcotest.failf "reason should be optional: %s" e

(* ------------------------------------------------------------------------ *)
(* Explain                                                                   *)
(* ------------------------------------------------------------------------ *)

let test_explain_bullets () =
  let prefs =
    {
      Config.default_preferences with
      preferred_groups = [ "FLUX" ];
      preferred_codecs = [ "x265" ];
      ideal_size_gib = Some 6.0;
      size_tolerance_gib = 1.0;
    }
  in
  let config = config_with ~preferences:prefs () in
  let selected_release = mk_release ~id:"sel" ~size_gib:6.2 () in
  let bigger = mk_release ~id:"big" ~size_gib:30. () in
  let candidates =
    Scoring.rank prefs Config.default_weights movie
      [ selected_release; bigger ]
  in
  let selected =
    List.find (fun s -> s.Types.scored.Types.id = "sel") candidates
  in
  let explanation, conflicts =
    Explain.explain ~config ~instance:None ~media:movie ~selected ~candidates
      ~rejected:[] ~llm:None
  in
  let has needle =
    List.exists (fun b -> Filter.contains_ci ~needle ~haystack:b) explanation
  in
  Alcotest.(check bool) "mentions preferred group" true (has "preferred groups");
  Alcotest.(check bool) "mentions preferred codec" true (has "preferred codecs");
  Alcotest.(check bool) "mentions WEB-DL" true (has "WEB-DL");
  Alcotest.(check bool)
    "mentions size range" true (has "within your preferred size range");
  Alcotest.(check bool)
    "mentions larger alternatives" true
    (has "larger alternative");
  Alcotest.(check (list string)) "no conflicts" [] conflicts

let test_explain_merges_llm_influences () =
  let config = config_with () in
  let candidates = ranked_fixture ~n:1 () in
  let selected = List.hd candidates in
  let llm =
    Some
      {
        Types.selected_id = selected.Types.scored.Types.id;
        confidence = 0.8;
        llm_reason = "best";
        ranking = [];
        influences = [ "matches your preference for WEB-DL over WEBRip" ];
        conflicts = [ "you wanted Atmos but no candidate had it" ];
      }
  in
  let explanation, conflicts =
    Explain.explain ~config ~instance:None ~media:movie ~selected ~candidates
      ~rejected:[] ~llm
  in
  Alcotest.(check bool)
    "llm influence first" true
    (match explanation with
    | first :: _ -> first = "matches your preference for WEB-DL over WEBRip"
    | [] -> false);
  Alcotest.(check (list string))
    "llm conflicts propagated"
    [ "you wanted Atmos but no candidate had it" ]
    conflicts

let test_explain_hard_rule_conflicts () =
  let hard_rules =
    {
      Config.default_hard_rules with
      blocked_codecs = [ "AV1" ];
      blocked_groups = [ "YTS" ];
      allow_remux = false;
      allow_dolby_vision = false;
      max_size_gib = Some 10.;
    }
  in
  let config =
    config_with ~hard_rules
      ~nl_preferences:
        "I really like AV1 releases and YTS is fine. Remux is great and Dolby \
         Vision looks nice. Pick the best possible quality."
      ()
  in
  let conflicts = Explain.hard_rule_conflicts ~config ~instance:None in
  let has needle =
    List.exists (fun c -> Filter.contains_ci ~needle ~haystack:c) conflicts
  in
  Alcotest.(check bool)
    "av1 conflict" true
    (List.exists
       (fun c ->
         c
         = "You said you prefer AV1, but AV1 is blocked by a hard codec rule.")
       conflicts);
  Alcotest.(check bool) "group conflict" true (has "blocked release groups");
  Alcotest.(check bool) "remux conflict" true (has "remuxes are blocked");
  Alcotest.(check bool) "dv conflict" true (has "Dolby Vision is blocked");
  Alcotest.(check bool) "size conflict" true (has "maximum size")

let test_explain_no_conflicts_without_mentions () =
  let hard_rules = { Config.default_hard_rules with blocked_codecs = [ "AV1" ] } in
  let config =
    config_with ~hard_rules
      ~nl_preferences:"Prefer reasonably sized 1080p WEB-DLs." ()
  in
  Alcotest.(check (list string))
    "nothing mentioned, nothing reported" []
    (Explain.hard_rule_conflicts ~config ~instance:None)

let test_explain_instance_preferences () =
  let instance =
    {
      Config.inst_id = "radarr-4k";
      inst_name = "4K Radarr";
      inst_app = Types.Radarr;
      inst_url = "http://radarr:7878";
      inst_api_key = "key";
      inst_enabled = true;
      inst_nl_preferences = "Quality matters more than storage. Prefer Remux.";
      inst_automatic = false;
    }
  in
  let hard_rules = { Config.default_hard_rules with allow_remux = false } in
  let config = config_with ~hard_rules ~nl_preferences:"Prefer x265." () in
  Alcotest.(check bool)
    "per-instance preferences are scanned too" true
    (List.exists
       (fun c -> Filter.contains_ci ~needle:"remux" ~haystack:c)
       (Explain.hard_rule_conflicts ~config ~instance:(Some instance)))

(* ------------------------------------------------------------------------ *)
(* Pipeline                                                                  *)
(* ------------------------------------------------------------------------ *)

let run_pipeline ?instruction ?llm ?use_ai ~config releases =
  Lwt_main.run
    (Pipeline.run ~config ~instance:None ~media:movie ~releases ?instruction
       ?llm ?use_ai ())

let selected_id (r : Types.selection_result) =
  match r.Types.selected with
  | Some s -> s.Types.scored.Types.id
  | None -> "<none>"

let test_pipeline_deterministic () =
  let config = config_with () in
  let a = mk_release ~id:"webrip" ~source:(Some "WEBRip") () in
  let b = mk_release ~id:"webdl" ~source:(Some "WEB-DL") () in
  let result = run_pipeline ~config [ a; b ] in
  Alcotest.(check string) "picks the best deterministic" "webdl"
    (selected_id result);
  Alcotest.(check bool)
    "method is deterministic" true
    (result.Types.method_ = Types.By_deterministic);
  Alcotest.(check bool) "not grabbed" false result.Types.grabbed;
  Alcotest.(check int) "candidates" 2 (List.length result.Types.candidates)

let test_pipeline_no_candidates () =
  let config =
    config_with
      ~hard_rules:{ Config.default_hard_rules with max_size_gib = Some 0.1 }
      ()
  in
  let result = run_pipeline ~config [ mk_release () ] in
  Alcotest.(check string) "nothing selected" "<none>" (selected_id result);
  Alcotest.(check int) "all rejected" 1 (List.length result.Types.rejected);
  Alcotest.(check bool)
    "reason explains" true
    (Filter.contains_ci ~needle:"rejected by hard rules"
       ~haystack:result.Types.reason)

let test_pipeline_no_releases () =
  let result = run_pipeline ~config:(config_with ()) [] in
  Alcotest.(check string) "nothing selected" "<none>" (selected_id result);
  Alcotest.(check bool)
    "reason explains" true
    (Filter.contains_ci ~needle:"No releases" ~haystack:result.Types.reason)

let ai_config () =
  config_with ~llm:{ Config.default_llm with llm_enabled = true } ()

let test_pipeline_llm_selection () =
  let a = mk_release ~id:"a" ~custom_format_score:(Some 100) () in
  let b = mk_release ~id:"b" ~custom_format_score:(Some 0) () in
  let llm ~system ~user =
    ignore system;
    ignore user;
    Lwt.return
      (Ok
         (Yojson.Safe.from_string
            {|{"selected_id":"b","confidence":0.8,"reason":"smaller is fine",
               "ranking":[{"id":"b","score":90,"reason":"good"},
                          {"id":"a","score":50,"reason":"too big"}],
               "influences":["you prefer sensible file sizes"]}|}))
  in
  let result = run_pipeline ~config:(ai_config ()) ~llm [ a; b ] in
  Alcotest.(check string) "llm pick wins" "b" (selected_id result);
  Alcotest.(check bool) "method is llm" true (result.Types.method_ = Types.By_llm);
  Alcotest.(check string) "reason from llm" "smaller is fine" result.Types.reason;
  Alcotest.(check (list string))
    "candidates re-ordered by the llm ranking" [ "b"; "a" ]
    (List.map (fun s -> s.Types.scored.Types.id) result.Types.candidates);
  Alcotest.(check bool)
    "llm influence surfaced in the explanation" true
    (List.exists
       (fun b -> b = "you prefer sensible file sizes")
       result.Types.explanation)

let test_pipeline_llm_failure_falls_back () =
  let a = mk_release ~id:"a" ~custom_format_score:(Some 100) () in
  let b = mk_release ~id:"b" ~custom_format_score:(Some 0) () in
  let llm ~system ~user =
    ignore system;
    ignore user;
    Lwt.return (Error "connection refused")
  in
  let result = run_pipeline ~config:(ai_config ()) ~llm [ b; a ] in
  Alcotest.(check string) "deterministic top used" "a" (selected_id result);
  Alcotest.(check bool)
    "method records the failure" true
    (result.Types.method_
     = Types.By_deterministic_fallback "connection refused");
  Alcotest.(check bool) "no llm decision" true (result.Types.llm = None)

let test_pipeline_llm_malformed_falls_back () =
  let a = mk_release ~id:"a" ~custom_format_score:(Some 100) () in
  let llm ~system ~user =
    ignore system;
    ignore user;
    Lwt.return (Ok (Yojson.Safe.from_string {|{"selected_id":"nope"}|}))
  in
  let result = run_pipeline ~config:(ai_config ()) ~llm [ a ] in
  Alcotest.(check string) "falls back to deterministic" "a"
    (selected_id result);
  Alcotest.(check bool)
    "fallback reason mentions the invalid response" true
    (match result.Types.method_ with
    | Types.By_deterministic_fallback why ->
        Filter.contains_ci ~needle:"invalid response" ~haystack:why
    | _ -> false)

let test_pipeline_llm_exception_falls_back () =
  let llm ~system ~user =
    ignore system;
    ignore user;
    Lwt.fail (Failure "boom")
  in
  let result = run_pipeline ~config:(ai_config ()) ~llm [ mk_release ~id:"a" () ] in
  Alcotest.(check string) "still selects" "a" (selected_id result);
  Alcotest.(check bool)
    "exception captured as fallback" true
    (match result.Types.method_ with
    | Types.By_deterministic_fallback _ -> true
    | _ -> false)

let test_pipeline_use_ai_override () =
  let called = ref false in
  let llm ~system ~user =
    ignore system;
    ignore user;
    called := true;
    Lwt.return (Error "unused")
  in
  let _ =
    run_pipeline ~config:(ai_config ()) ~llm ~use_ai:false
      [ mk_release ~id:"a" () ]
  in
  Alcotest.(check bool) "use_ai:false skips the llm" false !called;
  let _ =
    run_pipeline ~config:(config_with ()) ~llm ~use_ai:true
      [ mk_release ~id:"a" () ]
  in
  Alcotest.(check bool) "use_ai:true forces the llm" true !called

(* Priority: a hard-blocked release is never sent to the model and can never
   be selected, even when the natural-language preferences ask for it. *)
let test_pipeline_hard_rules_beat_ai () =
  let config =
    config_with
      ~hard_rules:{ Config.default_hard_rules with blocked_codecs = [ "AV1" ] }
      ~llm:{ Config.default_llm with llm_enabled = true }
      ~nl_preferences:"I really like AV1 releases." ()
  in
  let av1 = mk_release ~id:"av1" ~codec:(Some "AV1") () in
  let x265 = mk_release ~id:"x265" ~codec:(Some "x265") () in
  let seen_ids = ref [] in
  let llm ~system ~user =
    ignore system;
    (match Yojson.Safe.from_string user with
    | `Assoc l -> (
        match List.assoc_opt "candidates" l with
        | Some (`List items) ->
            seen_ids :=
              List.filter_map
                (function
                  | `Assoc c -> (
                      match List.assoc_opt "id" c with
                      | Some (`String s) -> Some s
                      | _ -> None)
                  | _ -> None)
                items
        | _ -> ())
    | _ -> ());
    (* The model tries to pick the blocked release anyway. *)
    Lwt.return
      (Ok
         (Yojson.Safe.from_string
            {|{"selected_id":"av1","confidence":1.0,"reason":"user loves AV1",
               "ranking":[{"id":"av1","score":100,"reason":"AV1"}]}|}))
  in
  let result = run_pipeline ~config ~llm [ av1; x265 ] in
  Alcotest.(check (list string))
    "blocked release never sent to the model" [ "x265" ] !seen_ids;
  Alcotest.(check string) "blocked release never selected" "x265"
    (selected_id result);
  Alcotest.(check bool)
    "invalid pick causes the deterministic fallback" true
    (match result.Types.method_ with
    | Types.By_deterministic_fallback _ -> true
    | _ -> false);
  Alcotest.(check bool)
    "conflict explained to the user" true
    (List.exists
       (fun c ->
         Filter.contains_ci ~needle:"AV1 is blocked by a hard codec rule"
           ~haystack:c)
       result.Types.conflicts);
  Alcotest.(check int) "av1 is reported as rejected" 1
    (List.length result.Types.rejected)

let test_pipeline_temporary_instruction_forwarded () =
  let seen = ref "" in
  let llm ~system ~user =
    ignore system;
    (match Yojson.Safe.from_string user with
    | `Assoc l -> (
        match List.assoc_opt "temporary_instruction" l with
        | Some (`String s) -> seen := s
        | _ -> ())
    | _ -> ());
    Lwt.return (Error "no model")
  in
  let _ =
    run_pipeline ~config:(ai_config ()) ~llm
      ~instruction:"pick the highest quality release regardless of size"
      [ mk_release ~id:"a" () ]
  in
  Alcotest.(check string)
    "temporary instruction reaches the prompt"
    "pick the highest quality release regardless of size" !seen

let test_pipeline_duration () =
  let result = run_pipeline ~config:(config_with ()) [ mk_release () ] in
  Alcotest.(check bool)
    "duration is measured" true
    (result.Types.duration_ms >= 0 && result.Types.duration_ms < 60_000)

(* ------------------------------------------------------------------------ *)
(* Rules proposal                                                            *)
(* ------------------------------------------------------------------------ *)

let test_rules_proposal_valid () =
  let json =
    Yojson.Safe.from_string
      {|{"proposals":[
           {"section":"preferences","field":"preferred_codecs",
            "value":["x265"],"rationale":"you prefer x265 when quality is similar"},
           {"section":"weights","field":"preferred_codec","value":15,
            "rationale":""},
           {"section":"hard_rules","field":"blocked_codecs","value":["AV1"],
            "rationale":"you never want AV1"}]}|}
  in
  match Rules_proposal.parse json with
  | Error e -> Alcotest.failf "expected valid proposals: %s" e
  | Ok (patch, summary) ->
      let patched =
        match Config.of_yojson ~d:Config.default patch with
        | Ok c -> c
        | Error e -> Alcotest.failf "patch is not a valid config: %s" e
      in
      Alcotest.(check (list string))
        "preferred codecs applied" [ "x265" ]
        patched.Config.preferences.Config.preferred_codecs;
      Alcotest.(check (float 0.001))
        "weight applied" 15.
        patched.Config.weights.Config.w_preferred_codec;
      Alcotest.(check (list string))
        "blocked codec applied" [ "AV1" ]
        patched.Config.hard_rules.Config.blocked_codecs;
      Alcotest.(check int) "one summary line per proposal" 3
        (List.length summary);
      Alcotest.(check bool)
        "summary is human readable" true
        (List.exists
           (fun l ->
             Filter.contains_ci ~needle:"Preferred codecs: x265" ~haystack:l)
           summary);
      Alcotest.(check bool)
        "weights summary is signed" true
        (List.exists
           (fun l ->
             Filter.contains_ci ~needle:"Preferred codec bonus: +15"
               ~haystack:l)
           summary)

let test_rules_proposal_rejects_unknown () =
  let bad s = is_error (Rules_proposal.parse (Yojson.Safe.from_string s)) in
  Alcotest.(check bool)
    "unknown section" true
    (bad {|{"proposals":[{"section":"nope","field":"x","value":1}]}|});
  Alcotest.(check bool)
    "unknown field" true
    (bad
       {|{"proposals":[{"section":"preferences","field":"do_magic","value":1}]}|});
  Alcotest.(check bool)
    "wrong value type" true
    (bad
       {|{"proposals":[{"section":"preferences","field":"preferred_codecs","value":"x265"}]}|});
  Alcotest.(check bool)
    "bad enum" true
    (bad
       {|{"proposals":[{"section":"preferences","field":"hdr_preference","value":"maybe"}]}|});
  Alcotest.(check bool) "missing proposals" true (bad {|{}|});
  Alcotest.(check bool)
    "proposals not a list" true
    (bad {|{"proposals":"none"}|})

let test_rules_proposal_empty () =
  match Rules_proposal.parse (Yojson.Safe.from_string {|{"proposals":[]}|}) with
  | Ok (patch, summary) ->
      Alcotest.(check string) "empty patch" "{}" (Yojson.Safe.to_string patch);
      Alcotest.(check (list string)) "empty summary" [] summary
  | Error e -> Alcotest.failf "empty proposals should be accepted: %s" e

let test_rules_proposal_prompt () =
  let body = Rules_proposal.build_prompt (config_with ()) "Prefer x265." in
  let json = Yojson.Safe.from_string body in
  let keys = match json with `Assoc l -> List.map fst l | _ -> [] in
  List.iter
    (fun k ->
      Alcotest.(check bool)
        (Printf.sprintf "prompt has %s" k)
        true (List.mem k keys))
    [
      "natural_language_preferences";
      "current_preferences";
      "current_hard_rules";
      "current_weights";
      "allowed_fields";
    ];
  Alcotest.(check bool)
    "system prompt requires approval workflow" true
    (Filter.contains_ci ~needle:"STRICT JSON"
       ~haystack:Rules_proposal.system_prompt)

(* ------------------------------------------------------------------------ *)
(* Runner                                                                    *)
(* ------------------------------------------------------------------------ *)

let () =
  Alcotest.run "pickarr-core"
    [
      ( "filter",
        [
          Alcotest.test_case "passes clean release" `Quick test_filter_passes;
          Alcotest.test_case "max size" `Quick test_filter_max_size;
          Alcotest.test_case "min size" `Quick test_filter_min_size;
          Alcotest.test_case "min seeders" `Quick test_filter_min_seeders;
          Alcotest.test_case "blocked group" `Quick test_filter_blocked_group;
          Alcotest.test_case "blocked codec" `Quick test_filter_blocked_codec;
          Alcotest.test_case "allowed codecs" `Quick test_filter_allowed_codec;
          Alcotest.test_case "languages" `Quick test_filter_languages;
          Alcotest.test_case "remux" `Quick test_filter_remux;
          Alcotest.test_case "dolby vision" `Quick test_filter_dolby_vision;
          Alcotest.test_case "hdr" `Quick test_filter_hdr;
          Alcotest.test_case "resolution and protocol" `Quick
            test_filter_resolution_and_protocol;
          Alcotest.test_case "title patterns" `Quick test_filter_title_patterns;
          Alcotest.test_case "arr rejections" `Quick test_filter_arr_rejections;
          Alcotest.test_case "all reasons reported" `Quick
            test_filter_multiple_reasons;
          Alcotest.test_case "partition" `Quick test_filter_partition;
        ] );
      ( "scoring",
        [
          Alcotest.test_case "web-dl beats webrip" `Quick
            test_scoring_webdl_beats_webrip;
          Alcotest.test_case "bluray beats web" `Quick
            test_scoring_bluray_beats_web;
          Alcotest.test_case "preferred group order" `Quick
            test_scoring_preferred_group_wins;
          Alcotest.test_case "preferred codec" `Quick
            test_scoring_preferred_codec;
          Alcotest.test_case "size penalty" `Quick test_scoring_size_penalty;
          Alcotest.test_case "seeders capped" `Quick test_scoring_seeders_capped;
          Alcotest.test_case "avoid dolby vision" `Quick
            test_scoring_avoid_dolby_vision;
          Alcotest.test_case "deterministic tie break" `Quick
            test_scoring_deterministic_tiebreak;
          Alcotest.test_case "custom format score" `Quick
            test_scoring_custom_format_score;
        ] );
      ( "prompt",
        [
          Alcotest.test_case "structure" `Quick test_prompt_structure;
          Alcotest.test_case "no instruction" `Quick test_prompt_no_instruction;
          Alcotest.test_case "candidate limit" `Quick
            test_prompt_limits_candidates;
          Alcotest.test_case "excludes rejected" `Quick
            test_prompt_excludes_rejected;
          Alcotest.test_case "system prompt" `Quick
            test_prompt_system_mentions_hard_constraints;
        ] );
      ( "llm_response",
        [
          Alcotest.test_case "valid" `Quick test_llm_valid;
          Alcotest.test_case "numeric strings" `Quick test_llm_numeric_strings;
          Alcotest.test_case "unknown selected id" `Quick
            test_llm_unknown_selected_id;
          Alcotest.test_case "unknown ranking id" `Quick
            test_llm_unknown_ranking_id;
          Alcotest.test_case "duplicate ids" `Quick test_llm_duplicate_ids;
          Alcotest.test_case "score range" `Quick test_llm_score_out_of_range;
          Alcotest.test_case "confidence range" `Quick
            test_llm_confidence_out_of_range;
          Alcotest.test_case "missing fields" `Quick test_llm_missing_fields;
          Alcotest.test_case "malformed types" `Quick test_llm_malformed_types;
          Alcotest.test_case "optional reason" `Quick test_llm_optional_reason;
        ] );
      ( "explain",
        [
          Alcotest.test_case "bullets" `Quick test_explain_bullets;
          Alcotest.test_case "merges llm influences" `Quick
            test_explain_merges_llm_influences;
          Alcotest.test_case "hard rule conflicts" `Quick
            test_explain_hard_rule_conflicts;
          Alcotest.test_case "no false conflicts" `Quick
            test_explain_no_conflicts_without_mentions;
          Alcotest.test_case "instance preferences" `Quick
            test_explain_instance_preferences;
        ] );
      ( "pipeline",
        [
          Alcotest.test_case "deterministic" `Quick test_pipeline_deterministic;
          Alcotest.test_case "no candidates" `Quick test_pipeline_no_candidates;
          Alcotest.test_case "no releases" `Quick test_pipeline_no_releases;
          Alcotest.test_case "llm selection" `Quick test_pipeline_llm_selection;
          Alcotest.test_case "llm failure fallback" `Quick
            test_pipeline_llm_failure_falls_back;
          Alcotest.test_case "llm malformed fallback" `Quick
            test_pipeline_llm_malformed_falls_back;
          Alcotest.test_case "llm exception fallback" `Quick
            test_pipeline_llm_exception_falls_back;
          Alcotest.test_case "use_ai override" `Quick
            test_pipeline_use_ai_override;
          Alcotest.test_case "hard rules beat ai" `Quick
            test_pipeline_hard_rules_beat_ai;
          Alcotest.test_case "temporary instruction" `Quick
            test_pipeline_temporary_instruction_forwarded;
          Alcotest.test_case "duration" `Quick test_pipeline_duration;
        ] );
      ( "rules_proposal",
        [
          Alcotest.test_case "valid proposals" `Quick
            test_rules_proposal_valid;
          Alcotest.test_case "rejects unknown" `Quick
            test_rules_proposal_rejects_unknown;
          Alcotest.test_case "empty proposals" `Quick
            test_rules_proposal_empty;
          Alcotest.test_case "prompt" `Quick test_rules_proposal_prompt;
        ] );
    ]
