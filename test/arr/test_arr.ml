(* Tests for the Sonarr/Radarr decoding, mapping and grab-body layers.

   The fixtures under fixtures/ mirror real API payloads; their field names
   and types come from the vendored OpenAPI documents. *)

module T = Pickarr_core.Types
module A = Pickarr_arr

let load name =
  let path = Filename.concat "fixtures" name in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> Yojson.Safe.from_string (really_input_string ic (in_channel_length ic)))

let list_of json =
  match json with `List l -> l | _ -> Alcotest.fail "fixture is not a JSON array"

let opt_string = Alcotest.(check (option string))
let opt_int = Alcotest.(check (option int))
let strings = Alcotest.(check (list string))
let bool_ = Alcotest.(check bool)

(* ------------------------------------------------------------------ *)
(* Sonarr releases                                                     *)
(* ------------------------------------------------------------------ *)

let sonarr_releases () =
  load "sonarr_releases.json" |> list_of
  |> List.map A.Sonarr.release_resource_of_yojson
  |> List.map A.Mapping.release_of_sonarr

let test_sonarr_release_mapping () =
  match sonarr_releases () with
  | [ first; second ] ->
      Alcotest.(check string)
        "id is the guid" "https://indexer.example/api/t/abc123" first.T.id;
      opt_string "guid" (Some "https://indexer.example/api/t/abc123") first.T.guid;
      Alcotest.(check string)
        "title" "Some.Show.S02E05.1080p.WEB-DL.DDP5.1.H.264-NTb" first.T.title;
      Alcotest.(check int64) "size" 2952790016L first.T.size_bytes;
      opt_int "indexer id" (Some 4) first.T.indexer_id;
      opt_string "indexer" (Some "Example Indexer (Prowlarr)") first.T.indexer;
      opt_int "seeders" (Some 44) first.T.seeders;
      opt_int "leechers" (Some 3) first.T.leechers;
      Alcotest.(check bool) "torrent" true (first.T.protocol = T.Torrent);
      opt_string "quality name" (Some "WEBDL-1080p") first.T.quality;
      opt_string "quality source (raw enum)" (Some "web") first.T.quality_source;
      opt_int "resolution from quality model" (Some 1080) first.T.resolution;
      opt_string "normalised source" (Some "WEB-DL") first.T.source;
      opt_string "codec from title" (Some "x264") first.T.codec;
      opt_string "audio from title" (Some "DDP") first.T.audio;
      opt_string "release group from api" (Some "NTb") first.T.release_group;
      strings "languages from api" [ "English" ] first.T.languages;
      opt_int "custom format score" (Some 120) first.T.custom_format_score;
      Alcotest.(check int) "custom formats" 2 (List.length first.T.custom_formats);
      Alcotest.(check string)
        "custom format name" "DD+"
        (List.hd first.T.custom_formats).T.cf_name;
      bool_ "approved" true first.T.arr_approved;
      bool_ "not rejected" false first.T.arr_rejected;
      bool_ "download allowed" true first.T.download_allowed;
      Alcotest.(check (list int)) "mapped episodes" [ 5150 ] first.T.mapped_episode_ids;
      opt_int "season" (Some 2) first.T.season_number;
      bool_ "not full season" false first.T.full_season;
      Alcotest.(check (option (float 0.01))) "age hours" (Some 14.2) first.T.age_hours;
      (* second release: rejected, repack, no seeders, group only in title *)
      bool_ "rejected" true second.T.arr_rejected;
      strings "rejection reasons"
        [ "Not a preferred protocol"; "Language: not wanted" ]
        second.T.arr_rejection_reasons;
      bool_ "download not allowed" false second.T.download_allowed;
      bool_ "repack from revision" true second.T.is_repack;
      bool_ "proper from revision version 2" true second.T.is_proper;
      opt_string "webrip source" (Some "WEBRip") second.T.source;
      opt_string "codec" (Some "x265") second.T.codec;
      opt_string "group parsed from title" (Some "FLUX") second.T.release_group;
      opt_int "no seeders" None second.T.seeders;
      Alcotest.(check bool) "usenet" true (second.T.protocol = T.Usenet);
      strings "languages fall back to title" [] second.T.languages;
      opt_int "negative custom format score" (Some (-50)) second.T.custom_format_score
  | other -> Alcotest.failf "expected 2 releases, got %d" (List.length other)

(* ------------------------------------------------------------------ *)
(* Radarr releases                                                     *)
(* ------------------------------------------------------------------ *)

let radarr_releases () =
  load "radarr_releases.json" |> list_of
  |> List.map A.Radarr.release_resource_of_yojson
  |> List.map A.Mapping.release_of_radarr

let test_radarr_release_mapping () =
  match radarr_releases () with
  | [ remux; webdl ] ->
      Alcotest.(check string) "id is the guid" "Indexer-9f3c1" remux.T.id;
      Alcotest.(check int64) "size" 64424509440L remux.T.size_bytes;
      opt_string "quality name" (Some "Bluray-2160p") remux.T.quality;
      opt_string "raw source enum" (Some "bluray") remux.T.quality_source;
      opt_string "modifier promotes to Remux" (Some "Remux") remux.T.source;
      opt_string "modifier kept" (Some "remux") remux.T.quality_modifier;
      opt_int "resolution" (Some 2160) remux.T.resolution;
      opt_string "codec" (Some "x265") remux.T.codec;
      opt_string "audio" (Some "Atmos") remux.T.audio;
      strings "hdr" [ "HDR10" ] remux.T.hdr;
      bool_ "dolby vision" true remux.T.dolby_vision;
      opt_string "group" (Some "FraMeSToR") remux.T.release_group;
      opt_int "custom format score" (Some 300) remux.T.custom_format_score;
      bool_ "approved" true remux.T.arr_approved;
      Alcotest.(check (list int)) "no episodes for movies" [] remux.T.mapped_episode_ids;
      (* Second: empty guid must fall back to a synthesised id *)
      opt_string "empty guid becomes None" None webdl.T.guid;
      Alcotest.(check bool)
        "synthesised id is a digest" true
        (String.length webdl.T.id = 32 && webdl.T.id <> "");
      opt_string "webdl source" (Some "WEB-DL") webdl.T.source;
      opt_string "modifier none is dropped" None webdl.T.quality_modifier;
      opt_string "codec" (Some "x265") webdl.T.codec;
      strings "languages" [ "English"; "French" ] webdl.T.languages;
      bool_ "temporarily rejected" true webdl.T.arr_temporarily_rejected;
      strings "rejections" [ "Unknown quality profile" ] webdl.T.arr_rejection_reasons
  | other -> Alcotest.failf "expected 2 releases, got %d" (List.length other)

(* ------------------------------------------------------------------ *)
(* Media                                                               *)
(* ------------------------------------------------------------------ *)

let test_media_of_episode () =
  let ep = A.Sonarr.episode_resource_of_yojson (load "sonarr_episode.json") in
  let tags = list_of (load "sonarr_tags.json") |> List.map A.Resources.tag_of_yojson in
  let series =
    match ep.A.Sonarr.er_series with
    | Some s -> s
    | None -> Alcotest.fail "fixture should embed the series"
  in
  let m = A.Mapping.media_of_episode ~tags ~profile_name:"HD-1080p" ep series in
  Alcotest.(check bool) "app" true (m.T.app = T.Sonarr);
  Alcotest.(check int) "media id is the episode id" 5150 m.T.media_id;
  Alcotest.(check string) "title is the series title" "Some Show" m.T.title;
  opt_int "year" (Some 2019) m.T.year;
  Alcotest.(check string) "kind" "episode" m.T.media_kind;
  opt_string "series type" (Some "anime") m.T.series_type;
  opt_int "season" (Some 2) m.T.season_number;
  opt_int "episode" (Some 5) m.T.episode_number;
  opt_string "episode title" (Some "The One With The Release") m.T.episode_title;
  strings "genres" [ "Animation"; "Action" ] m.T.genres;
  opt_int "runtime prefers the episode" (Some 47) m.T.runtime_minutes;
  opt_int "quality profile id" (Some 6) m.T.quality_profile_id;
  opt_string "quality profile name" (Some "HD-1080p") m.T.quality_profile_name;
  strings "tag labels" [ "anime"; "keep-forever" ] m.T.tags;
  opt_string "original language" (Some "Japanese") m.T.original_language;
  bool_ "has file" true m.T.has_file;
  opt_string "existing quality" (Some "HDTV-720p") m.T.existing_quality;
  bool_ "monitored" true m.T.monitored;
  opt_string "path" (Some "/tv/Some Show") m.T.path;
  Alcotest.(check bool)
    "series id in extra" true
    (List.assoc_opt "series_id" m.T.extra = Some (`Int 12));
  Alcotest.(check bool)
    "network in extra" true
    (List.assoc_opt "network" m.T.extra = Some (`String "Example Network"))

let test_media_of_movie () =
  let mv = A.Radarr.movie_resource_of_yojson (load "radarr_movie.json") in
  let m = A.Mapping.media_of_movie ~profile_name:"Ultra-HD" mv in
  Alcotest.(check bool) "app" true (m.T.app = T.Radarr);
  Alcotest.(check int) "media id" 77 m.T.media_id;
  Alcotest.(check string) "title" "Some Movie" m.T.title;
  Alcotest.(check string) "kind" "movie" m.T.media_kind;
  opt_int "year" (Some 2024) m.T.year;
  opt_int "runtime" (Some 122) m.T.runtime_minutes;
  strings "genres" [ "Drama"; "Thriller" ] m.T.genres;
  opt_string "original language" (Some "French") m.T.original_language;
  bool_ "no file" false m.T.has_file;
  opt_string "no existing quality" None m.T.existing_quality;
  opt_string "profile name" (Some "Ultra-HD") m.T.quality_profile_name;
  strings "tags without a tag table" [] m.T.tags;
  Alcotest.(check bool)
    "tmdb id in extra" true
    (List.assoc_opt "tmdb_id" m.T.extra = Some (`Int 654321));
  Alcotest.(check bool)
    "studio in extra" true
    (List.assoc_opt "studio" m.T.extra = Some (`String "Example Studio"))

(* ------------------------------------------------------------------ *)
(* Paging / queue / history decoding                                   *)
(* ------------------------------------------------------------------ *)

let test_wanted_paging () =
  let paging =
    A.Resources.paging_of_yojson A.Sonarr.episode_resource_of_yojson
      (load "sonarr_wanted_missing.json")
  in
  Alcotest.(check int) "total records" 42 paging.A.Resources.total_records;
  Alcotest.(check int) "records" 1 (List.length paging.A.Resources.records);
  let ep = List.hd paging.A.Resources.records in
  Alcotest.(check int) "episode id" 6001 ep.A.Sonarr.er_id;
  match ep.A.Sonarr.er_series with
  | None -> Alcotest.fail "includeSeries=true should embed the series"
  | Some s ->
      let m = A.Mapping.media_of_episode ep s in
      Alcotest.(check string) "media title" "Some Show" m.T.title;
      opt_int "season" (Some 3) m.T.season_number

let test_queue_decoding () =
  let paging =
    A.Resources.paging_of_yojson A.Sonarr.queue_item_of_yojson (load "sonarr_queue.json")
  in
  let ids =
    List.filter_map
      (fun (q : A.Sonarr.queue_item) -> q.A.Sonarr.qi_episode_id)
      paging.A.Resources.records
  in
  Alcotest.(check (list int)) "queued episode ids (nulls dropped)" [ 5150 ] ids

let test_history_decoding () =
  let items =
    list_of (load "sonarr_history_since.json") |> List.map A.Sonarr.history_item_of_yojson
  in
  let grabbed =
    List.filter_map
      (fun (h : A.Sonarr.history_item) ->
        match h.A.Sonarr.hi_event_type with
        | Some "grabbed" -> h.A.Sonarr.hi_episode_id
        | _ -> None)
      items
    |> List.sort_uniq compare
  in
  Alcotest.(check (list int)) "grabbed only" [ 5150; 6001 ] grabbed

(* ------------------------------------------------------------------ *)
(* Grab bodies                                                         *)
(* ------------------------------------------------------------------ *)

let media_stub app kind id =
  {
    T.app;
    media_id = id;
    title = "X";
    year = None;
    media_kind = kind;
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

let test_grab_bodies () =
  let media = media_stub T.Sonarr "episode" 5150 in
  let body = A.Mapping.sonarr_grab_body ~guid:"g-1" ~indexer_id:4 ~media in
  Alcotest.(check string)
    "sonarr body" {|{"guid":"g-1","indexerId":4,"episodeId":5150}|}
    (Yojson.Safe.to_string body);
  let season = media_stub T.Sonarr "season" 12 in
  Alcotest.(check string)
    "sonarr season body omits episodeId" {|{"guid":"g-1","indexerId":4}|}
    (Yojson.Safe.to_string (A.Mapping.sonarr_grab_body ~guid:"g-1" ~indexer_id:4 ~media:season));
  let movie = media_stub T.Radarr "movie" 77 in
  Alcotest.(check string)
    "radarr body" {|{"guid":"g-2","indexerId":2,"movieId":77}|}
    (Yojson.Safe.to_string (A.Mapping.radarr_grab_body ~guid:"g-2" ~indexer_id:2 ~media:movie))

let test_grab_identity_guards () =
  match radarr_releases () with
  | [ remux; webdl ] -> (
      (match A.Mapping.grab_identity remux with
      | Ok (guid, indexer_id) ->
          Alcotest.(check string) "guid" "Indexer-9f3c1" guid;
          Alcotest.(check int) "indexer id" 2 indexer_id
      | Error _ -> Alcotest.fail "valid release should yield a grab identity");
      match A.Mapping.grab_identity webdl with
      | Ok _ -> Alcotest.fail "release without a guid must not be grabbable"
      | Error e ->
          Alcotest.(check bool)
            "message mentions guid" true
            (String.length (A.Mapping.grab_error_message e) > 0
            && e = A.Mapping.Missing_guid))
  | _ -> Alcotest.fail "fixture changed"

(* ------------------------------------------------------------------ *)
(* Webhooks                                                            *)
(* ------------------------------------------------------------------ *)

let test_webhooks () =
  (match A.Client.parse_webhook T.Sonarr (load "sonarr_webhook_grab.json") with
  | Ok (event, ids) ->
      Alcotest.(check string) "event" "Grab" event;
      Alcotest.(check (list int)) "episode ids" [ 5150; 5151 ] ids
  | Error m -> Alcotest.failf "sonarr grab webhook: %s" m);
  (match A.Client.parse_webhook T.Sonarr (load "sonarr_webhook_test.json") with
  | Ok (event, ids) ->
      Alcotest.(check string) "event" "Test" event;
      Alcotest.(check (list int)) "test episode ids" [ 123 ] ids
  | Error m -> Alcotest.failf "sonarr test webhook: %s" m);
  (match A.Client.parse_webhook T.Radarr (load "radarr_webhook_movieadded.json") with
  | Ok (event, ids) ->
      Alcotest.(check string) "event" "MovieAdded" event;
      Alcotest.(check (list int)) "movie id" [ 77 ] ids
  | Error m -> Alcotest.failf "radarr webhook: %s" m);
  (* PascalCase keys (older payloads) must still decode. *)
  (match
     A.Client.parse_webhook T.Radarr
       (`Assoc [ ("EventType", `String "Test"); ("Movie", `Assoc [ ("Id", `Int 5) ]) ])
   with
  | Ok (event, ids) ->
      Alcotest.(check string) "pascal event" "Test" event;
      Alcotest.(check (list int)) "pascal ids" [ 5 ] ids
  | Error m -> Alcotest.failf "pascal-case webhook: %s" m);
  match A.Client.parse_webhook T.Sonarr (`Assoc [ ("nonsense", `Bool true) ]) with
  | Ok _ -> Alcotest.fail "payload without eventType must be rejected"
  | Error _ -> ()

(* ------------------------------------------------------------------ *)
(* HTTP helpers                                                        *)
(* ------------------------------------------------------------------ *)

let test_http_join () =
  Alcotest.(check string)
    "no trailing slash" "http://sonarr:8989/api/v3/release"
    (A.Http.join "http://sonarr:8989" "/api/v3/release");
  Alcotest.(check string)
    "trailing slash" "http://sonarr:8989/api/v3/release"
    (A.Http.join "http://sonarr:8989/" "/api/v3/release");
  Alcotest.(check string)
    "url base preserved" "http://host/sonarr/api/v3/release"
    (A.Http.join "http://host/sonarr/" "/api/v3/release")

let test_http_error_bodies () =
  (match A.Http.parse_error_body 404 {|{"message":"Couldn't find requested release in cache, try searching again"}|} with
  | A.Http.Http_status (404, m) ->
      Alcotest.(check string) "message" "Couldn't find requested release in cache, try searching again" m
  | _ -> Alcotest.fail "expected an Http_status error");
  (match
     A.Http.parse_error_body 400
       {|[{"propertyName":"IndexerId","errorMessage":"Must be greater than 0"}]|}
   with
  | A.Http.Http_status (400, m) ->
      Alcotest.(check string) "validation message" "IndexerId: Must be greater than 0" m
  | _ -> Alcotest.fail "expected an Http_status error");
  match A.Http.parse_error_body 500 "<html>boom</html>" with
  | A.Http.Http_status (500, m) -> Alcotest.(check string) "raw body" "<html>boom</html>" m
  | _ -> Alcotest.fail "expected an Http_status error"

let test_lenient_decoding () =
  (* Unknown fields are ignored, missing optionals default sanely, and a
     wrong-typed field does not raise. *)
  let j =
    `Assoc
      [
        ("title", `String "X.2024.1080p.WEB-DL-GRP");
        ("brandNewFieldFromSonarrV5", `Assoc [ ("a", `Int 1) ]);
        ("seeders", `String "not a number");
        ("size", `Intlit "9007199254740993");
      ]
  in
  let r = A.Mapping.release_of_sonarr (A.Sonarr.release_resource_of_yojson j) in
  Alcotest.(check string) "title" "X.2024.1080p.WEB-DL-GRP" r.T.title;
  Alcotest.(check int64) "big size via Intlit" 9007199254740993L r.T.size_bytes;
  opt_int "bad seeders become None" None r.T.seeders;
  opt_int "no indexer id" None r.T.indexer_id;
  bool_ "defaults to not rejected" false r.T.arr_rejected;
  opt_string "source still parsed from the title" (Some "WEB-DL") r.T.source


let test_seerr_webhook () =
  let open Pickarr_arr.Client in
  let payload =
    Yojson.Safe.from_string
      {|{"notification_type":"MEDIA_AUTO_APPROVED","event":"TV Request Automatically Approved",
         "subject":"Some Show (2019)","message":"...","image":"",
         "media":{"media_type":"tv","tmdbId":"1396","tvdbId":"81189","imdbId":"","status":"PROCESSING","status4k":"UNKNOWN"},
         "request":{"request_id":"12","requestedBy_email":"a@b.c","requestedBy_username":"alice"},
         "extra":[{"name":"Requested Seasons","value":"1, 2"}]}|}
  in
  (match parse_seerr_webhook payload with
  | Error e -> Alcotest.fail e
  | Ok ev ->
      Alcotest.(check string) "type" "MEDIA_AUTO_APPROVED" ev.seerr_notification_type;
      Alcotest.(check (option string)) "media type" (Some "tv") ev.seerr_media_type;
      Alcotest.(check (option int)) "tmdb (string in payload)" (Some 1396) ev.seerr_tmdb_id;
      Alcotest.(check (option int)) "tvdb" (Some 81189) ev.seerr_tvdb_id;
      Alcotest.(check (list int)) "seasons" [ 1; 2 ] ev.seerr_seasons;
      Alcotest.(check (option string)) "subject" (Some "Some Show (2019)") ev.seerr_subject);
  (* Movie with numeric ids and no extra; media null for a test notification. *)
  (match
     parse_seerr_webhook
       (Yojson.Safe.from_string
          {|{"notification_type":"MEDIA_APPROVED","subject":"Film","media":{"media_type":"movie","tmdbId":603,"tvdbId":""}}|})
   with
  | Error e -> Alcotest.fail e
  | Ok ev ->
      Alcotest.(check (option int)) "tmdb numeric" (Some 603) ev.seerr_tmdb_id;
      Alcotest.(check (option int)) "tvdb empty" None ev.seerr_tvdb_id;
      Alcotest.(check (list int)) "no seasons" [] ev.seerr_seasons);
  (match
     parse_seerr_webhook
       (Yojson.Safe.from_string {|{"notification_type":"TEST_NOTIFICATION","media":null,"extra":[]}|})
   with
  | Error e -> Alcotest.fail e
  | Ok ev ->
      Alcotest.(check (option string)) "no media" None ev.seerr_media_type;
      Alcotest.(check string) "test" "TEST_NOTIFICATION" ev.seerr_notification_type);
  Alcotest.(check bool) "missing type is an error" true
    (Result.is_error (parse_seerr_webhook (`Assoc [ ("subject", `String "x") ])))

(* ------------------------------------------------------------------ *)
(* Grab response handling (regression: docs/GRAB_BUG_NOTES.md)          *)
(* ------------------------------------------------------------------ *)

(* A throwaway HTTP server that answers one request with a fixed status and
   body, so the real Cohttp client path is exercised.  Returns the port. *)
let serve_once ~(status : int) ~(body : string) : int * unit Lwt.t =
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt socket Unix.SO_REUSEADDR true;
  Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) |> Lwt_main.run;
  Lwt_unix.listen socket 1;
  let port =
    match Lwt_unix.getsockname socket with
    | Unix.ADDR_INET (_, p) -> p
    | Unix.ADDR_UNIX _ -> Alcotest.fail "expected an inet socket"
  in
  let served =
    let open Lwt.Infix in
    Lwt_unix.accept socket >>= fun (client, _) ->
    let buf = Bytes.create 65536 in
    Lwt_unix.read client buf 0 (Bytes.length buf) >>= fun _ ->
    let response =
      Printf.sprintf
        "HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: \
         close\r\n\r\n%s"
        status (String.length body) body
    in
    let bytes = Bytes.of_string response in
    Lwt_unix.write client bytes 0 (Bytes.length bytes) >>= fun _ ->
    Lwt_unix.close client >>= fun () -> Lwt_unix.close socket
  in
  (port, served)

let post_unit_to ~status ~body =
  let port, served = serve_once ~status ~body in
  Lwt_main.run
    (Lwt.both served
       (A.Http.post_unit
          ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
          ~api_key:"k" "/api/v3/release"
          (`Assoc [ ("guid", `String "g"); ("indexerId", `Int 4) ])))
  |> snd

(* POST /api/v3/release echoes the posted resource, but Pickarr must treat the
   status code as the outcome: an empty, null-filled, plain-text or
   proxy-rewritten 2xx body is still a completed grab. *)
let test_grab_response_handling () =
  let ok label r =
    Alcotest.(check bool) (label ^ " counts as a successful grab") true (Result.is_ok r)
  in
  ok "echoed resource" (post_unit_to ~status:201 ~body:{|{"guid":"g","indexerId":4}|});
  ok "mostly-null resource"
    (post_unit_to ~status:200 ~body:{|{"guid":null,"indexerId":0,"title":null}|});
  ok "empty body" (post_unit_to ~status:200 ~body:"");
  ok "plain text body" (post_unit_to ~status:200 ~body:"Release grabbed");
  ok "202 accepted" (post_unit_to ~status:202 ~body:"");
  (* Failures must keep the *arr message so the UI can show it. *)
  (match
     post_unit_to ~status:404
       ~body:{|{"message":"Couldn't find requested release in cache, try searching again"}|}
   with
  | Error (A.Http.Http_status (404, m)) ->
      Alcotest.(check string) "404 message"
        "Couldn't find requested release in cache, try searching again" m
  | Error e -> Alcotest.failf "expected Http_status 404, got %s" (A.Http.error_to_string e)
  | Ok () -> Alcotest.fail "404 must not count as a grab");
  match post_unit_to ~status:409 ~body:{|{"message":"Unable to add release"}|} with
  | Error (A.Http.Http_status (409, m)) ->
      Alcotest.(check string) "409 message" "Unable to add release" m
  | Error e -> Alcotest.failf "expected Http_status 409, got %s" (A.Http.error_to_string e)
  | Ok () -> Alcotest.fail "409 must not count as a grab"

(* ------------------------------------------------------------------ *)
(* Seerr request API                                                   *)
(* ------------------------------------------------------------------ *)

let test_seerr_requests () =
  let page = A.Seerr.request_page_of_yojson (load "seerr_requests_processing.json") in
  Alcotest.(check int) "page" 1 page.rp_page_info.pi_page;
  Alcotest.(check int) "pages" 2 page.rp_page_info.pi_pages;
  Alcotest.(check int) "page size" 2 page.rp_page_info.pi_page_size;
  Alcotest.(check int) "total results" 3 page.rp_page_info.pi_results;
  match page.rp_results with
  | [ movie; tv ] ->
      Alcotest.(check int) "movie request id" 41 movie.rq_id;
      Alcotest.(check int) "approved" A.Seerr.status_approved movie.rq_status;
      opt_string "type" (Some "movie") movie.rq_type;
      bool_ "not 4k" false movie.rq_is4k;
      opt_int "tmdb" (Some 603) movie.rq_media.mi_tmdb_id;
      opt_int "tvdb is null" None movie.rq_media.mi_tvdb_id;
      opt_int "radarr movie id" (Some 912) (A.Seerr.request_external_service_id movie);
      Alcotest.(check int)
        "media status is the non-4k one" A.Seerr.media_processing
        (A.Seerr.request_media_status movie);
      opt_string "requested by display name" (Some "alice")
        (Option.bind movie.rq_requested_by (fun u -> u.us_name));
      Alcotest.(check (list int)) "movie has no seasons" [] (A.Seerr.season_numbers movie);
      Alcotest.(check int) "tv request id" 42 tv.rq_id;
      bool_ "4k" true tv.rq_is4k;
      opt_int "tvdb" (Some 81189) tv.rq_media.mi_tvdb_id;
      Alcotest.(check (list int))
        "specials dropped, seasons sorted" [ 2; 3 ] (A.Seerr.season_numbers tv);
      (* A 4K request tracks status4k, not the (already available) status. *)
      Alcotest.(check int)
        "4k media status" A.Seerr.media_processing (A.Seerr.request_media_status tv);
      opt_int "sonarr series id for the 4k copy" (Some 44)
        (A.Seerr.request_external_service_id tv);
      opt_string "plex username as the fallback name" (Some "bob")
        (Option.bind tv.rq_requested_by (fun u -> u.us_name))
  | other -> Alcotest.failf "expected 2 requests, got %d" (List.length other)

let test_seerr_pending_and_counts () =
  let page = A.Seerr.request_page_of_yojson (load "seerr_requests_pending.json") in
  (match page.rp_results with
  | [ r ] ->
      Alcotest.(check int) "pending" A.Seerr.status_pending r.rq_status;
      opt_int "no arr id before the push" None (A.Seerr.request_external_service_id r)
  | other -> Alcotest.failf "expected 1 request, got %d" (List.length other));
  let st = A.Seerr.status_of_yojson (load "seerr_status.json") in
  Alcotest.(check string) "version" "3.0.1" st.sv_version;
  bool_ "no update" false st.sv_update_available;
  let c = A.Seerr.counts_of_yojson (load "seerr_request_count.json") in
  Alcotest.(check int) "pending count" 2 c.ct_pending;
  Alcotest.(check int) "processing count" 3 c.ct_processing

let test_seerr_titles () =
  let m = A.Seerr.movie_title_of_yojson (load "seerr_movie.json") in
  Alcotest.(check string) "movie title" "The Matrix" m.ti_title;
  opt_int "release year" (Some 1999) m.ti_year;
  let t = A.Seerr.tv_title_of_yojson (load "seerr_tv.json") in
  Alcotest.(check string) "tv name" "Breaking Bad" t.ti_title;
  opt_int "first air year" (Some 2008) t.ti_year;
  (* Missing dates and names must not raise. *)
  let empty = A.Seerr.movie_title_of_yojson (`Assoc []) in
  Alcotest.(check string) "no title" "" empty.ti_title;
  opt_int "no year" None empty.ti_year

let test_seerr_filters_and_lenience () =
  Alcotest.(check string) "processing" "processing" (A.Seerr.filter_to_string `Processing);
  bool_ "pending parses" true (A.Seerr.filter_of_string "PENDING" = Some `Pending);
  bool_ "unknown filter" true (A.Seerr.filter_of_string "nonsense" = None);
  (* A payload with neither type nor seasons still decodes; the media row
     supplies the type. *)
  let r =
    A.Seerr.request_of_yojson
      (Yojson.Safe.from_string {|{"id":9,"status":2,"media":{"mediaType":"TV","tmdbId":5}}|})
  in
  opt_string "type from the media row, lowercased" (Some "tv") r.rq_type;
  Alcotest.(check (list int)) "no seasons" [] (A.Seerr.season_numbers r);
  bool_ "not 4k by default" false r.rq_is4k;
  Alcotest.(check int) "unknown media status by default" A.Seerr.media_unknown
    (A.Seerr.request_media_status r);
  Alcotest.(check string) "status label" "approved"
    (A.Seerr.request_status_to_string r.rq_status);
  (* An empty page must not raise either. *)
  let empty = A.Seerr.request_page_of_yojson (`Assoc []) in
  Alcotest.(check int) "no results" 0 (List.length empty.rp_results)

let tests =
  [
    ("sonarr release mapping", `Quick, test_sonarr_release_mapping);
    ("radarr release mapping", `Quick, test_radarr_release_mapping);
    ("media of episode", `Quick, test_media_of_episode);
    ("media of movie", `Quick, test_media_of_movie);
    ("wanted paging", `Quick, test_wanted_paging);
    ("queue decoding", `Quick, test_queue_decoding);
    ("history decoding", `Quick, test_history_decoding);
    ("grab bodies", `Quick, test_grab_bodies);
    ("grab identity guards", `Quick, test_grab_identity_guards);
    ("webhooks", `Quick, test_webhooks);
    ("seerr webhook", `Quick, test_seerr_webhook);
    ("seerr requests", `Quick, test_seerr_requests);
    ("seerr pending and counts", `Quick, test_seerr_pending_and_counts);
    ("seerr titles", `Quick, test_seerr_titles);
    ("seerr filters and lenience", `Quick, test_seerr_filters_and_lenience);
    ("http join", `Quick, test_http_join);
    ("http error bodies", `Quick, test_http_error_bodies);
    ("grab response handling", `Quick, test_grab_response_handling);
    ("lenient decoding", `Quick, test_lenient_decoding);
  ]

let () = Alcotest.run "pickarr-arr" [ ("arr", tests) ]
