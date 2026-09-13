(* Tests for the server stream: persistence, request parsing and the pure
   automatic-mode decision logic. Nothing here touches the network. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Store = Pickarr_server.Store
module Selection = Pickarr_server.Selection
module Automatic = Pickarr_server.Automatic
module Auth = Pickarr_server.Auth

let temp_dir prefix =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  dir

let run = Lwt_main.run

(** Whether [needle] occurs in [haystack]. *)
let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

(* ------------------------------------------------------------------ *)
(* Store                                                               *)
(* ------------------------------------------------------------------ *)

let store_of dir = match run (Store.create ~data_dir:dir ~getenv:(fun _ -> None) ()) with
  | Ok s -> s
  | Error e -> Alcotest.failf "store creation failed: %s" e

let test_store_defaults () =
  let dir = temp_dir "pickarr-store" in
  let store = store_of dir in
  let c = Store.config store in
  Alcotest.(check (list string)) "no instances" [] (List.map (fun (i : Config.instance) -> i.inst_id) c.instances);
  Alcotest.(check bool) "ai off by default" false c.llm.llm_enabled;
  Alcotest.(check string) "config path" (Filename.concat dir "config.json") (Store.config_path store)

let test_store_round_trip () =
  let dir = temp_dir "pickarr-store" in
  let store = store_of dir in
  let updated =
    run
      (Store.update store (fun c ->
           Ok
             {
               c with
               nl_preferences = "Prefer x265 and sensible file sizes.";
               instances =
                 [
                   {
                     inst_id = "radarr-4k";
                     inst_name = "4K Radarr";
                     inst_app = Types.Radarr;
                     inst_url = "http://radarr:7878";
                     inst_api_key = "secret-key";
                     inst_enabled = true;
                     inst_nl_preferences = "Quality matters more than storage.";
                     inst_automatic = true;
                   };
                 ];
             }))
  in
  (match updated with Ok _ -> () | Error e -> Alcotest.failf "update failed: %s" e);
  Alcotest.(check bool) "config file written" true (Sys.file_exists (Store.config_path store));
  (* A second store reading the same directory must observe the same values. *)
  let reloaded = store_of dir in
  let c = Store.config reloaded in
  Alcotest.(check string) "nl preferences persisted" "Prefer x265 and sensible file sizes." c.nl_preferences;
  match c.instances with
  | [ i ] ->
      Alcotest.(check string) "instance id" "radarr-4k" i.inst_id;
      Alcotest.(check string) "api key persisted" "secret-key" i.inst_api_key;
      Alcotest.(check bool) "automatic persisted" true i.inst_automatic;
      Alcotest.(check string) "per-instance prefs" "Quality matters more than storage." i.inst_nl_preferences
  | other -> Alcotest.failf "expected one instance, got %d" (List.length other)

let test_store_env_overrides () =
  let dir = temp_dir "pickarr-store" in
  let env = function
    | "SONARR_URL" -> Some "http://sonarr:8989/"
    | "SONARR_API_KEY" -> Some "abc"
    | "LLM_ENABLED" -> Some "true"
    | "LLM_MODEL" -> Some "local-model"
    | "MIN_SEEDERS" -> Some "5"
    | _ -> None
  in
  match run (Store.create ~data_dir:dir ~getenv:env ()) with
  | Error e -> Alcotest.failf "store creation failed: %s" e
  | Ok store ->
      let c = Store.config store in
      Alcotest.(check bool) "llm enabled from env" true c.llm.llm_enabled;
      Alcotest.(check string) "model from env" "local-model" c.llm.llm_model;
      Alcotest.(check (option int)) "min seeders from env" (Some 5) c.hard_rules.min_seeders;
      (match c.instances with
      | [ i ] ->
          Alcotest.(check string) "trailing slash trimmed" "http://sonarr:8989" i.inst_url;
          Alcotest.(check string) "api key" "abc" i.inst_api_key
      | other -> Alcotest.failf "expected one instance, got %d" (List.length other))

let test_store_rejects_bad_config () =
  let dir = temp_dir "pickarr-store" in
  let oc = open_out (Filename.concat dir "config.json") in
  output_string oc "{ not json";
  close_out oc;
  match run (Store.create ~data_dir:dir ~getenv:(fun _ -> None) ()) with
  | Ok _ -> Alcotest.fail "expected an error for an unparseable config file"
  | Error message ->
      Alcotest.(check bool) "explains that the file is not valid JSON" true
        (contains ~needle:"not valid JSON" message)

(* ------------------------------------------------------------------ *)
(* History                                                             *)
(* ------------------------------------------------------------------ *)

let media : Types.media =
  {
    app = Types.Radarr;
    media_id = 42;
    title = "Some Movie";
    year = Some 2026;
    media_kind = "movie";
    series_type = None;
    season_number = None;
    episode_number = None;
    episode_title = None;
    genres = [];
    runtime_minutes = None;
    quality_profile_id = None;
    quality_profile_name = None;
    tags = [];
    overview = None;
    original_language = None;
    has_file = false;
    existing_quality = None;
    monitored = true;
    path = None;
    extra = [];
  }

let release : Types.release =
  {
    id = "guid-1";
    guid = Some "guid-1";
    indexer_id = Some 3;
    indexer = Some "Test Indexer";
    title = "Some.Movie.2026.1080p.WEB-DL.x265-FLUX";
    size_bytes = 6_600_000_000L;
    seeders = Some 30;
    leechers = Some 2;
    protocol = Types.Torrent;
    age_hours = Some 4.;
    publish_date = None;
    quality = Some "WEBDL-1080p";
    quality_source = Some "web";
    resolution = Some 1080;
    quality_modifier = Some "none";
    quality_weight = Some 50;
    is_repack = false;
    is_proper = false;
    source = Some "WEB-DL";
    codec = Some "x265";
    audio = Some "DDP";
    hdr = [];
    dolby_vision = false;
    dv_profile = None;
    release_group = Some "FLUX";
    languages = [ "English" ];
    custom_formats = [];
    custom_format_score = Some 20;
    arr_approved = true;
    arr_rejected = false;
    arr_temporarily_rejected = false;
    arr_rejection_reasons = [];
    download_allowed = true;
    full_season = false;
    season_number = None;
    mapped_episode_ids = [];
    raw = `Null;
  }

let scored : Types.scored_release = { scored = release; score = 88.5; components = [] }

let result_of ?(grabbed = false) ?(selected = Some scored) () : Types.selection_result =
  {
    media;
    selected;
    candidates = (match selected with None -> [] | Some s -> [ s ]);
    rejected = [];
    reason = "best deterministic score";
    explanation = [ "matches your preference for WEB-DL over WEBRip" ];
    conflicts = [];
    method_ = Types.By_deterministic;
    llm = None;
    grabbed;
    grab_error = None;
    duration_ms = 12;
  }

let test_history_append_and_read () =
  let dir = temp_dir "pickarr-history" in
  let store = store_of dir in
  let entry = Store.history_entry_of_result ~instance_id:"radarr" (result_of ~grabbed:true ()) in
  run (Store.append_history store entry);
  run (Store.append_history store (Store.history_entry_of_result ~instance_id:"radarr" (result_of ~selected:None ())));
  let entries = run (Store.read_history store ~limit:10) in
  Alcotest.(check int) "two entries" 2 (List.length entries);
  (* newest first *)
  let newest = List.hd entries in
  Alcotest.(check (option string)) "newest has no selection" None newest.h_selected_title;
  let oldest = List.nth entries 1 in
  Alcotest.(check (option string))
    "oldest selection title" (Some release.title) oldest.h_selected_title;
  Alcotest.(check bool) "oldest grabbed" true oldest.h_grabbed;
  Alcotest.(check string) "media label" "Some Movie (2026)" oldest.h_media_label;
  Alcotest.(check int) "limit honoured" 1 (List.length (run (Store.read_history store ~limit:1)))

let test_history_skips_corrupt_lines () =
  let dir = temp_dir "pickarr-history" in
  let store = store_of dir in
  let oc = open_out (Store.history_path store) in
  output_string oc "{ broken\n";
  output_string oc (Yojson.Safe.to_string (Store.history_entry_to_yojson (Store.history_entry_of_result ~instance_id:"x" (result_of ()))));
  output_string oc "\n\n";
  close_out oc;
  let entries = run (Store.read_history store ~limit:10) in
  Alcotest.(check int) "only the valid line" 1 (List.length entries)

let test_media_label_episode () =
  let episode =
    {
      media with
      app = Types.Sonarr;
      media_kind = "episode";
      title = "Some Show";
      year = None;
      season_number = Some 2;
      episode_number = Some 7;
      episode_title = Some "Pilot";
    }
  in
  Alcotest.(check string) "episode label" "Some Show S02E07 - Pilot" (Store.media_label episode)

(* ------------------------------------------------------------------ *)
(* Selection request parsing                                           *)
(* ------------------------------------------------------------------ *)

let options = Alcotest.testable
  (fun fmt (o : Selection.options) ->
    Format.fprintf fmt "{grab=%b; instruction=%s; use_ai=%s}" o.grab
      (Option.value o.instruction ~default:"-")
      (match o.use_ai with None -> "-" | Some b -> string_of_bool b))
  (fun (a : Selection.options) (b : Selection.options) ->
    a.grab = b.grab && a.instruction = b.instruction && a.use_ai = b.use_ai)

let parse ?grab_query s =
  Selection.options_of_json ?grab_query (if s = "" then `Null else Yojson.Safe.from_string s)

let test_options_empty_body () =
  Alcotest.(check (result options string))
    "defaults" (Ok { grab = false; instruction = None; use_ai = None }) (parse "")

let test_options_full_body () =
  Alcotest.(check (result options string))
    "all fields"
    (Ok { grab = true; instruction = Some "pick the best quality"; use_ai = Some false })
    (parse {|{"grab":true,"instruction":"pick the best quality","use_ai":false}|})

let test_options_trims_and_ignores_blank_instruction () =
  Alcotest.(check (result options string))
    "blank instruction ignored"
    (Ok { grab = false; instruction = None; use_ai = None })
    (parse {|{"instruction":"   "}|});
  Alcotest.(check (result options string))
    "instruction trimmed"
    (Ok { grab = false; instruction = Some "only this time"; use_ai = None })
    (parse {|{"instruction":"  only this time  "}|})

let test_options_query_grab () =
  Alcotest.(check (result options string))
    "grab from query"
    (Ok { grab = true; instruction = None; use_ai = None })
    (parse ~grab_query:"true" "");
  Alcotest.(check (result options string))
    "body wins over query"
    (Ok { grab = false; instruction = None; use_ai = None })
    (parse ~grab_query:"true" {|{"grab":false}|});
  match parse ~grab_query:"maybe" "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an error for an invalid grab query value"

let test_options_rejects_bad_types () =
  let bad = [ {|{"grab":"perhaps"}|}; {|{"use_ai":3}|}; {|{"instruction":42}|}; {|[1,2]|} ] in
  List.iter
    (fun body ->
      match parse body with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "expected %s to be rejected" body)
    bad

let test_options_ignores_unknown_fields () =
  Alcotest.(check (result options string))
    "media_id and extras tolerated"
    (Ok { grab = true; instruction = None; use_ai = None })
    (parse {|{"media_id":123,"grab":true,"whatever":null}|})

(* ------------------------------------------------------------------ *)
(* Automatic mode                                                      *)
(* ------------------------------------------------------------------ *)

let test_skip_reason () =
  let base =
    Automatic.skip_reason ~now:1000. ~cooldown_seconds:600.
      ~attempts:[ (("sonarr", 7), 900.); (("sonarr", 8), 100.) ]
      ~queue:[ 1 ] ~recently_grabbed:[ 2 ] ~instance_id:"sonarr"
  in
  Alcotest.(check bool) "queued item skipped" true (Option.is_some (base ~media_id:1));
  Alcotest.(check bool) "recently grabbed skipped" true (Option.is_some (base ~media_id:2));
  Alcotest.(check bool) "within cooldown skipped" true (Option.is_some (base ~media_id:7));
  Alcotest.(check (option string)) "cooldown expired" None (base ~media_id:8);
  Alcotest.(check (option string)) "fresh item" None (base ~media_id:99);
  Alcotest.(check (option string))
    "cooldown is per instance" None
    (Automatic.skip_reason ~now:1000. ~cooldown_seconds:600.
       ~attempts:[ (("sonarr", 7), 900.) ] ~queue:[] ~recently_grabbed:[]
       ~instance_id:"radarr" ~media_id:7)

let media_with id = { media with media_id = id }

let test_plan () =
  let wanted = List.map media_with [ 1; 2; 3; 4; 5 ] in
  let chosen, skipped =
    Automatic.plan ~now:1000. ~cooldown_seconds:600.
      ~attempts:[ (("radarr", 3), 990.) ] ~queue:[ 1 ] ~recently_grabbed:[ 2 ]
      ~instance_id:"radarr" ~limit:2 wanted
  in
  Alcotest.(check (list int)) "chosen respects skips and limit" [ 4; 5 ]
    (List.map (fun (m : Types.media) -> m.media_id) chosen);
  Alcotest.(check (list int)) "skipped reported" [ 1; 2; 3 ]
    (List.map (fun ((m : Types.media), _) -> m.media_id) skipped)

let test_plan_zero_limit () =
  let chosen, skipped =
    Automatic.plan ~now:0. ~cooldown_seconds:600. ~attempts:[] ~queue:[]
      ~recently_grabbed:[] ~instance_id:"radarr" ~limit:0
      (List.map media_with [ 1; 2 ])
  in
  Alcotest.(check int) "nothing chosen" 0 (List.length chosen);
  Alcotest.(check int) "everything skipped" 2 (List.length skipped)

let automatic_cfg ?(grab = true) ?(min_confidence = 0.7) () =
  { Config.default_automatic with auto_grab = grab; auto_min_confidence = min_confidence }

let llm_decision confidence : Types.llm_decision =
  {
    selected_id = release.id;
    confidence;
    llm_reason = "best value";
    ranking = [];
    influences = [];
    conflicts = [];
  }

let test_should_grab () =
  let deterministic = result_of () in
  Alcotest.(check bool) "dry run never grabs" false
    (Automatic.should_grab (automatic_cfg ~grab:false ()) deterministic);
  Alcotest.(check bool) "deterministic grabs" true
    (Automatic.should_grab (automatic_cfg ()) deterministic);
  Alcotest.(check bool) "nothing selected" false
    (Automatic.should_grab (automatic_cfg ()) (result_of ~selected:None ()));
  let confident = { deterministic with method_ = Types.By_llm; llm = Some (llm_decision 0.9) } in
  let unsure = { deterministic with method_ = Types.By_llm; llm = Some (llm_decision 0.4) } in
  Alcotest.(check bool) "confident ai grabs" true (Automatic.should_grab (automatic_cfg ()) confident);
  Alcotest.(check bool) "unsure ai does not grab" false (Automatic.should_grab (automatic_cfg ()) unsure);
  let fallback =
    { deterministic with method_ = Types.By_deterministic_fallback "llm timed out" }
  in
  Alcotest.(check bool) "fallback grabs" true (Automatic.should_grab (automatic_cfg ()) fallback)

let test_cooldown_seconds () =
  Alcotest.(check (float 0.001)) "short interval floors at 10 minutes" 600.
    (Automatic.cooldown_seconds { Config.default_automatic with auto_interval_seconds = 60 });
  Alcotest.(check (float 0.001)) "long interval used as is" 3600.
    (Automatic.cooldown_seconds { Config.default_automatic with auto_interval_seconds = 3600 })

let action = Alcotest.testable
  (fun fmt a ->
    Format.fprintf fmt "%s"
      (match a with
      | `Test -> "test"
      | `Ignored why -> "ignored:" ^ why
      | `Full_pass -> "full_pass"
      | `Select ids -> "select:" ^ String.concat "," (List.map string_of_int ids)))
  ( = )

let test_webhook_action () =
  Alcotest.check action "test event"
    `Test
    (Automatic.webhook_action ~trigger_enabled:true ~event:"Test" ~media_ids:[]);
  Alcotest.check action "movie added with id"
    (`Select [ 5 ])
    (Automatic.webhook_action ~trigger_enabled:true ~event:"MovieAdded" ~media_ids:[ 5 ]);
  Alcotest.check action "series add without ids"
    `Full_pass
    (Automatic.webhook_action ~trigger_enabled:true ~event:"SeriesAdd" ~media_ids:[]);
  Alcotest.check action "grab event is not actionable"
    (`Ignored "event not actionable: Grab")
    (Automatic.webhook_action ~trigger_enabled:true ~event:"Grab" ~media_ids:[ 1 ]);
  Alcotest.check action "triggers disabled"
    (`Ignored "webhook triggers are disabled")
    (Automatic.webhook_action ~trigger_enabled:false ~event:"MovieAdded" ~media_ids:[ 1 ])


let seerr_action_t =
  Alcotest.testable
    (fun fmt a ->
      Format.pp_print_string fmt
        (match a with
        | `Test -> "test"
        | `Ignored why -> "ignored:" ^ why
        | `Resolve app -> "resolve:" ^ Pickarr_core.Types.app_to_string app))
    ( = )

let test_seerr_action () =
  let ev ?(nt = "MEDIA_APPROVED") ?media_type ?tmdb ?tvdb () =
    {
      Pickarr_arr.Client.seerr_notification_type = nt;
      seerr_media_type = media_type;
      seerr_tmdb_id = tmdb;
      seerr_tvdb_id = tvdb;
      seerr_seasons = [];
      seerr_subject = None;
    }
  in
  Alcotest.check seerr_action_t "test" `Test
    (Automatic.seerr_action ~trigger_enabled:true (ev ~nt:"TEST_NOTIFICATION" ()));
  Alcotest.check seerr_action_t "movie -> radarr" (`Resolve Pickarr_core.Types.Radarr)
    (Automatic.seerr_action ~trigger_enabled:true (ev ~media_type:"movie" ~tmdb:603 ()));
  Alcotest.check seerr_action_t "tv -> sonarr" (`Resolve Pickarr_core.Types.Sonarr)
    (Automatic.seerr_action ~trigger_enabled:true
       (ev ~nt:"MEDIA_AUTO_APPROVED" ~media_type:"tv" ~tvdb:81189 ()));
  Alcotest.check seerr_action_t "tv without tvdb" (`Ignored "tv request without a tvdbId")
    (Automatic.seerr_action ~trigger_enabled:true (ev ~media_type:"tv" ~tmdb:1 ()));
  Alcotest.check seerr_action_t "available is not actionable"
    (`Ignored "event not actionable: MEDIA_AVAILABLE")
    (Automatic.seerr_action ~trigger_enabled:true (ev ~nt:"MEDIA_AVAILABLE" ~media_type:"movie" ~tmdb:1 ()));
  Alcotest.check seerr_action_t "disabled" (`Ignored "webhook triggers are disabled")
    (Automatic.seerr_action ~trigger_enabled:false (ev ~media_type:"movie" ~tmdb:1 ()))

(* ------------------------------------------------------------------ *)
(* Config plumbing used by the routes                                  *)
(* ------------------------------------------------------------------ *)

let test_effective_nl_preferences () =
  let instance : Config.instance =
    {
      inst_id = "radarr-4k";
      inst_name = "4K Radarr";
      inst_app = Types.Radarr;
      inst_url = "http://radarr:7878";
      inst_api_key = "";
      inst_enabled = true;
      inst_nl_preferences = "Quality matters much more than storage.";
      inst_automatic = false;
    }
  in
  let cfg = { Config.default with nl_preferences = "Prefer x265." } in
  let combined = Config.effective_nl_preferences cfg (Some instance) in
  Alcotest.(check bool) "contains global" true (contains ~needle:"Prefer x265." combined);
  Alcotest.(check bool) "contains instance name" true (contains ~needle:"4K Radarr" combined);
  Alcotest.(check bool) "contains instance preferences" true
    (contains ~needle:"Quality matters much more than storage." combined)

(* ------------------------------------------------------------------ *)
(* Auth                                                                *)
(* ------------------------------------------------------------------ *)

(* Published PBKDF2-HMAC-SHA256 test vectors for P="password", S="salt". *)
let test_pbkdf2_vectors () =
  let check iterations expected =
    let derived = Auth.pbkdf2 ~password:"password" ~salt:"salt" ~iterations ~length:32 in
    Alcotest.(check string) (Printf.sprintf "c=%d" iterations) expected (Auth.to_hex derived)
  in
  check 1 "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b";
  check 2 "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43";
  check 4096 "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"

let test_pbkdf2_length () =
  let long = Auth.pbkdf2 ~password:"password" ~salt:"salt" ~iterations:2 ~length:40 in
  Alcotest.(check int) "requested length" 40 (String.length long);
  Alcotest.(check string) "first block matches the 32 byte vector"
    "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
    (Auth.to_hex (String.sub long 0 32))

let test_hex_round_trip () =
  let raw = "\x00\x01\xfe\xff abc" in
  Alcotest.(check (option string)) "round trip" (Some raw) (Auth.of_hex (Auth.to_hex raw));
  Alcotest.(check (option string)) "invalid hex" None (Auth.of_hex "zz");
  Alcotest.(check (option string)) "odd length" None (Auth.of_hex "abc")

let test_constant_time_equality () =
  Alcotest.(check bool) "equal" true (Auth.equal_constant_time "abcdef" "abcdef");
  Alcotest.(check bool) "different content" false (Auth.equal_constant_time "abcdef" "abcdeg");
  Alcotest.(check bool) "different length" false (Auth.equal_constant_time "abc" "abcd")

let test_password_verification () =
  let creds = Auth.hash_password ~iterations:1000 ~username:"admin" "correct horse" in
  Alcotest.(check bool) "right password" true
    (Auth.verify_password creds ~username:"admin" ~password:"correct horse");
  Alcotest.(check bool) "user name is case insensitive" true
    (Auth.verify_password creds ~username:"Admin" ~password:"correct horse");
  Alcotest.(check bool) "wrong password" false
    (Auth.verify_password creds ~username:"admin" ~password:"correct horde");
  Alcotest.(check bool) "wrong user" false
    (Auth.verify_password creds ~username:"someone" ~password:"correct horse");
  (* Two accounts with the same password must not share a hash. *)
  let other = Auth.hash_password ~iterations:1000 ~username:"admin" "correct horse" in
  Alcotest.(check bool) "salts differ" false
    (Auth.to_hex creds.Auth.password_hash = Auth.to_hex other.Auth.password_hash)

let auth_of ?(getenv = fun (_ : string) -> None) dir =
  match run (Auth.create ~getenv ~data_dir:dir ()) with
  | Ok a -> a
  | Error e -> Alcotest.failf "auth creation failed: %s" e

let test_auth_first_start () =
  let dir = temp_dir "pickarr-auth" in
  let auth = auth_of dir in
  Alcotest.(check bool) "no account yet" false (Auth.is_configured auth);
  Alcotest.(check bool) "authentication required by default" true (Auth.auth_required auth);
  Alcotest.(check int) "api key is 32 hex characters" 32 (String.length (Auth.api_key auth));
  Alcotest.(check bool) "api key is hex" true
    (Option.is_some (Auth.of_hex (Auth.api_key auth)));
  Alcotest.(check bool) "auth.json created on first start" true
    (Sys.file_exists (Filename.concat dir "auth.json"));
  Alcotest.(check bool) "login impossible before setup" true
    (Result.is_error (Auth.check_login auth ~username:"admin" ~password:"whatever"));
  (* The API key and cookie secret must survive a restart. *)
  let reloaded = auth_of dir in
  Alcotest.(check string) "api key is stable" (Auth.api_key auth) (Auth.api_key reloaded);
  Alcotest.(check string) "secret is stable" (Auth.secret auth) (Auth.secret reloaded)

let test_auth_setup_and_login () =
  let dir = temp_dir "pickarr-auth" in
  let auth = auth_of dir in
  Alcotest.(check bool) "short passwords rejected" true
    (Result.is_error (run (Auth.set_credentials auth ~username:"admin" ~password:"short")));
  Alcotest.(check bool) "empty user name rejected" true
    (Result.is_error (run (Auth.set_credentials auth ~username:"  " ~password:"a good password")));
  (match run (Auth.set_credentials auth ~username:"admin" ~password:"a good password") with
  | Ok () -> ()
  | Error e -> Alcotest.failf "set_credentials failed: %s" e);
  Alcotest.(check string) "username" "admin" (Auth.username auth);
  Alcotest.(check bool) "wrong password rejected" true
    (Result.is_error (Auth.check_login auth ~username:"admin" ~password:"nope"));
  (match Auth.check_login auth ~username:"admin" ~password:"a good password" with
  | Ok user -> Alcotest.(check string) "session user" "admin" user
  | Error e -> Alcotest.failf "login failed: %s" e);
  (* A restart must accept the persisted password. *)
  let reloaded = auth_of dir in
  Alcotest.(check bool) "persisted password works" true
    (Result.is_ok (Auth.check_login reloaded ~username:"admin" ~password:"a good password"));
  let stored = Yojson.Safe.from_string (Option.get (Result.to_option (run (Store.read_file (Filename.concat dir "auth.json"))))) in
  Alcotest.(check bool) "plaintext never stored" false
    (contains ~needle:"a good password" (Yojson.Safe.to_string stored))

let test_auth_api_key_and_toggle () =
  let dir = temp_dir "pickarr-auth" in
  let auth = auth_of dir in
  let original = Auth.api_key auth in
  Alcotest.(check bool) "matches" true (Auth.api_key_matches auth (Some original));
  Alcotest.(check bool) "mismatch" false (Auth.api_key_matches auth (Some "nope"));
  Alcotest.(check bool) "absent" false (Auth.api_key_matches auth None);
  (match run (Auth.regenerate_api_key auth) with
  | Ok fresh ->
      Alcotest.(check bool) "regenerated key differs" false (fresh = original);
      Alcotest.(check bool) "old key no longer matches" false
        (Auth.api_key_matches auth (Some original));
      Alcotest.(check string) "persisted" fresh (Auth.api_key (auth_of dir))
  | Error e -> Alcotest.failf "regenerate failed: %s" e);
  (match run (Auth.set_auth_required auth false) with
  | Ok () -> Alcotest.(check bool) "toggled off" false (Auth.auth_required auth)
  | Error e -> Alcotest.failf "toggle failed: %s" e);
  Alcotest.(check bool) "toggle persisted" false (Auth.auth_required (auth_of dir))

let test_auth_env_credentials () =
  let dir = temp_dir "pickarr-auth" in
  let env = function
    | "PICKARR_PASSWORD" -> Some "env password"
    | "PICKARR_USERNAME" -> Some "operator"
    | "PICKARR_API_KEY" -> Some "key-123"
    | "PICKARR_AUTH_REQUIRED" -> Some "false"
    | _ -> None
  in
  let auth = auth_of ~getenv:env dir in
  Alcotest.(check bool) "configured from env" true (Auth.is_configured auth);
  Alcotest.(check bool) "flagged as env credentials" true (Auth.credentials_from_env auth);
  Alcotest.(check bool) "env login works" true
    (Result.is_ok (Auth.check_login auth ~username:"operator" ~password:"env password"));
  Alcotest.(check string) "api key from env" "key-123" (Auth.api_key auth);
  Alcotest.(check bool) "auth requirement from env" false (Auth.auth_required auth);
  Alcotest.(check bool) "env credentials cannot be changed" true
    (Result.is_error (run (Auth.set_credentials auth ~username:"x" ~password:"another one")));
  let stored =
    Option.get (Result.to_option (run (Store.read_file (Filename.concat dir "auth.json"))))
  in
  Alcotest.(check bool) "env password hash not persisted" false
    (contains ~needle:"password_hash\": \"" stored
    && not (contains ~needle:"password_hash\": \"\"" stored))

(* ------------------------------------------------------------------ *)
(* The pure authorisation decision                                     *)
(* ------------------------------------------------------------------ *)

let decision = Alcotest.testable
  (fun fmt d ->
    Format.fprintf fmt "%s"
      (match d with
      | Auth.Allow -> "allow"
      | Auth.Redirect_login -> "redirect_login"
      | Auth.Redirect_setup -> "redirect_setup"
      | Auth.Unauthorized -> "unauthorized"))
  ( = )

let decide ?(auth_required = true) ?(configured = true) ?(kind = Auth.Api_call)
    ?(session_user = None) ?(api_key_ok = false) path =
  Auth.decide ~auth_required ~configured ~kind ~path ~session_user ~api_key_ok

let test_exempt_paths () =
  List.iter
    (fun path ->
      Alcotest.check decision (path ^ " is exempt") Auth.Allow (decide path))
    [
      "/health";
      "/login";
      "/logout";
      "/setup";
      "/static/style.css";
      "/static/app.js";
      "/api/auth/status";
      "/api/webhook/sonarr";
    ];
  Alcotest.(check bool) "exempt_path agrees" true (Auth.exempt_path "/static/x");
  Alcotest.(check bool) "the UI root is not exempt" false (Auth.exempt_path "/");
  Alcotest.(check bool) "the API is not exempt" false (Auth.exempt_path "/api/config")

let test_decide_api_calls () =
  Alcotest.check decision "no session, no key" Auth.Unauthorized (decide "/api/config");
  Alcotest.check decision "valid api key" Auth.Allow (decide ~api_key_ok:true "/api/config");
  Alcotest.check decision "valid session" Auth.Allow
    (decide ~session_user:(Some "admin") "/api/config");
  Alcotest.check decision "blank session user" Auth.Unauthorized
    (decide ~session_user:(Some " ") "/api/config");
  Alcotest.check decision "authentication disabled" Auth.Allow
    (decide ~auth_required:false "/api/config")

let test_decide_browser_pages () =
  Alcotest.check decision "anonymous browser goes to the login page" Auth.Redirect_login
    (decide ~kind:Auth.Browser_page "/");
  Alcotest.check decision "without an account it goes to setup" Auth.Redirect_setup
    (decide ~kind:Auth.Browser_page ~configured:false "/");
  Alcotest.check decision "signed in" Auth.Allow
    (decide ~kind:Auth.Browser_page ~session_user:(Some "admin") "/");
  Alcotest.check decision "api key works for pages too" Auth.Allow
    (decide ~kind:Auth.Browser_page ~api_key_ok:true "/");
  Alcotest.check decision "disabled authentication" Auth.Allow
    (decide ~kind:Auth.Browser_page ~auth_required:false ~configured:false "/")

let () =
  Alcotest.run "pickarr-server"
    [
      ( "store",
        [
          Alcotest.test_case "defaults" `Quick test_store_defaults;
          Alcotest.test_case "round trip" `Quick test_store_round_trip;
          Alcotest.test_case "env overrides" `Quick test_store_env_overrides;
          Alcotest.test_case "rejects invalid config" `Quick test_store_rejects_bad_config;
        ] );
      ( "history",
        [
          Alcotest.test_case "append and read" `Quick test_history_append_and_read;
          Alcotest.test_case "skips corrupt lines" `Quick test_history_skips_corrupt_lines;
          Alcotest.test_case "episode label" `Quick test_media_label_episode;
        ] );
      ( "select request",
        [
          Alcotest.test_case "empty body" `Quick test_options_empty_body;
          Alcotest.test_case "full body" `Quick test_options_full_body;
          Alcotest.test_case "instruction trimming" `Quick
            test_options_trims_and_ignores_blank_instruction;
          Alcotest.test_case "grab query" `Quick test_options_query_grab;
          Alcotest.test_case "rejects bad types" `Quick test_options_rejects_bad_types;
          Alcotest.test_case "ignores unknown fields" `Quick test_options_ignores_unknown_fields;
        ] );
      ( "automatic",
        [
          Alcotest.test_case "skip reason" `Quick test_skip_reason;
          Alcotest.test_case "plan" `Quick test_plan;
          Alcotest.test_case "plan with zero limit" `Quick test_plan_zero_limit;
          Alcotest.test_case "should grab" `Quick test_should_grab;
          Alcotest.test_case "cooldown seconds" `Quick test_cooldown_seconds;
          Alcotest.test_case "webhook action" `Quick test_webhook_action;
          Alcotest.test_case "seerr action" `Quick test_seerr_action;
        ] );
      ( "config",
        [ Alcotest.test_case "effective nl preferences" `Quick test_effective_nl_preferences ]
      );
      ( "auth",
        [
          Alcotest.test_case "pbkdf2 vectors" `Quick test_pbkdf2_vectors;
          Alcotest.test_case "pbkdf2 length" `Quick test_pbkdf2_length;
          Alcotest.test_case "hex round trip" `Quick test_hex_round_trip;
          Alcotest.test_case "constant time equality" `Quick test_constant_time_equality;
          Alcotest.test_case "password verification" `Quick test_password_verification;
          Alcotest.test_case "first start" `Quick test_auth_first_start;
          Alcotest.test_case "setup and login" `Quick test_auth_setup_and_login;
          Alcotest.test_case "api key and toggle" `Quick test_auth_api_key_and_toggle;
          Alcotest.test_case "env credentials" `Quick test_auth_env_credentials;
        ] );
      ( "authorisation",
        [
          Alcotest.test_case "exempt paths" `Quick test_exempt_paths;
          Alcotest.test_case "api calls" `Quick test_decide_api_calls;
          Alcotest.test_case "browser pages" `Quick test_decide_browser_pages;
        ] );
    ]
