(* Stage 4 input: build the LLM request.  Pure module. *)

let system_prompt =
  String.concat "\n"
    [
      "You are Pickarr. Pick the single best download for one movie, episode \
       or season from a list of candidates.";
      "";
      "INPUT (one JSON object)";
      "- media: what is being downloaded.";
      "- hard_constraints: already enforced by Pickarr. Every candidate \
       already satisfies them. Never ask for a release that is not listed and \
       never argue that a hard constraint should be broken.";
      "- structured_preferences: the user's explicit settings.";
      "- natural_language_preferences: the user's own words. They may be \
       conditional (\"for movies...\", \"for anime...\", \"for 4K...\"); \
       apply only the parts that fit this media and ignore the rest.";
      "- temporary_instruction: applies to this one request only.";
      "- candidates: the releases you may choose from. deterministic_score \
       and deterministic_rank (1 = best) are Pickarr's own opinion, not an \
       order you must follow.";
      "";
      "PRIORITY, highest first";
      "1. hard_constraints (already applied)";
      "2. structured_preferences";
      "3. temporary_instruction";
      "4. natural_language_preferences";
      "5. deterministic_score";
      "6. your own knowledge of good releases";
      "";
      "IDS";
      "- Every candidate has a short id: r1, r2, r3 ...";
      "- Copy an id exactly as written. Never use a title, URL, magnet link, \
       info hash or number on its own as an id.";
      "";
      "NOTES";
      "- A candidate with arr_rejections was rejected by Sonarr/Radarr's own \
       rules and the user allowed Pickarr to override that: treat the reasons \
       as advice, prefer a candidate without them when quality is comparable, \
       and say so if you pick it anyway.";
      "- Prefer the release that best matches the user's wishes, not simply \
       the largest one or the top deterministic_score.";
      "";
      "OUTPUT";
      "Reply with STRICT JSON only. No markdown, no code fences, no text \
       before or after the JSON. Use exactly this shape:";
      "{\"selected_id\":\"r1\",\"confidence\":0.9,\"reason\":\"one \
       sentence\",\"ranking\":[{\"id\":\"r1\",\"score\":95,\"reason\":\"one \
       sentence\"}],\"influences\":[\"one sentence\"],\"conflicts\":[]}";
      "- selected_id: one id from candidates.";
      "- confidence: a number between 0 and 1.";
      "- ranking: the best 5 candidates at most, best first, whole scores \
       between 0 and 100, each id used once.";
      "- reason and every ranking reason: one sentence.";
      "- influences: which of the user's preferences drove the choice, in \
       plain English.";
      "- conflicts: user wishes you could not honour; [] when there are none.";
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

(* The model never sees a guid, magnet link or URL: those are hundreds of
   characters long, and models truncate or re-encode them, which used to make
   every ranking id unusable.  Ids are short tokens ("r1", "r2", ...) that the
   pipeline maps back to real release ids. *)
let short_id (index : int) : string = Printf.sprintf "r%d" (index + 1)

(** [short_ids sent] pairs each candidate that is sent to the model with its
    short id, in the order they appear in the prompt. *)
let short_ids (sent : Types.scored_release list) :
    (string * Types.scored_release) list =
  List.mapi (fun i s -> (short_id i, s)) sent

let some_string key = function
  | Some s when String.trim s <> "" -> [ (key, `String s) ]
  | _ -> []

let some_int key = function Some i -> [ (key, `Int i) ] | None -> []

let some_joined key = function
  | [] -> []
  | items -> [ (key, `String (String.concat ", " items)) ]

let when_true key b = if b then [ (key, `Bool true) ] else []

(** One candidate, as compact as possible: absent and empty fields are
    omitted rather than sent as nulls, so a small local model sees only
    information that exists. *)
let candidate_to_yojson ~(id : string) ~(rank : int) (s : Types.scored_release)
    : Yojson.Safe.t =
  let r = s.Types.scored in
  `Assoc
    ([ ("id", `String id); ("title", `String r.Types.title) ]
    @ [ ("size_gib", `Float (round2 (Types.gib_of_bytes r.Types.size_bytes))) ]
    @ some_string "quality" r.Types.quality
    @ some_int "resolution" r.Types.resolution
    @ some_string "source" r.Types.source
    @ some_string "codec" r.Types.codec
    @ some_string "audio" r.Types.audio
    @ some_joined "hdr" r.Types.hdr
    @ when_true "dolby_vision" r.Types.dolby_vision
    @ some_string "release_group" r.Types.release_group
    @ some_joined "languages" r.Types.languages
    @ some_int "seeders" r.Types.seeders
    @ some_int "custom_format_score" r.Types.custom_format_score
    @ some_joined "custom_formats"
        (List.map (fun c -> c.Types.cf_name) r.Types.custom_formats)
    @ when_true "is_repack" r.Types.is_repack
    @ when_true "is_proper" r.Types.is_proper
    @ (match r.Types.arr_rejection_reasons with
      | [] -> []
      | reasons ->
          (* Only non-empty when the user turned respect_arr_rejections off:
             advisory, not binding. *)
          [ ("arr_rejections", Types.str_list reasons) ])
    @ [
        ("deterministic_score", `Float (round2 s.Types.score));
        ("deterministic_rank", `Int rank);
      ])

(** [build_with_ids ...] renders the user message and returns the mapping from
    the short ids used in the prompt to the real release ids. *)
let build_with_ids ~(config : Config.t) ~(instance : Config.instance option)
    ~(media : Types.media) ?(instruction = "")
    (candidates : Types.scored_release list) : string * (string * string) list =
  let nl = Config.effective_nl_preferences config instance in
  let sent = candidates_for_llm config.Config.llm candidates in
  let pairs = short_ids sent in
  let temporary =
    match String.trim instruction with "" -> `Null | s -> `String s
  in
  let body =
    `Assoc
      [
        ("media", Types.media_to_yojson media);
        ( "hard_constraints",
          Config.hard_rules_to_yojson config.Config.hard_rules );
        ( "structured_preferences",
          Config.preferences_to_yojson config.Config.preferences );
        ("natural_language_preferences", `String nl);
        ("temporary_instruction", temporary);
        ( "candidates",
          `List
            (List.mapi
               (fun i (id, s) -> candidate_to_yojson ~id ~rank:(i + 1) s)
               pairs) );
      ]
    |> Yojson.Safe.to_string
  in
  (body, List.map (fun (id, s) -> (id, s.Types.scored.Types.id)) pairs)

let build ~(config : Config.t) ~(instance : Config.instance option)
    ~(media : Types.media) ?(instruction = "")
    (candidates : Types.scored_release list) : string =
  fst (build_with_ids ~config ~instance ~media ~instruction candidates)
