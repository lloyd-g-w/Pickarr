(* HTTP API and UI routing.

   Conventions:
   - every response is JSON except the UI routes;
   - errors are [{"error": "..."}] with 400 for bad input, 404 for unknown
     instances/media, 502 for Sonarr/Radarr/LLM failures and 500 for anything
     unexpected (always logged);
   - /api/* requires authentication when a password or an API key is
     configured: a session cookie from POST /api/auth/login, or the API key in
     X-Api-Key or ?apikey= (the query form exists because the *arr webhook UI
     cannot send custom headers). /health and /api/auth/* stay reachable. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client
module Llm = Pickarr_llm.Client
module Rules_proposal = Pickarr_core.Rules_proposal

let ( let* ) = Lwt.bind

(* ------------------------------------------------------------------ *)
(* Responses                                                           *)
(* ------------------------------------------------------------------ *)

let respond_json ?status (json : Yojson.Safe.t) =
  match status with
  | None -> Dream.json (Yojson.Safe.to_string json)
  | Some status -> Dream.json ~status (Yojson.Safe.to_string json)

let error_json status message =
  respond_json ~status (`Assoc [ ("error", `String message) ])

(** Parse a JSON request body. An empty body yields [`Null] so routes with
    entirely optional fields work with no body at all. *)
let json_body request =
  let* body = Dream.body request in
  if String.trim body = "" then Lwt.return (Ok `Null)
  else
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error e ->
        Lwt.return (Error (Printf.sprintf "invalid JSON body: %s" e))
    | json -> Lwt.return (Ok json)

let string_field key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let int_query request key =
  match Dream.query request key with
  | None -> None
  | Some v -> int_of_string_opt (String.trim v)

(** Wrap a handler so that an unexpected exception is logged and answered with
    a 500 instead of escaping into Dream's default error page. *)
let guard name handler request =
  Lwt.catch
    (fun () -> handler request)
    (fun exn ->
      Log_buffer.errorf "unhandled error in %s: %s" name (Printexc.to_string exn);
      error_json `Internal_Server_Error "internal error (see logs)")

(* ------------------------------------------------------------------ *)
(* Auth                                                                *)
(* ------------------------------------------------------------------ *)
(* Authentication                                                      *)
(* ------------------------------------------------------------------ *)

(** The request path without the query string. *)
let request_path request =
  let target = Dream.target request in
  match String.index_opt target '?' with
  | Some i -> String.sub target 0 i
  | None -> target

let given_api_key request =
  match Dream.header request "X-Api-Key" with
  | Some k -> Some k
  | None -> (
      match Dream.query request "apikey" with
      | Some k -> Some k
      | None -> (
          (* Seerr's webhook agent can send a configurable Authorization
             header; accept the raw key or "Bearer <key>". *)
          match Dream.header request "Authorization" with
          | Some v ->
              let v = String.trim v in
              let prefix = "Bearer " in
              let lp = String.length prefix in
              if String.length v > lp && String.lowercase_ascii (String.sub v 0 lp) = String.lowercase_ascii prefix
              then Some (String.trim (String.sub v lp (String.length v - lp)))
              else Some v
          | None -> None))

let session_user request = Dream.session_field request Auth.session_field

(** The authorisation decision for a request, using the pure [Auth.decide]. *)
let decide (state : App_state.t) request =
  let auth = state.App_state.auth in
  let path = request_path request in
  let kind =
    if String.length path >= 4 && String.sub path 0 4 = "/api" then Auth.Api_call
    else Auth.Browser_page
  in
  Auth.decide ~auth_required:(Auth.auth_required auth) ~configured:(Auth.is_configured auth)
    ~kind ~path ~session_user:(session_user request)
    ~api_key_ok:(Auth.api_key_matches auth (given_api_key request))

(** Whether the caller is authenticated (session or API key), ignoring path
    exemptions. Used by /api/auth/status and the login page. *)
let authenticated (state : App_state.t) request =
  let auth = state.App_state.auth in
  Auth.api_key_matches auth (given_api_key request)
  || match session_user request with Some u -> String.trim u <> "" | None -> false

let auth_middleware (state : App_state.t) inner request =
  match decide state request with
  | Auth.Allow -> inner request
  | Auth.Redirect_login -> Dream.redirect request "/login"
  | Auth.Redirect_setup -> Dream.redirect request "/setup"
  | Auth.Unauthorized -> error_json `Unauthorized "unauthorized"

(* ------------------------------------------------------------------ *)
(* Login, logout and first-run setup (server-rendered forms)           *)
(* ------------------------------------------------------------------ *)

let html ?status body =
  match status with None -> Dream.html body | Some status -> Dream.html ~status body

(** Credentials from either an HTML form (CSRF checked) or a JSON body. JSON
    callers are additionally required to be same-origin when they send an
    Origin header, since the session cookie is SameSite=Strict but the body
    cannot carry a CSRF token. *)
let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

(** Whether the caller sent (or expects) JSON rather than an HTML form. *)
let wants_json request =
  let header name = Option.value (Dream.header request name) ~default:"" in
  contains ~needle:"application/json" (header "Content-Type")
  || contains ~needle:"application/json" (header "Accept")

let credentials_from_request request :
    ([ `Form | `Json ] * string * string * bool, string) result Lwt.t =
  let is_json =
    contains ~needle:"application/json"
      (Option.value (Dream.header request "Content-Type") ~default:"")
  in
  if is_json then
    let* body = json_body request in
    match body with
    | Error e -> Lwt.return (Error e)
    | Ok body -> (
        let origin_ok =
          match Dream.header request "Origin" with
          | None -> true
          | Some origin -> (
              match Dream.header request "Host" with
              | None -> false
              | Some host ->
                  let suffix = "//" ^ host in
                  let n = String.length suffix and h = String.length origin in
                  h >= n && String.sub origin (h - n) n = suffix)
        in
        if not origin_ok then Lwt.return (Error "cross-origin login requests are refused")
        else
          match (string_field "username" body, string_field "password" body) with
          | Some username, Some password -> Lwt.return (Ok (`Json, username, password, false))
          | _ -> Lwt.return (Error "\"username\" and \"password\" are required"))
  else
    let* form = Dream.form request in
    match form with
    | `Ok fields ->
        let get k = Option.value (List.assoc_opt k fields) ~default:"" in
        Lwt.return
          (Ok (`Form, get "username", get "password", List.mem_assoc "remember" fields))
    | `Expired _ | `Wrong_session _ ->
        Lwt.return (Error "This form expired. Please try again.")
    | `Invalid_token _ | `Missing_token _ | `Many_tokens _ ->
        Lwt.return (Error "Invalid form submission. Please try again.")
    | `Wrong_content_type -> Lwt.return (Error "Unsupported form encoding.")

let login_page (state : App_state.t) request =
  if not (Auth.is_configured state.App_state.auth) then Dream.redirect request "/setup"
  else if authenticated state request then Dream.redirect request "/"
  else html (Pages.login ~csrf:(Dream.csrf_tag request) ())

let login_submit (state : App_state.t) request =
  let auth = state.App_state.auth in
  if not (Auth.is_configured auth) then Dream.redirect request "/setup"
  else
    let* credentials = credentials_from_request request in
    match credentials with
    | Error message ->
        if wants_json request then error_json `Bad_Request message
        else
          html ~status:`Bad_Request
            (Pages.login ~csrf:(Dream.csrf_tag request) ~message:("bad", message) ())
    | Ok (source, username, password, _remember) -> (
        match Auth.check_login auth ~username ~password with
        | Error message ->
            Log_buffer.warnf "failed login attempt for user \"%s\"" username;
            Activity.event ~level:Events.Warn
              ~data:[ ("username", `String username); ("ip", `String (Dream.client request)) ]
              "auth.login_failed"
              (Printf.sprintf "failed login for \"%s\" from %s" username (Dream.client request));
            if source = `Json then error_json `Unauthorized message
            else
              html ~status:`Unauthorized
                (Pages.login ~csrf:(Dream.csrf_tag request) ~username ~message:("bad", message) ())
        | Ok user ->
            let* () = Dream.invalidate_session request in
            let* () = Dream.set_session_field request Auth.session_field user in
            Log_buffer.infof "user %s signed in" user;
            Activity.event
              ~data:[ ("username", `String user); ("ip", `String (Dream.client request)) ]
              "auth.login"
              (Printf.sprintf "%s signed in from %s" user (Dream.client request));
            if source = `Json then respond_json (`Assoc [ ("ok", `Bool true) ])
            else Dream.redirect request "/")

let setup_page (state : App_state.t) request =
  if Auth.is_configured state.App_state.auth then Dream.redirect request "/login"
  else html (Pages.setup ~csrf:(Dream.csrf_tag request) ())

let setup_submit (state : App_state.t) request =
  let auth = state.App_state.auth in
  if Auth.is_configured auth then Dream.redirect request "/login"
  else
    let fail message =
      html ~status:`Bad_Request
        (Pages.setup ~csrf:(Dream.csrf_tag request) ~message:("bad", message) ())
    in
    let* form = Dream.form request in
    match form with
    | `Ok fields -> (
        let get k = Option.value (List.assoc_opt k fields) ~default:"" in
        let username = get "username" and password = get "password" in
        if password <> get "confirm" then fail "The two passwords do not match."
        else
          let* created = Auth.set_credentials auth ~username ~password in
          match created with
          | Error e -> fail e
          | Ok () ->
              Log_buffer.infof "admin account created for user %s" (Auth.username auth);
              let* () = Dream.invalidate_session request in
              let* () = Dream.set_session_field request Auth.session_field (Auth.username auth) in
              Dream.redirect request "/")
    | `Expired _ | `Wrong_session _ -> fail "This form expired. Please try again."
    | `Invalid_token _ | `Missing_token _ | `Many_tokens _ ->
        fail "Invalid form submission. Please try again."
    | `Wrong_content_type -> fail "Unsupported form encoding."

let logout request =
  (match Dream.session_field request Auth.session_field with
  | Some user when String.trim user <> "" ->
      Activity.event
        ~data:[ ("username", `String user); ("ip", `String (Dream.client request)) ]
        "auth.logout"
        (Printf.sprintf "%s signed out" user)
  | _ -> ());
  let* () = Dream.invalidate_session request in
  if wants_json request then respond_json (`Assoc [ ("ok", `Bool true) ])
  else Dream.redirect request "/login"

(* ------------------------------------------------------------------ *)
(* Security settings (authenticated)                                   *)
(* ------------------------------------------------------------------ *)

let auth_status (state : App_state.t) request =
  respond_json
    (Auth.status_to_yojson ~authenticated:(authenticated state request) state.App_state.auth)

let security_settings (state : App_state.t) _request =
  respond_json (Auth.settings_to_yojson state.App_state.auth)

(** Change the user name and/or password; the current password is required. *)
let security_credentials (state : App_state.t) request =
  let auth = state.App_state.auth in
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      let username =
        match string_field "username" body with
        | Some u when String.trim u <> "" -> String.trim u
        | _ -> Auth.username auth
      in
      match string_field "password" body with
      | None | Some "" -> error_json `Bad_Request "\"password\" is required"
      | Some password -> (
          let current_ok =
            if not (Auth.is_configured auth) then Ok ()
            else
              match string_field "current_password" body with
              | None -> Error (`Bad_Request, "\"current_password\" is required")
              | Some current -> (
                  match
                    Auth.check_login auth ~username:(Auth.username auth) ~password:current
                  with
                  | Ok _ -> Ok ()
                  | Error _ -> Error (`Unauthorized, "The current password is incorrect."))
          in
          match current_ok with
          | Error (status, e) -> error_json status e
          | Ok () -> (
              let* saved = Auth.set_credentials auth ~username ~password in
              match saved with
              | Error e -> error_json `Bad_Request e
              | Ok () ->
                  Log_buffer.infof "credentials changed for user %s" username;
                  (* Keep this session usable under the new user name. *)
                  let* () = Dream.set_session_field request Auth.session_field username in
                  respond_json (Auth.settings_to_yojson auth))))

let security_regenerate_api_key (state : App_state.t) _request =
  let* regenerated = Auth.regenerate_api_key state.App_state.auth in
  match regenerated with
  | Error e -> error_json `Internal_Server_Error e
  | Ok _ ->
      Log_buffer.infof "API key regenerated";
      respond_json (Auth.settings_to_yojson state.App_state.auth)

let security_auth_required (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      match body with
      | `Assoc fields -> (
          match List.assoc_opt "auth_required" fields with
          | Some (`Bool value) -> (
              let* saved = Auth.set_auth_required state.App_state.auth value in
              match saved with
              | Error e -> error_json `Internal_Server_Error e
              | Ok () ->
                  Log_buffer.warnf "authentication requirement set to %s"
                    (if value then "enabled" else "disabled");
                  respond_json (Auth.settings_to_yojson state.App_state.auth))
          | _ -> error_json `Bad_Request "\"auth_required\" must be a boolean")
      | _ -> error_json `Bad_Request "a JSON body is required")

(* ------------------------------------------------------------------ *)

(* Responses that embed a media object get their "open in Sonarr/Radarr" and
   "open in Seerr" URLs added here, at the boundary, so the link shapes live
   in one place (Library) and out of the core types.  [instance_id] is the
   instance the route used; without one, Library falls back to the media's
   app default, which is what the /select/sonarr/... routes select on. *)
let respond_linked (state : App_state.t) ?instance_id ?status (json : Yojson.Safe.t) =
  let config = App_state.config state in
  let instance = Option.bind instance_id (App_state.find_instance state) in
  respond_json ?status (Library.decorate ~config ~instance json)

let selection_error_response (e : Selection.error) =
  match e with
  | Selection.Bad_request m -> error_json `Bad_Request m
  | Selection.Instance_not_found id ->
      error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)
  | Selection.Media_not_found m -> error_json `Not_Found m
  | Selection.Release_not_found m -> error_json `Not_Found m
  | Selection.Release_rejected m -> error_json `Conflict m
  | Selection.Arr_error m -> error_json `Bad_Gateway m

let parse_options request =
  let* body = json_body request in
  match body with
  | Error e -> Lwt.return (Error e)
  | Ok body ->
      Lwt.return
        (Selection.options_of_json ?grab_query:(Dream.query request "grab") body)

(* ------------------------------------------------------------------ *)
(* Actions run as queue jobs                                           *)
(* ------------------------------------------------------------------ *)

(* Every action endpoint below (select, grab, Seerr select, the passes)
   enqueues the matching job (lib/server/job_kinds.ml) so it shows up in the
   queue, then waits for it and answers with the job's result: the same JSON
   and the same status codes as before the queue existed.  A job error
   carries its status as a "[ddd] " prefix (see lib/server/responses.ml).  If
   the job does not finish within three search timeouts plus a minute, the
   answer is 202 {"job": ...} and the caller can poll GET /api/jobs/:id. *)

let error_status code message = error_json (Dream.int_to_status code) message

let job_source request =
  match Dream.header request "X-Pickarr-Source" with
  | Some s when String.lowercase_ascii (String.trim s) = "ui" -> "ui"
  | _ -> "api"

let job_wait_timeout (state : App_state.t) =
  let cfg = App_state.config state in
  float_of_int ((cfg.network.arr_search_timeout_seconds * 3) + 60)

let int_member key json =
  match json with
  | `Assoc fields -> ( match List.assoc_opt key fields with Some (`Int i) -> Some i | _ -> None)
  | _ -> None

(** Answer a job the way its endpoint answered before the queue. *)
let respond_job (job : Yojson.Safe.t) =
  match string_field "status" job with
  | Some "succeeded" -> (
      match job with
      | `Assoc fields -> respond_json (Option.value (List.assoc_opt "result" fields) ~default:`Null)
      | _ -> respond_json `Null)
  | Some "failed" ->
      let code, message =
        Responses.split_status_error ~default:500
          (Option.value (string_field "error" job) ~default:"the job failed")
      in
      error_status code message
  | Some "cancelled" ->
      error_json `Conflict
        (match int_member "id" job with
        | Some id -> Printf.sprintf "job #%d was cancelled" id
        | None -> "the job was cancelled")
  | _ -> respond_json ~status:`Accepted (`Assoc [ ("job", job) ])

(** Enqueue a job and answer with its outcome. *)
let run_job (state : App_state.t) request ~(kind : string) (params : Yojson.Safe.t) =
  match Jobs.enqueue state ~source:(job_source request) kind params with
  | Error e ->
      let code, message = Responses.split_status_error ~default:400 e in
      error_status code message
  | Ok job -> (
      match int_member "id" job with
      | None -> respond_json ~status:`Accepted (`Assoc [ ("job", job) ])
      | Some id -> (
          let* finished = Jobs.wait id ~timeout:(job_wait_timeout state) in
          match finished with
          | Some job -> respond_job job
          | None ->
              respond_json ~status:`Accepted
                (`Assoc [ ("job", Option.value (Jobs.get id) ~default:job) ])))

(** The parameters of a "search" / "grab_best" job. *)
let selection_job_params ~(instance_id : string) ~(target : Yojson.Safe.t)
    (opts : Selection.options) : Yojson.Safe.t =
  `Assoc
    ([ ("instance_id", `String instance_id); ("target", target) ]
    @ (match opts.instruction with Some i -> [ ("instruction", `String i) ] | None -> [])
    @ match opts.use_ai with Some b -> [ ("use_ai", `Bool b) ] | None -> [])

let selection_kind (opts : Selection.options) = if opts.grab then "grab_best" else "search"

let instance_by_id (state : App_state.t) id =
  match App_state.find_instance state id with Some i -> Ok i | None -> Error id

let default_instance_for (state : App_state.t) app =
  match App_state.default_instance state app with
  | Some i -> Ok i
  | None -> Error (Types.app_to_string app)

let unknown_instance_response id =
  error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)

let movie_target id = `Assoc [ ("kind", `String "movie"); ("media_id", `Int id) ]
let episode_target id = `Assoc [ ("kind", `String "episode"); ("media_id", `Int id) ]

(* A media id means a movie on Radarr and an episode on Sonarr. *)
let media_target (inst : Config.instance) id =
  match inst.inst_app with Types.Radarr -> movie_target id | Types.Sonarr -> episode_target id

let season_target ~series_id ~season_number =
  `Assoc
    [
      ("kind", `String "season");
      ("series_id", `Int series_id);
      ("season_number", `Int season_number);
    ]

let series_target ~series_id ~seasons =
  `Assoc
    ([ ("kind", `String "series"); ("series_id", `Int series_id) ]
    @ match seasons with [] -> [] | ns -> [ ("seasons", `List (List.map (fun n -> `Int n) ns)) ])

(** A selection endpoint: options from the body (400), then the instance
    (404), then the job. *)
let run_selection (state : App_state.t) request
    (instance : (Config.instance, string) result) (target : Config.instance -> Yojson.Safe.t) =
  let* opts = parse_options request in
  match opts with
  | Error e -> error_json `Bad_Request e
  | Ok opts -> (
      match instance with
      | Error id -> unknown_instance_response id
      | Ok inst ->
          run_job state request ~kind:(selection_kind opts)
            (selection_job_params ~instance_id:inst.inst_id ~target:(target inst) opts))

let media_id_param request name =
  match int_of_string_opt (Dream.param request name) with
  | Some id when id > 0 -> Ok id
  | _ ->
      Error
        (Printf.sprintf "\"%s\" must be a positive integer" (Dream.param request name))

(* The release-identity fields of a grab-by-hand body, passed on to the
   "grab_release" job unchanged. *)
let release_fields (body : Yojson.Safe.t) =
  match body with
  | `Assoc fields ->
      List.filter
        (fun (k, _) -> List.mem k [ "release_id"; "guid"; "indexer_id"; "release_title" ])
        fields
  | _ -> []

let run_grab_release (state : App_state.t) request ~(body : Yojson.Safe.t)
    (instance_id : string) (target : Config.instance -> Yojson.Safe.t) =
  match instance_by_id state instance_id with
  | Error id -> unknown_instance_response id
  | Ok inst ->
      run_job state request ~kind:"grab_release"
        (`Assoc
          ([ ("instance_id", `String inst.inst_id); ("target", target inst) ] @ release_fields body))

(* Grab one specific candidate rather than the pipeline's winner: the Select
   page puts a Grab button on every candidate row.  The release id comes from
   a previous selection response; see Selection.grab_release_media for how
   the release the user saw is found again. *)
let grab_specific_release (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      match media_id_param request "media_id" with
      | Error e -> error_json `Bad_Request e
      | Ok media_id -> (
          match Selection.grab_target_of_json body with
          | Error e -> error_json `Bad_Request e
          | Ok _ ->
              run_grab_release state request ~body (Dream.param request "instance_id")
                (fun inst -> media_target inst media_id)))

(* ------------------------------------------------------------------ *)
(* Seasons and whole series (Sonarr)                                   *)
(* ------------------------------------------------------------------ *)

(* Season 0 (specials) is a legitimate request, so only negative numbers are
   rejected here. *)
let season_number_param request name =
  match int_of_string_opt (Dream.param request name) with
  | Some n when n >= 0 -> Ok n
  | _ ->
      Error
        (Printf.sprintf "\"%s\" must be a season number (0 or greater)"
           (Dream.param request name))

(* Like [run_selection], but a whole-series run also takes "seasons". *)
let run_series_selection (state : App_state.t) request
    (instance : (Config.instance, string) result) ~(series_id : int) =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      match
        ( Selection.options_of_json ?grab_query:(Dream.query request "grab") body,
          Selection.seasons_of_json body )
      with
      | Error e, _ | _, Error e -> error_json `Bad_Request e
      | Ok opts, Ok seasons -> (
          match instance with
          | Error id -> unknown_instance_response id
          | Ok inst ->
              run_job state request ~kind:(selection_kind opts)
                (selection_job_params ~instance_id:inst.inst_id
                   ~target:(series_target ~series_id ~seasons) opts)))

let select_season_on_default (state : App_state.t) request =
  match (media_id_param request "series_id", season_number_param request "season_number") with
  | Error e, _ | _, Error e -> error_json `Bad_Request e
  | Ok series_id, Ok season_number ->
      run_selection state request (default_instance_for state Types.Sonarr) (fun _ ->
          season_target ~series_id ~season_number)

let select_season_on_instance (state : App_state.t) request =
  match (media_id_param request "series_id", season_number_param request "season_number") with
  | Error e, _ | _, Error e -> error_json `Bad_Request e
  | Ok series_id, Ok season_number ->
      run_selection state request
        (instance_by_id state (Dream.param request "instance_id"))
        (fun _ -> season_target ~series_id ~season_number)

let select_series_on_default (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id ->
      run_series_selection state request (default_instance_for state Types.Sonarr) ~series_id

let select_series_on_instance (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id ->
      run_series_selection state request
        (instance_by_id state (Dream.param request "instance_id"))
        ~series_id

(* The season equivalent of [grab_specific_release]: a pack is named by series
   id and season number, because a season has no media id of its own. *)
let grab_specific_season_release (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      match
        ( media_id_param request "series_id",
          season_number_param request "season_number",
          Selection.grab_target_of_json body )
      with
      | Error e, _, _ | _, Error e, _ | _, _, Error e -> error_json `Bad_Request e
      | Ok series_id, Ok season_number, Ok _ ->
          run_grab_release state request ~body (Dream.param request "instance_id") (fun _ ->
              season_target ~series_id ~season_number))

let get_series_overview (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id -> (
      let instance_id = Dream.param request "instance_id" in
      let* overview = Selection.series_overview state ~instance_id ~series_id in
      match overview with
      | Error e -> selection_error_response e
      | Ok json -> respond_linked state ~instance_id json)

(* ------------------------------------------------------------------ *)
(* Library browsing                                                    *)
(* ------------------------------------------------------------------ *)

(* One text box drives the Search page: a title, or an id pasted from
   Sonarr/Radarr, TMDB, TheTVDB or IMDb.  The instance's library is listed
   once and cached, so the matching itself is local. *)
let library_search (state : App_state.t) request =
  let instance_id = Dream.param request "instance_id" in
  let query = Option.value (Dream.query request "q") ~default:"" in
  let* results = Selection.library_search state ~instance_id ~query in
  match results with
  | Error e -> selection_error_response e
  | Ok json -> respond_linked state ~instance_id json

(* The seasons of a picked series: the same overview the season buttons use. *)
let library_series (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id -> (
      let instance_id = Dream.param request "instance_id" in
      let* overview = Selection.series_overview state ~instance_id ~series_id in
      match overview with
      | Error e -> selection_error_response e
      | Ok json -> respond_linked state ~instance_id json)

(* Loaded on demand when a season row is expanded, so picking a series does
   not fetch every episode of every season up front. *)
let library_season_episodes (state : App_state.t) request =
  match (media_id_param request "series_id", season_number_param request "season_number") with
  | Error e, _ | _, Error e -> error_json `Bad_Request e
  | Ok series_id, Ok season_number -> (
      let instance_id = Dream.param request "instance_id" in
      let* episodes =
        Selection.library_season_episodes state ~instance_id ~series_id ~season_number
      in
      match episodes with
      | Error e -> selection_error_response e
      | Ok json -> respond_linked state ~instance_id json)

let library_movie (state : App_state.t) request =
  match media_id_param request "movie_id" with
  | Error e -> error_json `Bad_Request e
  | Ok movie_id -> (
      let instance_id = Dream.param request "instance_id" in
      let* movie = Selection.library_movie state ~instance_id ~movie_id in
      match movie with
      | Error e -> selection_error_response e
      | Ok json -> respond_linked state ~instance_id json)

(* ------------------------------------------------------------------ *)
(* Handlers                                                            *)
(* ------------------------------------------------------------------ *)

let health _request = respond_json (`Assoc [ ("status", `String "ok") ])

let get_status (state : App_state.t) _request =
  respond_json (App_state.status_to_yojson state)

let get_config (state : App_state.t) _request =
  respond_json (Config.to_yojson ~redact:true (App_state.config state))

(* [Config.of_yojson] reads a missing key and an explicit [null] the same way:
   keep the current value. That is what a partial update needs, but it makes
   the optional numeric limits impossible to clear through the API. Clearing
   is therefore handled here, for exactly the fields that are optional. *)
let apply_explicit_nulls (body : Yojson.Safe.t) (c : Config.t) : Config.t =
  let section name =
    match body with
    | `Assoc fields -> (
        match List.assoc_opt name fields with Some (`Assoc s) -> s | _ -> [])
    | _ -> []
  in
  let cleared fields key =
    match List.assoc_opt key fields with Some `Null -> true | _ -> false
  in
  let hr = section "hard_rules" and pr = section "preferences" in
  let keep_unless_cleared fields key current = if cleared fields key then None else current in
  {
    c with
    hard_rules =
      {
        c.hard_rules with
        max_size_gib = keep_unless_cleared hr "max_size_gib" c.hard_rules.max_size_gib;
        min_size_gib = keep_unless_cleared hr "min_size_gib" c.hard_rules.min_size_gib;
        min_seeders = keep_unless_cleared hr "min_seeders" c.hard_rules.min_seeders;
      };
    preferences =
      {
        c.preferences with
        ideal_size_gib =
          keep_unless_cleared pr "ideal_size_gib" c.preferences.ideal_size_gib;
      };
  }

let patch_config state body =
  Store.update state.App_state.store (fun current ->
      Result.map (apply_explicit_nulls body) (Config.patch current body))

(* Which sections a configuration change touched, by top-level key only:
   never values, so no secret can end up in the event log. *)
let config_sections (body : Yojson.Safe.t) : string list =
  match body with `Assoc fields -> List.map fst fields | _ -> []

let config_event ~(how : string) (body : Yojson.Safe.t) (updated : Config.t) =
  let sections = config_sections body in
  Activity.event
    ~data:
      [
        ("sections", `List (List.map (fun s -> `String s) sections));
        ("via", `String how);
        ("instances", `Int (List.length updated.instances));
        ("ai_enabled", `Bool updated.llm.llm_enabled);
      ]
    "config.updated"
    (Printf.sprintf "configuration updated (%s)%s"
       (match sections with [] -> "no sections" | l -> String.concat ", " l)
       (if how = "settings" then "" else " via " ^ how))

let put_config (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok `Null -> error_json `Bad_Request "a JSON body is required"
  | Ok body -> (
      let* updated = patch_config state body in
      match updated with
      | Error e -> error_json `Bad_Request e
      | Ok updated ->
          App_state.prune_clients state;
          (* Cached search results were scored and filtered with the previous
             rules, so a grab must not be able to use them: a release that the
             new hard rules reject would otherwise still be grabbable from a
             page rendered a moment ago. *)
          Search_cache.clear state.searches;
          Log_buffer.infof "configuration updated (%d instance(s), AI %s)"
            (List.length updated.instances)
            (if updated.llm.llm_enabled then "enabled" else "disabled");
          config_event ~how:"settings" body updated;
          respond_json (Config.to_yojson ~redact:true updated))

let instance_summary ?(status : Yojson.Safe.t = `Null) (i : Config.instance) =
  `Assoc
    [
      ("id", `String i.inst_id);
      ("name", `String i.inst_name);
      ("app", `String (Types.app_to_string i.inst_app));
      ("url", `String i.inst_url);
      ("enabled", `Bool i.inst_enabled);
      ("automatic", `Bool i.inst_automatic);
      ("has_api_key", `Bool (i.inst_api_key <> ""));
      ("nl_preferences", `String i.inst_nl_preferences);
      ("status", status);
    ]

let get_instances (state : App_state.t) _request =
  let cfg = App_state.config state in
  respond_json (`List (List.map (fun i -> instance_summary i) cfg.instances))

let test_instance (state : App_state.t) request =
  let id = Dream.param request "id" in
  match App_state.find_instance state id with
  | None -> error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)
  | Some inst -> (
      let client = App_state.client state inst in
      let* result = Client.test_connection client in
      match result with
      | Ok (app_name, version, instance_name) ->
          Activity.event ~instance_id:inst.inst_id
            ~data:
              [
                ("ok", `Bool true);
                ("app_name", `String app_name);
                ("version", `String version);
              ]
            "instance.tested"
            (Printf.sprintf "%s: connection OK (%s %s)" inst.inst_name app_name version);
          respond_json
            (`Assoc
              [
                ("ok", `Bool true);
                ("app_name", `String app_name);
                ("version", `String version);
                ("instance_name", `String instance_name);
              ])
      | Error e ->
          let msg = Client.error_to_string e in
          Log_buffer.warnf "instance test failed for %s: %s" inst.inst_name msg;
          Activity.event ~level:Events.Warn ~instance_id:inst.inst_id
            ~data:[ ("ok", `Bool false); ("error", `String msg) ]
            "instance.tested"
            (Printf.sprintf "%s: connection failed: %s" inst.inst_name msg);
          respond_json ~status:`Bad_Gateway
            (`Assoc [ ("ok", `Bool false); ("error", `String msg) ]))

let test_llm (state : App_state.t) _request =
  let cfg = App_state.config state in
  let* result =
    Llm.chat_text cfg.llm
      ~system:"You are a connectivity test. Answer with exactly one word."
      ~user:"Reply with the single word: ready"
  in
  match result with
  | Ok text ->
      Activity.event
        ~data:[ ("ok", `Bool true); ("model", `String cfg.llm.llm_model) ]
        "llm.tested"
        (Printf.sprintf "AI connection OK (%s)" cfg.llm.llm_model);
      respond_json
        (`Assoc
          [
            ("ok", `Bool true);
            ("model", `String cfg.llm.llm_model);
            ("base_url", `String cfg.llm.llm_base_url);
            ("reply", `String (String.trim text));
          ])
  | Error e ->
      let msg = Llm.error_to_string e in
      Log_buffer.warnf "LLM test failed: %s" msg;
      Activity.event ~level:Events.Warn
        ~data:[ ("ok", `Bool false); ("model", `String cfg.llm.llm_model); ("error", `String msg) ]
        "llm.tested"
        (Printf.sprintf "AI connection failed (%s): %s" cfg.llm.llm_model msg);
      respond_json ~status:`Bad_Gateway
        (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])

let get_history (state : App_state.t) request =
  let limit = match int_query request "limit" with Some l when l > 0 -> min l 500 | _ -> 50 in
  let* entries = Store.read_history state.App_state.store ~limit in
  respond_json (`List (List.map Store.history_entry_to_yojson entries))

let get_logs _state request =
  let limit = match int_query request "limit" with Some l when l > 0 -> min l 500 | _ -> 200 in
  respond_json (`List (List.map Log_buffer.entry_to_yojson (Log_buffer.recent ~limit)))

let get_wanted (state : App_state.t) request =
  let id = Dream.param request "instance_id" in
  match App_state.find_instance state id with
  | None -> error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)
  | Some inst -> (
      let kind =
        match Dream.query request "kind" with
        | Some "cutoff" -> `Cutoff
        | _ -> `Missing
      in
      let page = match int_query request "page" with Some p when p > 0 -> p | _ -> 1 in
      let page_size =
        match int_query request "page_size" with Some p when p > 0 -> min p 100 | _ -> 25
      in
      let client = App_state.client state inst in
      let* result = Client.wanted client ~kind ~page ~page_size in
      match result with
      | Ok (items, total) ->
          let item_json (m : Types.media) =
            `Assoc
              [
                ("media_id", `Int m.media_id);
                ("label", `String (Store.media_label m));
                ("kind", `String m.media_kind);
                ("media", Types.media_to_yojson m);
              ]
          in
          respond_json
            (`Assoc
               [
                 ("instance_id", `String inst.inst_id);
                 ( "kind",
                   `String (match kind with `Cutoff -> "cutoff" | `Missing -> "missing")
                 );
                 ("page", `Int page);
                 ("page_size", `Int page_size);
                 ("total_records", `Int total);
                 ("items", `List (List.map item_json items));
               ])
      | Error e -> error_json `Bad_Gateway (Client.error_to_string e))

let propose_rules (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      let cfg = App_state.config state in
      let text =
        match string_field "text" body with
        | Some t when String.trim t <> "" -> String.trim t
        | _ -> cfg.nl_preferences
      in
      if String.trim text = "" then
        error_json `Bad_Request
          "no natural language preferences to convert: provide \"text\" or save some first"
      else
        let* reply =
          Llm.chat_json cfg.llm ~system:Rules_proposal.system_prompt
            ~user:(Rules_proposal.build_prompt cfg text)
        in
        match reply with
        | Error e -> error_json `Bad_Gateway (Llm.error_to_string e)
        | Ok json -> (
            match Rules_proposal.parse json with
            | Error e ->
                Log_buffer.warnf "rule proposal rejected: %s" e;
                error_json `Bad_Gateway (Printf.sprintf "the model returned an unusable proposal: %s" e)
            | Ok (patch, summary) ->
                respond_json
                  (`Assoc
                    [
                      ("patch", patch);
                      ("summary", `List (List.map (fun s -> `String s) summary));
                      ("applied", `Bool false);
                    ])))

let apply_rules (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      let patch =
        match body with
        | `Assoc fields -> (
            match List.assoc_opt "patch" fields with Some p -> p | None -> body)
        | other -> other
      in
      match patch with
      | `Assoc _ -> (
          let* updated = patch_config state patch in
          match updated with
          | Error e -> error_json `Bad_Request e
          | Ok updated ->
              Log_buffer.infof "structured rules updated from an approved proposal";
              config_event ~how:"rule proposal" patch updated;
              respond_json
                (`Assoc
                  [
                    ("applied", `Bool true);
                    ("config", Config.to_yojson ~redact:true updated);
                  ]))
      | _ -> error_json `Bad_Request "\"patch\" must be a JSON object")

let automatic_status (state : App_state.t) _request = respond_json (Automatic.status state)

let automatic_run (state : App_state.t) request =
  run_job state request ~kind:"automatic_pass" (`Assoc [])

(* Webhooks are exempt from the session middleware because Sonarr/Radarr
   cannot send headers; the user puts ?apikey=<key> in the configured URL. *)
let webhook (state : App_state.t) request =
  let auth = state.App_state.auth in
  if Auth.auth_required auth && not (authenticated state request) then (
    Log_buffer.warnf "webhook: rejected an unauthenticated call (add ?apikey=<key> to the URL)";
    error_json `Unauthorized "unauthorized")
  else
  let id = Dream.param request "instance_id" in
  match App_state.find_instance state id with
  | None -> error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)
  | Some inst -> (
      let* body = json_body request in
      match body with
      | Error e ->
          (* Acknowledge malformed webhooks: retrying will not help the *arr. *)
          Log_buffer.warnf "webhook: %s: %s" inst.inst_name e;
          respond_json (`Assoc [ ("accepted", `Bool false); ("error", `String e) ])
      | Ok body -> respond_json (Automatic.handle_webhook state inst body))

(* Seerr / Overseerr / Jellyseerr: POST /api/webhook/seerr with the default
   Seerr JSON payload. Authenticate with ?apikey=<key> in the URL or by
   setting Seerr's "Authorization Header" to the Pickarr API key. *)
let seerr_webhook (state : App_state.t) request =
  let auth = state.App_state.auth in
  if Auth.auth_required auth && not (authenticated state request) then (
    Log_buffer.warnf "seerr: rejected an unauthenticated call (add ?apikey=<key> to the URL or set the Authorization header)";
    error_json `Unauthorized "unauthorized")
  else
    let* body = json_body request in
    match body with
    | Error e ->
        Log_buffer.warnf "seerr: %s" e;
        respond_json (`Assoc [ ("accepted", `Bool false); ("error", `String e) ])
    | Ok body -> respond_json (Automatic.handle_seerr_webhook state body)

(* ------------------------------------------------------------------ *)
(* Seerr / Overseerr / Jellyseerr requests                             *)
(* ------------------------------------------------------------------ *)

let seerr_status (state : App_state.t) _request = respond_json (Seerr_sync.status state)

(* Tests the SAVED configuration, like POST /api/instances/:id/test. *)
let seerr_test (state : App_state.t) _request =
  let* result = Seerr_sync.test state in
  match result with
  | Ok json -> respond_json json
  | Error msg ->
      Log_buffer.warnf "seerr test failed: %s" msg;
      respond_json ~status:`Bad_Gateway (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])

let seerr_requests (state : App_state.t) request =
  let filter =
    match Dream.query request "filter" with
    | None -> Ok `Processing
    | Some f -> (
        match Pickarr_arr.Seerr.filter_of_string f with
        | Some f -> Ok f
        | None -> Error (Printf.sprintf "unknown filter \"%s\"" f))
  in
  match filter with
  | Error e -> error_json `Bad_Request e
  | Ok filter -> (
      let take = Option.value (int_query request "take") ~default:30 in
      let* result = Seerr_sync.list_requests state ~filter ~take:(max 1 (min 100 take)) in
      match result with
      | Ok json -> respond_json json
      | Error msg -> error_json `Bad_Gateway msg)

let seerr_request_id request =
  match int_of_string_opt (Dream.param request "id") with
  | Some id when id > 0 -> Ok id
  | _ -> Error "the request id must be a positive integer"

(* Approving here also fulfils the request straight away, so the user does not
   have to wait for the next poll. *)
let seerr_decide (state : App_state.t) ~(approve : bool) request =
  match seerr_request_id request with
  | Error e -> error_json `Bad_Request e
  | Ok request_id -> (
      let* result = Seerr_sync.set_request_status state ~request_id ~approve in
      match result with
      | Error msg -> error_json `Bad_Gateway msg
      | Ok json ->
          (* The fulfilment that follows an approval is a queued job, so the
             answer does not wait for the *arr. *)
          let job =
            if not approve then []
            else
              match
                Jobs.enqueue state ~source:(job_source request) "seerr_fulfil"
                  (`Assoc [ ("request_id", `Int request_id) ])
              with
              | Ok job -> [ ("job_id", Option.fold ~none:`Null ~some:(fun i -> `Int i) (int_member "id" job)) ]
              | Error e ->
                  Log_buffer.warnf "seerr: could not queue the fulfilment of request #%d: %s"
                    request_id e;
                  [ ("job_id", `Null) ]
          in
          respond_json
            (`Assoc
              ([
                 ("ok", `Bool true);
                 ("action", `String (if approve then "approved" else "declined"));
                 ("request", json);
               ]
              @ job)))

let seerr_fulfil (state : App_state.t) request =
  match seerr_request_id request with
  | Error e -> error_json `Bad_Request e
  | Ok request_id -> (
      match
        Jobs.enqueue state ~source:(job_source request) "seerr_fulfil"
          (`Assoc [ ("request_id", `Int request_id) ])
      with
      | Error e ->
          let code, message = Responses.split_status_error ~default:400 e in
          error_status code message
      | Ok job ->
          respond_json
            (`Assoc
               [
                 ("ok", `Bool true);
                 ("action", `String "fulfilling");
                 ("request_id", `Int request_id);
                 ("job_id", Option.fold ~none:`Null ~some:(fun i -> `Int i) (int_member "id" job));
               ]))

let seerr_run (state : App_state.t) request = run_job state request ~kind:"seerr_pass" (`Assoc [])

(* ------------------------------------------------------------------ *)
(* Working a Seerr request like the Select page                        *)
(* ------------------------------------------------------------------ *)

let seerr_request_error_response (e : Seerr_sync.request_error) =
  let message = Seerr_sync.request_error_message e in
  match e with
  | Seerr_sync.Req_bad_request _ -> error_json `Bad_Request message
  | Seerr_sync.Req_not_found _ -> error_json `Not_Found message
  | Seerr_sync.Req_unconfigured _ | Seerr_sync.Req_pending _ | Seerr_sync.Req_nothing _ ->
      error_json `Conflict message
  | Seerr_sync.Req_upstream _ -> error_json `Bad_Gateway message

(* What the request maps to in Sonarr/Radarr, without searching anything: the
   Requests tab shows this before the user previews a selection. *)
let seerr_resolve (state : App_state.t) request =
  match seerr_request_id request with
  | Error e -> error_json `Bad_Request e
  | Ok request_id -> (
      let* result = Seerr_sync.resolve_request state ~request_id in
      match result with
      | Ok json -> respond_json json
      | Error e -> seerr_request_error_response e)

(* Run the pipeline for a request and answer with the same payload the Select
   page renders, so a request can be previewed and grabbed by hand. *)
let seerr_select (state : App_state.t) request =
  match seerr_request_id request with
  | Error e -> error_json `Bad_Request e
  | Ok request_id -> (
      let* body = json_body request in
      match body with
      | Error e -> error_json `Bad_Request e
      | Ok body -> (
          match Seerr_sync.select_body_of_json ?grab_query:(Dream.query request "grab") body with
          | Error e -> error_json `Bad_Request e
          | Ok parsed ->
              (* The job re-parses the body; [grab] is fixed here because a
                 ?grab= query may have set it. *)
              let fields =
                match body with
                | `Assoc f -> List.filter (fun (k, _) -> k <> "grab" && k <> "request_id") f
                | _ -> []
              in
              run_job state request ~kind:"seerr_select"
                (`Assoc
                  ([ ("request_id", `Int request_id); ("grab", `Bool parsed.sb_options.grab) ]
                  @ fields))))

(* ------------------------------------------------------------------ *)
(* UI                                                                  *)
(* ------------------------------------------------------------------ *)

let ui_missing_page = Pages.ui_missing

let index (state : App_state.t) _request =
  match state.App_state.static_dir with
  | None -> Dream.html ~status:`Not_Found ui_missing_page
  | Some dir -> (
      let path = Filename.concat dir "index.html" in
      if not (Sys.file_exists path) then Dream.html ~status:`Not_Found ui_missing_page
      else
        let* contents = Store.read_file path in
        match contents with
        | Ok html -> Dream.html html
        | Error e ->
            Log_buffer.errorf "cannot read %s: %s" path e;
            Dream.html ~status:`Internal_Server_Error ui_missing_page)

let static_handler (state : App_state.t) =
  match state.App_state.static_dir with
  | Some dir -> Dream.static dir
  | None -> fun _request -> Dream.empty `Not_Found

(* ------------------------------------------------------------------ *)
(* Job queue and events (BEGIN queue-core block)                       *)
(* ------------------------------------------------------------------ *)

let job_id_param request =
  match int_of_string_opt (String.trim (Dream.param request "id")) with
  | Some i when i > 0 -> Ok i
  | _ -> Error "job id must be a positive integer"

(* "queued,running", plus the shorthands "active" and "finished". *)
let job_statuses_of_query (raw : string) : (Jobs.status list, string) result =
  let parts =
    String.split_on_char ',' raw |> List.map String.trim |> List.filter (fun s -> s <> "")
  in
  List.fold_left
    (fun acc part ->
      match acc with
      | Error _ -> acc
      | Ok l -> (
          match String.lowercase_ascii part with
          | "active" -> Ok (l @ [ Jobs.Queued; Jobs.Running ])
          | "finished" | "done" -> Ok (l @ [ Jobs.Succeeded; Jobs.Failed; Jobs.Cancelled ])
          | "all" -> Ok l
          | other -> (
              match Jobs.status_of_string other with
              | Some st -> Ok (l @ [ st ])
              | None -> Error (Printf.sprintf "unknown job status %S" part))))
    (Ok []) parts

let post_job (state : App_state.t) request =
  let* body = json_body request in
  match body with
  | Error e -> error_json `Bad_Request e
  | Ok body -> (
      match string_field "kind" body with
      | None -> error_json `Bad_Request "kind is required"
      | Some kind -> (
          let params =
            match body with
            | `Assoc fields -> (
                match List.assoc_opt "params" fields with
                | None | Some `Null -> `Assoc []
                | Some p -> p)
            | _ -> `Assoc []
          in
          let source = Option.value (string_field "source" body) ~default:"api" in
          match Jobs.enqueue state ~source kind params with
          | Ok job -> respond_json ~status:`Accepted (`Assoc [ ("job", job) ])
          | Error e -> error_json `Bad_Request e))

let get_jobs (_ : App_state.t) request =
  let statuses =
    match Dream.query request "status" with
    | None -> Ok []
    | Some raw -> job_statuses_of_query raw
  in
  match statuses with
  | Error e -> error_json `Bad_Request e
  | Ok statuses ->
      let limit = Option.value (int_query request "limit") ~default:100 in
      let include_result =
        match Dream.query request "include" with
        | Some v -> List.mem "result" (List.map String.trim (String.split_on_char ',' v))
        | None -> false
      in
      respond_json
        (Jobs.list ~statuses ?kind:(Dream.query request "kind") ~limit ~include_result ())

let get_job (_ : App_state.t) request =
  match job_id_param request with
  | Error e -> error_json `Bad_Request e
  | Ok id -> (
      match Jobs.get id with
      | None -> error_json `Not_Found (Printf.sprintf "no job %d" id)
      | Some job -> respond_json (`Assoc [ ("job", job) ]))

let cancel_job (_ : App_state.t) request =
  match job_id_param request with
  | Error e -> error_json `Bad_Request e
  | Ok id -> (
      match Jobs.get id with
      | None -> error_json `Not_Found (Printf.sprintf "no job %d" id)
      | Some _ -> (
          match Jobs.cancel id with
          | Ok job -> respond_json (`Assoc [ ("job", job) ])
          | Error e -> error_json `Conflict e))

let retry_job (state : App_state.t) request =
  match job_id_param request with
  | Error e -> error_json `Bad_Request e
  | Ok id -> (
      match Jobs.get id with
      | None -> error_json `Not_Found (Printf.sprintf "no job %d" id)
      | Some _ -> (
          match Jobs.retry state id with
          | Ok job -> respond_json ~status:`Accepted (`Assoc [ ("job", job) ])
          | Error e -> error_json `Conflict e))

let delete_jobs (_ : App_state.t) request =
  match Dream.query request "status" with
  | None -> respond_json (`Assoc [ ("cleared", `Int (Jobs.clear_finished ())) ])
  | Some s when List.mem (String.lowercase_ascii (String.trim s)) [ "finished"; "done" ] ->
      respond_json (`Assoc [ ("cleared", `Int (Jobs.clear_finished ())) ])
  | Some s ->
      error_json `Bad_Request
        (Printf.sprintf "only finished jobs can be cleared (status=finished), not %S" s)

let get_events (_ : App_state.t) request =
  let level =
    match Dream.query request "level" with
    | None -> Ok None
    | Some l when String.trim l = "" -> Ok None
    | Some l -> (
        match Events.level_of_string l with
        | Some lv -> Ok (Some lv)
        | None -> Error (Printf.sprintf "unknown level %S (info, warn or error)" l))
  in
  match level with
  | Error e -> error_json `Bad_Request e
  | Ok min_level ->
      let events, last_id =
        Events.query
          ?since_id:(int_query request "since_id")
          ?limit:(int_query request "limit")
          ?type_prefix:(Dream.query request "type")
          ?min_level
          ?job_id:(int_query request "job_id")
          ?text:(Dream.query request "q")
          ()
      in
      respond_json (`Assoc [ ("events", `List events); ("last_id", `Int last_id) ])

(* ------------------------------------------------------------------ *)
(* (END queue-core block)                                              *)
(* ------------------------------------------------------------------ *)

(* ------------------------------------------------------------------ *)
(* Router                                                              *)
(* ------------------------------------------------------------------ *)

let router (state : App_state.t) =
  Dream.router
    [
      Dream.get "/" (guard "GET /" (fun request ->
          match decide state request with
          | Auth.Allow -> index state request
          | Auth.Redirect_login -> Dream.redirect request "/login"
          | Auth.Redirect_setup -> Dream.redirect request "/setup"
          | Auth.Unauthorized -> error_json `Unauthorized "unauthorized"));
      Dream.get "/health" (guard "GET /health" health);
      Dream.get "/static/**" (guard "GET /static" (static_handler state));
      Dream.get "/login" (guard "GET /login" (login_page state));
      Dream.post "/login" (guard "POST /login" (login_submit state));
      Dream.get "/setup" (guard "GET /setup" (setup_page state));
      Dream.post "/setup" (guard "POST /setup" (setup_submit state));
      Dream.post "/logout" (guard "POST /logout" logout);
      Dream.get "/logout" (guard "GET /logout" logout);
      Dream.get "/api/auth/status" (guard "GET /api/auth/status" (auth_status state));
      Dream.scope "/api"
        [ auth_middleware state ]
        [
          Dream.get "/security" (guard "GET /api/security" (security_settings state));
          Dream.post "/security/credentials"
            (guard "POST /api/security/credentials" (security_credentials state));
          Dream.post "/security/apikey"
            (guard "POST /api/security/apikey" (security_regenerate_api_key state));
          Dream.post "/security/auth-required"
            (guard "POST /api/security/auth-required" (security_auth_required state));
          Dream.get "/status" (guard "GET /api/status" (get_status state));
          Dream.get "/config" (guard "GET /api/config" (get_config state));
          Dream.put "/config" (guard "PUT /api/config" (put_config state));
          Dream.get "/instances" (guard "GET /api/instances" (get_instances state));
          Dream.post "/instances/:id/test"
            (guard "POST /api/instances/:id/test" (test_instance state));
          Dream.post "/llm/test" (guard "POST /api/llm/test" (test_llm state));
          Dream.post "/select/radarr/movie/:id"
            (guard "POST /api/select/radarr/movie/:id" (fun request ->
                 match media_id_param request "id" with
                 | Error e -> error_json `Bad_Request e
                 | Ok media_id ->
                     run_selection state request (default_instance_for state Types.Radarr)
                       (fun _ -> movie_target media_id)));
          Dream.post "/select/sonarr/episode/:id"
            (guard "POST /api/select/sonarr/episode/:id" (fun request ->
                 match media_id_param request "id" with
                 | Error e -> error_json `Bad_Request e
                 | Ok media_id ->
                     run_selection state request (default_instance_for state Types.Sonarr)
                       (fun _ -> episode_target media_id)));
          (* Seasons and whole series: registered before the generic
             /select/:instance_id/:media_id route so that the literal
             "season"/"series" segments always win. *)
          Dream.post "/select/sonarr/season/:series_id/:season_number"
            (guard "POST /api/select/sonarr/season/:series_id/:season_number"
               (select_season_on_default state));
          Dream.post "/select/sonarr/series/:series_id"
            (guard "POST /api/select/sonarr/series/:series_id"
               (select_series_on_default state));
          Dream.post "/select/:instance_id/season/:series_id/:season_number"
            (guard "POST /api/select/:instance_id/season/:series_id/:season_number"
               (select_season_on_instance state));
          Dream.post "/select/:instance_id/series/:series_id"
            (guard "POST /api/select/:instance_id/series/:series_id"
               (select_series_on_instance state));
          Dream.get "/series/:instance_id/:series_id"
            (guard "GET /api/series/:instance_id/:series_id"
               (get_series_overview state));
          (* Library browsing for the Search page.  The literal segments
             "series" and "movie" come before nothing else here, so the order
             within this group does not matter. *)
          Dream.get "/library/:instance_id/search"
            (guard "GET /api/library/:instance_id/search" (library_search state));
          Dream.get "/library/:instance_id/series/:series_id/season/:season_number"
            (guard "GET /api/library/:instance_id/series/:series_id/season/:season_number"
               (library_season_episodes state));
          Dream.get "/library/:instance_id/series/:series_id"
            (guard "GET /api/library/:instance_id/series/:series_id"
               (library_series state));
          Dream.get "/library/:instance_id/movie/:movie_id"
            (guard "GET /api/library/:instance_id/movie/:movie_id" (library_movie state));
          Dream.post "/select/:instance_id/:media_id"
            (guard "POST /api/select/:instance_id/:media_id" (fun request ->
                 match media_id_param request "media_id" with
                 | Error e -> error_json `Bad_Request e
                 | Ok media_id ->
                     run_selection state request
                       (instance_by_id state (Dream.param request "instance_id"))
                       (fun inst -> media_target inst media_id)));
          (* The season form is registered first: it has more segments, and
             the literal "season" must not be read as a media id. *)
          Dream.post "/grab/:instance_id/season/:series_id/:season_number"
            (guard "POST /api/grab/:instance_id/season/:series_id/:season_number"
               (grab_specific_season_release state));
          Dream.post "/grab/:instance_id/:media_id"
            (guard "POST /api/grab/:instance_id/:media_id" (grab_specific_release state));
          Dream.get "/history" (guard "GET /api/history" (get_history state));
          Dream.get "/logs" (guard "GET /api/logs" (get_logs state));
          Dream.get "/wanted/:instance_id" (guard "GET /api/wanted" (get_wanted state));
          Dream.post "/rules/propose" (guard "POST /api/rules/propose" (propose_rules state));
          Dream.post "/rules/apply" (guard "POST /api/rules/apply" (apply_rules state));
          Dream.post "/webhook/seerr" (guard "POST /api/webhook/seerr" (seerr_webhook state));
          Dream.post "/webhook/:instance_id" (guard "POST /api/webhook" (webhook state));
          Dream.get "/automatic/status"
            (guard "GET /api/automatic/status" (automatic_status state));
          Dream.post "/automatic/run" (guard "POST /api/automatic/run" (automatic_run state));
          (* Seerr request integration *)
          Dream.get "/seerr/status" (guard "GET /api/seerr/status" (seerr_status state));
          Dream.post "/seerr/test" (guard "POST /api/seerr/test" (seerr_test state));
          Dream.get "/seerr/requests" (guard "GET /api/seerr/requests" (seerr_requests state));
          Dream.post "/seerr/requests/:id/approve"
            (guard "POST /api/seerr/requests/:id/approve" (seerr_decide state ~approve:true));
          Dream.post "/seerr/requests/:id/decline"
            (guard "POST /api/seerr/requests/:id/decline" (seerr_decide state ~approve:false));
          Dream.post "/seerr/requests/:id/fulfil"
            (guard "POST /api/seerr/requests/:id/fulfil" (seerr_fulfil state));
          Dream.post "/seerr/requests/:id/resolve"
            (guard "POST /api/seerr/requests/:id/resolve" (seerr_resolve state));
          Dream.post "/seerr/requests/:id/select"
            (guard "POST /api/seerr/requests/:id/select" (seerr_select state));
          Dream.post "/seerr/run" (guard "POST /api/seerr/run" (seerr_run state));
          (* BEGIN queue-core routes: job queue and event log *)
          Dream.post "/jobs" (guard "POST /api/jobs" (post_job state));
          Dream.get "/jobs" (guard "GET /api/jobs" (get_jobs state));
          Dream.delete "/jobs" (guard "DELETE /api/jobs" (delete_jobs state));
          Dream.get "/jobs/:id" (guard "GET /api/jobs/:id" (get_job state));
          Dream.post "/jobs/:id/cancel" (guard "POST /api/jobs/:id/cancel" (cancel_job state));
          Dream.post "/jobs/:id/retry" (guard "POST /api/jobs/:id/retry" (retry_job state));
          Dream.get "/events" (guard "GET /api/events" (get_events state));
          (* END queue-core routes *)
        ];
    ]

(** The complete handler: request log, a stable cookie/CSRF secret, Dream's
    in-memory sessions, then the router. *)
let handler (state : App_state.t) =
  Dream.logger
  @@ Dream.set_secret (Auth.secret state.App_state.auth)
  @@ Dream.memory_sessions
  @@ router state
