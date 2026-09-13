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
            if source = `Json then error_json `Unauthorized message
            else
              html ~status:`Unauthorized
                (Pages.login ~csrf:(Dream.csrf_tag request) ~username ~message:("bad", message) ())
        | Ok user ->
            let* () = Dream.invalidate_session request in
            let* () = Dream.set_session_field request Auth.session_field user in
            Log_buffer.infof "user %s signed in" user;
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

let selection_error_response (e : Selection.error) =
  match e with
  | Selection.Bad_request m -> error_json `Bad_Request m
  | Selection.Instance_not_found id ->
      error_json `Not_Found (Printf.sprintf "no instance \"%s\" is configured" id)
  | Selection.Media_not_found m -> error_json `Not_Found m
  | Selection.Arr_error m -> error_json `Bad_Gateway m

let parse_options request =
  let* body = json_body request in
  match body with
  | Error e -> Lwt.return (Error e)
  | Ok body ->
      Lwt.return
        (Selection.options_of_json ?grab_query:(Dream.query request "grab") body)

let run_selection request
    (resolve : Selection.options -> (Types.selection_result, Selection.error) result Lwt.t)
    =
  let* opts = parse_options request in
  match opts with
  | Error e -> error_json `Bad_Request e
  | Ok opts -> (
      let* result = resolve opts in
      match result with
      | Error e -> selection_error_response e
      | Ok result -> respond_json (Types.selection_result_to_yojson result))

let media_id_param request name =
  match int_of_string_opt (Dream.param request name) with
  | Some id when id > 0 -> Ok id
  | _ ->
      Error
        (Printf.sprintf "\"%s\" must be a positive integer" (Dream.param request name))

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

(* Like [run_selection], but for a whole-series run, which answers with one
   outcome per season instead of a single selection. *)
let run_series_selection request
    (resolve :
      Selection.options -> seasons:int list -> (Selection.series_result, Selection.error) result Lwt.t)
    =
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
          let* result = resolve opts ~seasons in
          match result with
          | Error e -> selection_error_response e
          | Ok result -> respond_json (Selection.series_result_to_yojson result)))

let select_season_on_default (state : App_state.t) request =
  match (media_id_param request "series_id", season_number_param request "season_number") with
  | Error e, _ | _, Error e -> error_json `Bad_Request e
  | Ok series_id, Ok season_number ->
      run_selection request (fun opts ->
          Selection.run_season_on_default state ~series_id ~season_number opts)

let select_season_on_instance (state : App_state.t) request =
  match (media_id_param request "series_id", season_number_param request "season_number") with
  | Error e, _ | _, Error e -> error_json `Bad_Request e
  | Ok series_id, Ok season_number ->
      let instance_id = Dream.param request "instance_id" in
      run_selection request (fun opts ->
          Selection.run_season_on_instance_id state ~instance_id ~series_id ~season_number opts)

let select_series_on_default (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id ->
      run_series_selection request (fun opts ~seasons ->
          Selection.run_series_on_default state ~series_id ~seasons opts)

let select_series_on_instance (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id ->
      let instance_id = Dream.param request "instance_id" in
      run_series_selection request (fun opts ~seasons ->
          Selection.run_series_on_instance_id state ~instance_id ~series_id ~seasons opts)

let get_series_overview (state : App_state.t) request =
  match media_id_param request "series_id" with
  | Error e -> error_json `Bad_Request e
  | Ok series_id -> (
      let instance_id = Dream.param request "instance_id" in
      let* overview = Selection.series_overview state ~instance_id ~series_id in
      match overview with
      | Error e -> selection_error_response e
      | Ok json -> respond_json json)

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
          Log_buffer.infof "configuration updated (%d instance(s), AI %s)"
            (List.length updated.instances)
            (if updated.llm.llm_enabled then "enabled" else "disabled");
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
              respond_json
                (`Assoc
                  [
                    ("applied", `Bool true);
                    ("config", Config.to_yojson ~redact:true updated);
                  ]))
      | _ -> error_json `Bad_Request "\"patch\" must be a JSON object")

let automatic_status (state : App_state.t) _request = respond_json (Automatic.status state)

let automatic_run (state : App_state.t) _request =
  let* summary = Automatic.run_once state in
  respond_json summary

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
                     run_selection request (fun opts ->
                         Selection.run_on_default state ~app:Types.Radarr ~media_id opts)));
          Dream.post "/select/sonarr/episode/:id"
            (guard "POST /api/select/sonarr/episode/:id" (fun request ->
                 match media_id_param request "id" with
                 | Error e -> error_json `Bad_Request e
                 | Ok media_id ->
                     run_selection request (fun opts ->
                         Selection.run_on_default state ~app:Types.Sonarr ~media_id opts)));
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
          Dream.post "/select/:instance_id/:media_id"
            (guard "POST /api/select/:instance_id/:media_id" (fun request ->
                 match media_id_param request "media_id" with
                 | Error e -> error_json `Bad_Request e
                 | Ok media_id ->
                     let instance_id = Dream.param request "instance_id" in
                     run_selection request (fun opts ->
                         Selection.run_on_instance_id state ~instance_id ~media_id opts)));
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
        ];
    ]

(** The complete handler: request log, a stable cookie/CSRF secret, Dream's
    in-memory sessions, then the router. *)
let handler (state : App_state.t) =
  Dream.logger
  @@ Dream.set_secret (Auth.secret state.App_state.auth)
  @@ Dream.memory_sessions
  @@ router state
