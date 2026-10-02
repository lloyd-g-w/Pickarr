(* Tests for the queue job kinds: parameter parsing, dedupe keys, labels, the
   job-error -> HTTP status encoding, and the webhook/Seerr job parameters.
   Pure: nothing here runs a job or touches the network. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Job_kinds = Pickarr_server.Job_kinds
module Responses = Pickarr_server.Responses
module Selection = Pickarr_server.Selection
module Seerr_sync = Pickarr_server.Seerr_sync
module Automatic = Pickarr_server.Automatic
module Client = Pickarr_arr.Client

let instance ?(app = Types.Sonarr) id name : Config.instance =
  {
    Config.inst_id = id;
    inst_name = name;
    inst_app = app;
    inst_url = "http://localhost";
    inst_api_key = "k";
    inst_enabled = true;
    inst_nl_preferences = "";
    inst_automatic = false;
  }

let sonarr = instance "sonarr" "Sonarr"
let radarr = instance ~app:Types.Radarr "radarr" "Radarr"
let find_instance id = List.find_opt (fun (i : Config.instance) -> i.inst_id = id) [ sonarr; radarr ]
let json = Yojson.Safe.from_string
let ok_or_fail = function Ok v -> v | Error e -> Alcotest.failf "unexpected error: %s" e

let is_error = function Ok _ -> false | Error _ -> true

(* ------------------------------------------------------------------ *)
(* Targets                                                             *)
(* ------------------------------------------------------------------ *)

let test_targets () =
  let parse s = Job_kinds.target_of_json (json s) in
  let key s = Job_kinds.target_key (ok_or_fail (parse s)) in
  Alcotest.(check string) "movie" "movie:440" (key {|{"kind":"movie","media_id":440}|});
  Alcotest.(check string) "episode as a string id" "episode:5150"
    (key {|{"kind":"episode","media_id":"5150"}|});
  Alcotest.(check string) "season" "season:12:2"
    (key {|{"kind":"season","series_id":12,"season_number":2}|});
  Alcotest.(check string) "specials are a season" "season:12:0"
    (key {|{"kind":"season","series_id":12,"season_number":0}|});
  Alcotest.(check string) "whole series" "series:12" (key {|{"kind":"series","series_id":12}|});
  Alcotest.(check string) "some seasons" "series:12:1,3"
    (key {|{"kind":"series","series_id":12,"seasons":[1,3]}|});
  List.iter
    (fun (label, s) -> Alcotest.(check bool) label true (is_error (parse s)))
    [
      ("zero id", {|{"kind":"movie","media_id":0}|});
      ("missing id", {|{"kind":"episode"}|});
      ("negative season", {|{"kind":"season","series_id":12,"season_number":-1}|});
      ("bad seasons", {|{"kind":"series","series_id":12,"seasons":"x"}|});
      ("unknown kind", {|{"kind":"album","media_id":1}|});
      ("no kind", {|{"media_id":1}|});
      ("not an object", {|[1]|});
    ];
  (* to_json is the inverse of of_json *)
  List.iter
    (fun s ->
      let t = ok_or_fail (parse s) in
      Alcotest.(check string) ("round trip " ^ s) (Job_kinds.target_key t)
        (Job_kinds.target_key (ok_or_fail (Job_kinds.target_of_json (Job_kinds.target_to_json t)))))
    [
      {|{"kind":"movie","media_id":1}|};
      {|{"kind":"season","series_id":3,"season_number":4}|};
      {|{"kind":"series","series_id":3,"seasons":[2]}|};
    ]

(* ------------------------------------------------------------------ *)
(* search / grab_best                                                  *)
(* ------------------------------------------------------------------ *)

let test_selection_params () =
  let parse ?(grab = false) s = Job_kinds.parse_selection ~find_instance ~grab (json s) in
  let j =
    ok_or_fail
      (parse
         {|{"instance_id":"sonarr","target":{"kind":"episode","media_id":5150},
            "instruction":"  smallest please ","use_ai":false,"grab":true}|})
  in
  Alcotest.(check string) "instance" "sonarr" j.sj_instance.inst_id;
  Alcotest.(check bool) "search never grabs, whatever the params say" false j.sj_options.grab;
  Alcotest.(check (option string)) "instruction trimmed" (Some "smallest please")
    j.sj_options.instruction;
  Alcotest.(check (option bool)) "use_ai" (Some false) j.sj_options.use_ai;
  Alcotest.(check bool) "no gate" true (j.sj_gate = Job_kinds.No_gate);
  Alcotest.(check string) "dedupe key" "search:sonarr:episode:5150"
    (Job_kinds.selection_dedupe_key ~kind:"search" j);
  Alcotest.(check string) "label" "Search \xc2\xb7 Sonarr episode 5150"
    (Job_kinds.selection_label ~grab:false j);
  let g =
    ok_or_fail
      (parse ~grab:true
         {|{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"gate":"automatic"}|})
  in
  Alcotest.(check bool) "grab_best grabs" true g.sj_options.grab;
  Alcotest.(check bool) "automatic gate" true (g.sj_gate = Job_kinds.Automatic_gate);
  Alcotest.(check string) "grab label" "Grab \xc2\xb7 Radarr movie 440"
    (Job_kinds.selection_label ~grab:true g);
  Alcotest.(check string) "grab_best dedupe key" "grab_best:radarr:movie:440"
    (Job_kinds.selection_dedupe_key ~kind:"grab_best" g);
  (* errors *)
  (match parse {|{"instance_id":"nope","target":{"kind":"movie","media_id":1}}|} with
  | Ok _ -> Alcotest.fail "unknown instance accepted"
  | Error e ->
      Alcotest.(check (pair int string)) "unknown instance is a 404"
        (404, "no instance \"nope\" is configured")
        (Responses.split_status_error ~default:400 e));
  List.iter
    (fun (label, s) ->
      match parse s with
      | Ok _ -> Alcotest.failf "%s accepted" label
      | Error e ->
          Alcotest.(check int) (label ^ " is a 400") 400
            (fst (Responses.split_status_error ~default:400 e)))
    [
      ("movie on Sonarr", {|{"instance_id":"sonarr","target":{"kind":"movie","media_id":1}}|});
      ("season on Radarr",
       {|{"instance_id":"radarr","target":{"kind":"season","series_id":1,"season_number":1}}|});
      ("no target", {|{"instance_id":"sonarr"}|});
      ("no instance", {|{"target":{"kind":"movie","media_id":1}}|});
      ("bad use_ai", {|{"instance_id":"radarr","target":{"kind":"movie","media_id":1},"use_ai":"maybe"}|});
      ("bad gate", {|{"instance_id":"radarr","target":{"kind":"movie","media_id":1},"gate":"x"}|});
      ("not an object", {|"radarr"|});
    ]

(* ------------------------------------------------------------------ *)
(* grab_release                                                        *)
(* ------------------------------------------------------------------ *)

let test_release_params () =
  let parse s = Job_kinds.parse_release ~find_instance (json s) in
  let j =
    ok_or_fail
      (parse
         {|{"instance_id":"sonarr","target":{"kind":"season","series_id":12,"season_number":2},
            "release_id":" abc ","guid":"g","indexer_id":4}|})
  in
  Alcotest.(check string) "release id trimmed" "abc" j.rj_release.target_release_id;
  Alcotest.(check (option string)) "guid" (Some "g") j.rj_release.target_guid;
  Alcotest.(check (option int)) "indexer" (Some 4) j.rj_release.target_indexer_id;
  Alcotest.(check string) "dedupe key" "grab_release:sonarr:abc" (Job_kinds.release_dedupe_key j);
  Alcotest.(check string) "label without a title" "Grab release \xc2\xb7 Sonarr series 12 season 2"
    (Job_kinds.release_label j);
  let titled =
    ok_or_fail
      (parse
         {|{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"release_id":"r",
            "release_title":"Come.and.See.1985.1080p"}|})
  in
  Alcotest.(check string) "label with a title" "Grab release \xc2\xb7 Come.and.See.1985.1080p"
    (Job_kinds.release_label titled);
  List.iter
    (fun (label, s) -> Alcotest.(check bool) label true (is_error (parse s)))
    [
      ("whole series", {|{"instance_id":"sonarr","target":{"kind":"series","series_id":12},"release_id":"r"}|});
      ("no release id", {|{"instance_id":"radarr","target":{"kind":"movie","media_id":1}}|});
      ("blank release id", {|{"instance_id":"radarr","target":{"kind":"movie","media_id":1},"release_id":" "}|});
      ("unknown instance", {|{"instance_id":"x","target":{"kind":"movie","media_id":1},"release_id":"r"}|});
    ]

(* ------------------------------------------------------------------ *)
(* seerr_select / seerr_fulfil                                         *)
(* ------------------------------------------------------------------ *)

let test_seerr_params () =
  let id, body =
    ok_or_fail
      (Job_kinds.parse_seerr_select
         (json
            {|{"request_id":7,"grab":true,"instance_id":"sonarr","season_number":2,"approve":true,
               "instruction":"x"}|}))
  in
  Alcotest.(check int) "request id" 7 id;
  Alcotest.(check bool) "grab" true body.sb_options.grab;
  Alcotest.(check (option string)) "instance" (Some "sonarr") body.sb_instance_id;
  Alcotest.(check (option int)) "season" (Some 2) body.sb_season_number;
  Alcotest.(check bool) "approve" true body.sb_approve;
  Alcotest.(check string) "label" "Seerr request #7" (Job_kinds.seerr_label ~request_id:7);
  List.iter
    (fun (label, s) ->
      Alcotest.(check bool) label true (is_error (Job_kinds.parse_seerr_select (json s))))
    [
      ("no request id", {|{"grab":true}|});
      ("zero request id", {|{"request_id":0}|});
      ("bad approve", {|{"request_id":1,"approve":"perhaps"}|});
      ("bad season", {|{"request_id":1,"season_number":-2}|});
    ];
  Alcotest.(check bool) "fulfil needs a request id" true
    (is_error (Job_kinds.request_id_of (json {|{}|})));
  Alcotest.(check int) "fulfil request id as a string" 9
    (ok_or_fail (Job_kinds.request_id_of (json {|{"request_id":"9"}|})))

(* ------------------------------------------------------------------ *)
(* Error statuses                                                      *)
(* ------------------------------------------------------------------ *)

let test_status_errors () =
  let split = Responses.split_status_error ~default:500 in
  Alcotest.(check (pair int string)) "prefixed" (502, "Radarr: timed out")
    (split (Responses.status_error ~status:502 "Radarr: timed out"));
  Alcotest.(check (pair int string)) "no prefix uses the default" (500, "boom") (split "boom");
  Alcotest.(check (pair int string)) "out of range is not a status" (500, "[999] x") (split "[999] x");
  Alcotest.(check (pair int string)) "not digits" (500, "[abc] x") (split "[abc] x");
  Alcotest.(check (pair int string)) "empty message" (409, "") (split "[409] ");
  let sel e = fst (Responses.selection_error_status e) in
  Alcotest.(check (list int)) "selection errors"
    [ 400; 404; 404; 404; 409; 502 ]
    [
      sel (Selection.Bad_request "x");
      sel (Selection.Instance_not_found "x");
      sel (Selection.Media_not_found "x");
      sel (Selection.Release_not_found "x");
      sel (Selection.Release_rejected "x");
      sel (Selection.Arr_error "x");
    ];
  Alcotest.(check (pair int string)) "instance message"
    (404, "no instance \"radarr\" is configured")
    (split (Responses.selection_error (Selection.Instance_not_found "radarr")));
  let seerr e = fst (Responses.seerr_error_status e) in
  Alcotest.(check (list int)) "seerr errors"
    [ 400; 404; 409; 409; 409; 502 ]
    [
      seerr (Seerr_sync.Req_bad_request "x");
      seerr (Seerr_sync.Req_not_found "x");
      seerr (Seerr_sync.Req_unconfigured "x");
      seerr (Seerr_sync.Req_pending "x");
      seerr (Seerr_sync.Req_nothing "x");
      seerr (Seerr_sync.Req_upstream "x");
    ]

(* ------------------------------------------------------------------ *)
(* Webhook jobs                                                        *)
(* ------------------------------------------------------------------ *)

let test_webhook_jobs () =
  let a = Config.default_automatic in
  let kind, params = Automatic.webhook_job { a with auto_grab = false } radarr 440 in
  Alcotest.(check string) "dry run is a search" "search" kind;
  let j = ok_or_fail (Job_kinds.parse_selection ~find_instance ~grab:false params) in
  Alcotest.(check string) "movie target" "movie:440" (Job_kinds.target_key j.sj_target);
  Alcotest.(check bool) "gated like automatic mode" true (j.sj_gate = Job_kinds.Automatic_gate);
  let kind, params = Automatic.webhook_job { a with auto_grab = true } sonarr 5150 in
  Alcotest.(check string) "grabbing is a grab_best" "grab_best" kind;
  let j = ok_or_fail (Job_kinds.parse_selection ~find_instance ~grab:true params) in
  Alcotest.(check string) "episode target" "episode:5150" (Job_kinds.target_key j.sj_target)

let test_seerr_webhook_params () =
  let ev =
    {
      Client.seerr_notification_type = "MEDIA_AUTO_APPROVED";
      seerr_media_type = Some "tv";
      seerr_tmdb_id = Some 1396;
      seerr_tvdb_id = Some 81189;
      seerr_seasons = [ 1; 2 ];
      seerr_subject = Some "Breaking Bad (2008)";
    }
  in
  (match Automatic.seerr_event_of_params (Automatic.seerr_event_to_params ~attempt:3 ev) with
  | Error e -> Alcotest.fail e
  | Ok (back, app, attempt) ->
      Alcotest.(check bool) "round trip" true (back = ev);
      Alcotest.(check bool) "tv is Sonarr" true (app = Types.Sonarr);
      Alcotest.(check int) "attempt" 3 attempt);
  (match
     Automatic.seerr_event_of_params
       (json {|{"notification_type":"MEDIA_APPROVED","media_type":"MOVIE","tmdb_id":"603"}|})
   with
  | Error e -> Alcotest.fail e
  | Ok (ev, app, attempt) ->
      Alcotest.(check bool) "movie is Radarr" true (app = Types.Radarr);
      Alcotest.(check (option int)) "string id" (Some 603) ev.seerr_tmdb_id;
      Alcotest.(check int) "first attempt by default" 1 attempt);
  List.iter
    (fun (label, s) ->
      Alcotest.(check bool) label true (is_error (Automatic.seerr_event_of_params (json s))))
    [
      ("movie without tmdb", {|{"notification_type":"MEDIA_APPROVED","media_type":"movie"}|});
      ("tv without tvdb", {|{"notification_type":"MEDIA_APPROVED","media_type":"tv","tmdb_id":1}|});
      ("no media type", {|{"notification_type":"MEDIA_APPROVED","tmdb_id":1}|});
      ("no notification type", {|{"media_type":"movie","tmdb_id":1}|});
      ("bad seasons", {|{"notification_type":"X","media_type":"tv","tvdb_id":1,"seasons":["a"]}|});
      ("bad attempt", {|{"notification_type":"X","media_type":"movie","tmdb_id":1,"attempt":0}|});
    ]

let () =
  Alcotest.run "pickarr-job-kinds"
    [
      ( "job kinds",
        [
          Alcotest.test_case "targets" `Quick test_targets;
          Alcotest.test_case "search and grab_best params" `Quick test_selection_params;
          Alcotest.test_case "grab_release params" `Quick test_release_params;
          Alcotest.test_case "seerr params" `Quick test_seerr_params;
          Alcotest.test_case "status errors" `Quick test_status_errors;
          Alcotest.test_case "webhook jobs" `Quick test_webhook_jobs;
          Alcotest.test_case "seerr webhook params" `Quick test_seerr_webhook_params;
        ] );
    ]
