(* Pipeline orchestration.  The only Lwt-aware module in the core library. *)

type llm_fn =
  system:string -> user:string -> (Yojson.Safe.t, string) result Lwt.t

let now_ms () = Unix.gettimeofday () *. 1000.

(* Re-order the deterministic candidate list to follow the model's ranking:
   the selected release first, then the ranked ones by descending model score,
   then everything the model did not rank in deterministic order. *)
let reorder_by_ranking (decision : Types.llm_decision)
    (candidates : Types.scored_release list) : Types.scored_release list =
  let rank_of (s : Types.scored_release) =
    List.find_opt
      (fun (e : Types.llm_ranking_entry) ->
        e.Types.rank_id = s.Types.scored.Types.id)
      decision.Types.ranking
  in
  let is_selected (s : Types.scored_release) =
    s.Types.scored.Types.id = decision.Types.selected_id
  in
  let selected = List.filter is_selected candidates in
  let rest = List.filter (fun s -> not (is_selected s)) candidates in
  let ranked, unranked =
    List.partition (fun s -> rank_of s <> None) rest
  in
  let ranked =
    List.stable_sort
      (fun a b ->
        let score s =
          match rank_of s with
          | Some e -> e.Types.rank_score
          | None -> min_int
        in
        compare (score b) (score a))
      ranked
  in
  selected @ ranked @ unranked

let deterministic_reason (top : Types.scored_release) : string =
  Printf.sprintf "Highest deterministic score (%.1f points) for %s"
    top.Types.score top.Types.scored.Types.title

let run ~(config : Config.t) ~(instance : Config.instance option)
    ~(media : Types.media) ~(releases : Types.release list)
    ?(instruction = "") ?(llm : llm_fn option) ?use_ai () :
    Types.selection_result Lwt.t =
  let started = now_ms () in
  let finish ~selected ~candidates ~rejected ~reason ~explanation ~conflicts
      ~method_ ~llm_decision =
    let duration_ms = int_of_float (Float.round (now_ms () -. started)) in
    Lwt.return
      {
        Types.media;
        selected;
        candidates;
        rejected;
        reason;
        explanation;
        conflicts;
        method_;
        llm = llm_decision;
        grabbed = false;
        grab_error = None;
        duration_ms;
      }
  in
  (* Stage 2: hard rules.  For a season selection the pack requirement comes
     first, so that single episodes returned by Sonarr's season search are
     reported as rejected instead of competing with the packs. *)
  let packs, not_packs = Filter.season_pack_partition media releases in
  let valid, rejected = Filter.partition config.Config.hard_rules packs in
  let rejected = not_packs @ rejected in
  (* Stage 3: deterministic scoring. *)
  let ranked =
    Scoring.rank config.Config.preferences config.Config.weights media valid
  in
  match ranked with
  | [] ->
      let reason =
        if releases = [] then
          "No releases were returned by Sonarr/Radarr for this item"
        else
          Printf.sprintf
            "All %d release(s) were rejected by hard rules or by Sonarr/Radarr"
            (List.length rejected)
      in
      finish ~selected:None ~candidates:[] ~rejected ~reason ~explanation:[]
        ~conflicts:(Explain.hard_rule_conflicts ~config ~instance)
        ~method_:Types.By_deterministic ~llm_decision:None
  | top :: _ ->
      let use_ai =
        Option.value use_ai ~default:config.Config.llm.Config.llm_enabled
      in
      let explain_and_finish ~selected ~candidates ~reason ~method_
          ~llm_decision =
        let explanation, conflicts =
          Explain.explain ~config ~instance ~media ~selected ~candidates
            ~rejected ~llm:llm_decision
        in
        finish ~selected:(Some selected) ~candidates ~rejected ~reason
          ~explanation ~conflicts ~method_ ~llm_decision
      in
      let fallback (why : string) =
        explain_and_finish ~selected:top ~candidates:ranked
          ~reason:
            (Printf.sprintf "%s (AI selection unavailable: %s)"
               (deterministic_reason top) why)
          ~method_:(Types.By_deterministic_fallback why) ~llm_decision:None
      in
      (* Stage 4: AI ranking, when enabled and available. *)
      (match (use_ai, llm) with
      | false, _ | _, None ->
          explain_and_finish ~selected:top ~candidates:ranked
            ~reason:(deterministic_reason top) ~method_:Types.By_deterministic
            ~llm_decision:None
      | true, Some call ->
          let sent = Prompt.candidates_for_llm config.Config.llm ranked in
          let candidate_ids =
            List.map (fun s -> s.Types.scored.Types.id) sent
          in
          let user =
            Prompt.build ~config ~instance ~media ~instruction ranked
          in
          Lwt.bind
            (Lwt.catch
               (fun () -> call ~system:Prompt.system_prompt ~user)
               (fun exn -> Lwt.return (Error (Printexc.to_string exn))))
            (function
              | Error why -> fallback why
              | Ok json -> (
                  match Llm_response.parse ~candidate_ids json with
                  | Error why -> fallback ("invalid response: " ^ why)
                  | Ok decision -> (
                      let selected =
                        List.find_opt
                          (fun s ->
                            s.Types.scored.Types.id
                            = decision.Types.selected_id)
                          ranked
                      in
                      match selected with
                      | None ->
                          (* Unreachable: parse validates the id against the
                             candidates that were sent. *)
                          fallback "the selected release is not a candidate"
                      | Some selected ->
                          let reason =
                            match String.trim decision.Types.llm_reason with
                            | "" ->
                                Printf.sprintf
                                  "AI selected %s (confidence %.2f)"
                                  selected.Types.scored.Types.title
                                  decision.Types.confidence
                            | r -> r
                          in
                          explain_and_finish ~selected
                            ~candidates:(reorder_by_ranking decision ranked)
                            ~reason ~method_:Types.By_llm
                            ~llm_decision:(Some decision)))))
