(* Stage 4 input: build the LLM request.  Pure module. *)

let system_prompt =
  String.concat "\n"
    [
      "You are Selectarr, a release selector for Sonarr and Radarr.";
      "You are given the releases that are still allowed for one movie or \
       episode and you must choose exactly one of them.";
      "";
      "RULES";
      "1. `hard_constraints` have ALREADY been enforced. Every candidate you \
       are shown satisfies them. You must not suggest, request or invent any \
       release that is not in `candidates`, and you must never argue that a \
       hard constraint should be violated.";
      "2. You may only select an `id` that appears in `candidates`.";
      "3. Apply the preferences in this priority order, highest first:";
      "   a. Sonarr/Radarr rejections (already applied)";
      "   b. Selectarr hard rules (already applied)";
      "   c. `structured_preferences` (explicit user settings)";
      "   d. `natural_language_preferences` (the user's prose)";
      "   e. `deterministic_score` (Selectarr's own local score)";
      "   f. your own general knowledge of good release practice";
      "4. `natural_language_preferences` may contain conditional instructions \
       (\"for movies ...\", \"for TV shows ...\", \"for anime ...\", \"for 4K \
       ...\", \"for older movies ...\"). Apply ONLY the parts that are \
       relevant to the item described in `media` (its `media_kind`, \
       `series_type`, `genres`, `year`, resolution of the candidates and \
       whether it already has a file). Ignore the irrelevant parts.";
      "5. `temporary_instruction`, when present, applies to this selection \
       only and outranks `natural_language_preferences`.";
      "6. Prefer the release that best matches the user's wishes, not simply \
       the biggest or the highest `deterministic_score`. Explain trade-offs \
       in plain English.";
      "";
      "RESPONSE FORMAT";
      "Reply with STRICT JSON ONLY. No prose, no markdown, no code fences. \
       Use exactly this shape:";
      "{";
      "  \"selected_id\": \"<id of the chosen candidate>\",";
      "  \"confidence\": 0.0,";
      "  \"reason\": \"<one or two sentences explaining the pick>\",";
      "  \"ranking\": [ { \"id\": \"<candidate id>\", \"score\": 0, \
       \"reason\": \"<short reason>\" } ],";
      "  \"influences\": [ \"<which user preference drove the choice, in \
       plain English>\" ],";
      "  \"conflicts\": [ \"<a user wish you could not honour because a hard \
       rule prevented it>\" ]";
      "}";
      "";
      "`confidence` is a number between 0 and 1. `ranking` scores are whole \
       numbers between 0 and 100, one entry per candidate you considered, \
       best first, and every `id` must be unique and must exist in \
       `candidates`. `influences` must reference the user's actual \
       preferences (structured or natural language), not generic advice. \
       `conflicts` must be an empty list when nothing conflicts.";
    ]

let candidates_for_llm (llm : Config.llm) (scored : Types.scored_release list) :
    Types.scored_release list =
  let n = llm.Config.llm_max_candidates in
  if n <= 0 then scored
  else
    let rec take i = function
      | [] -> []
      | _ when i = 0 -> []
      | x :: tl -> x :: take (i - 1) tl
    in
    take n scored

let round2 (f : float) : float = Float.round (f *. 100.) /. 100.

let candidate_to_yojson (s : Types.scored_release) : Yojson.Safe.t =
  let r = s.Types.scored in
  `Assoc
    [
      ("id", `String r.Types.id);
      ("title", `String r.Types.title);
      ("size_gib", `Float (round2 (Types.gib_of_bytes r.Types.size_bytes)));
      ("quality", Types.opt_str r.Types.quality);
      ("resolution", Types.opt_int r.Types.resolution);
      ("source", Types.opt_str r.Types.source);
      ("codec", Types.opt_str r.Types.codec);
      ("audio", Types.opt_str r.Types.audio);
      ("hdr", Types.str_list r.Types.hdr);
      ("dolby_vision", `Bool r.Types.dolby_vision);
      ("release_group", Types.opt_str r.Types.release_group);
      ("languages", Types.str_list r.Types.languages);
      ("indexer", Types.opt_str r.Types.indexer);
      ("protocol", `String (Types.protocol_to_string r.Types.protocol));
      ("seeders", Types.opt_int r.Types.seeders);
      ("custom_format_score", Types.opt_int r.Types.custom_format_score);
      ( "custom_formats",
        Types.str_list
          (List.map (fun c -> c.Types.cf_name) r.Types.custom_formats) );
      ("is_repack", `Bool r.Types.is_repack);
      ("is_proper", `Bool r.Types.is_proper);
      ("deterministic_score", `Float (round2 s.Types.score));
    ]

let build ~(config : Config.t) ~(instance : Config.instance option)
    ~(media : Types.media) ?(instruction = "")
    (candidates : Types.scored_release list) : string =
  let nl = Config.effective_nl_preferences config instance in
  let sent = candidates_for_llm config.Config.llm candidates in
  let temporary =
    match String.trim instruction with "" -> `Null | s -> `String s
  in
  `Assoc
    [
      ("hard_constraints", Config.hard_rules_to_yojson config.Config.hard_rules);
      ( "structured_preferences",
        Config.preferences_to_yojson config.Config.preferences );
      ("natural_language_preferences", `String nl);
      ("temporary_instruction", temporary);
      ("media", Types.media_to_yojson media);
      ("candidates", `List (List.map candidate_to_yojson sent));
    ]
  |> Yojson.Safe.to_string
