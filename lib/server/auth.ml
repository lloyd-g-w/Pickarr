(* Forms authentication for Pickarr, modelled on Sonarr/Radarr's
   "Forms (Login Page)" mode.

   State lives in [$DATA_DIR/auth.json], separate from config.json:

     { "username", "password_hash", "salt", "iterations", "algorithm",
       "api_key", "auth_required", "secret" }

   Passwords are stored as PBKDF2-HMAC-SHA256 derived keys (RFC 8018) computed
   with digestif's HMAC-SHA256; the plaintext is never written anywhere.

   Credential sources, in priority order:
   1. PICKARR_USERNAME / PICKARR_PASSWORD environment variables, which are
      never persisted and suit immutable container deployments;
   2. the stored auth.json, created by the first-run setup page.

   Sessions are Dream sessions; this module only decides *whether* a request is
   allowed (see [decide]), it does not touch cookies. *)

let ( let* ) = Lwt.bind

let session_field = "pickarr_user"
let default_iterations = 210_000
let key_length = 32
let algorithm = "pbkdf2-hmac-sha256"

(* ------------------------------------------------------------------ *)
(* PBKDF2-HMAC-SHA256                                                  *)
(* ------------------------------------------------------------------ *)

let hmac_sha256 ~key data = Digestif.SHA256.(to_raw_string (hmac_string ~key data))

let xor_strings a b =
  String.init (String.length a) (fun i -> Char.chr (Char.code a.[i] lxor Char.code b.[i]))

(** [pbkdf2 ~password ~salt ~iterations ~length] is the RFC 8018 PBKDF2
    derived key using HMAC-SHA256 as the pseudo-random function. *)
let pbkdf2 ~password ~salt ~iterations ~length =
  let hash_length = Digestif.SHA256.digest_size in
  let blocks = (length + hash_length - 1) / hash_length in
  let buffer = Buffer.create (blocks * hash_length) in
  for index = 1 to blocks do
    let int_be = String.init 4 (fun i -> Char.chr ((index lsr (8 * (3 - i))) land 0xff)) in
    let u1 = hmac_sha256 ~key:password (salt ^ int_be) in
    let result = ref u1 and previous = ref u1 in
    for _ = 2 to iterations do
      let u = hmac_sha256 ~key:password !previous in
      previous := u;
      result := xor_strings !result u
    done;
    Buffer.add_string buffer !result
  done;
  String.sub (Buffer.contents buffer) 0 length

let to_hex s =
  String.concat ""
    (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let of_hex s =
  let n = String.length s / 2 in
  if String.length s mod 2 <> 0 then None
  else
    try Some (String.init n (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2))))
    with _ -> None

(** Constant-time comparison, so a wrong password or API key cannot be
    discovered by timing the comparison. *)
let equal_constant_time a b =
  String.length a = String.length b
  &&
  let acc = ref 0 in
  String.iteri (fun i c -> acc := !acc lor (Char.code c lxor Char.code b.[i])) a;
  !acc = 0

(** Cryptographically strong random hex string of [bytes * 2] characters. *)
let random_hex bytes = to_hex (Dream.random bytes)

(* ------------------------------------------------------------------ *)
(* Credentials                                                         *)
(* ------------------------------------------------------------------ *)

type credentials = {
  username : string;
  salt : string;  (** raw bytes *)
  iterations : int;
  password_hash : string;  (** raw bytes *)
}

let hash_password ?(iterations = default_iterations) ?salt ~username password =
  let salt = match salt with Some s -> s | None -> Dream.random 16 in
  {
    username;
    salt;
    iterations;
    password_hash = pbkdf2 ~password ~salt ~iterations ~length:key_length;
  }

(** Verify a login attempt. The user name comparison is case-insensitive, like
    Sonarr/Radarr's. *)
let verify_password (c : credentials) ~username ~password =
  let candidate = pbkdf2 ~password ~salt:c.salt ~iterations:c.iterations ~length:key_length in
  String.lowercase_ascii c.username = String.lowercase_ascii (String.trim username)
  && equal_constant_time c.password_hash candidate

(* ------------------------------------------------------------------ *)
(* Persisted state                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  path : string;
  mutable credentials : credentials option;
  mutable from_env : bool;
      (** Credentials came from the environment and must not be overwritten. *)
  mutable api_key : string;
  mutable auth_required : bool;
  secret : string;  (** Dream cookie/CSRF secret, kept across restarts. *)
  mutex : Lwt_mutex.t;
}

let json_field j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None
let json_string j k = match json_field j k with Some (`String s) -> Some s | _ -> None
let json_bool j k = match json_field j k with Some (`Bool b) -> Some b | _ -> None

let json_int j k =
  match json_field j k with
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None

let to_yojson (t : t) : Yojson.Safe.t =
  let credential_fields =
    match (t.from_env, t.credentials) with
    | true, _ | _, None -> [ ("username", `String ""); ("password_hash", `String ""); ("salt", `String "") ]
    | false, Some c ->
        [
          ("username", `String c.username);
          ("password_hash", `String (to_hex c.password_hash));
          ("salt", `String (to_hex c.salt));
          ("iterations", `Int c.iterations);
          ("algorithm", `String algorithm);
        ]
  in
  `Assoc
    (credential_fields
    @ [
        ("api_key", `String t.api_key);
        ("auth_required", `Bool t.auth_required);
        ("secret", `String t.secret);
      ])

let credentials_of_yojson (j : Yojson.Safe.t) : credentials option =
  match (json_string j "username", json_string j "password_hash", json_string j "salt") with
  | Some username, Some hash, Some salt
    when username <> "" && hash <> "" && salt <> "" -> (
      match (of_hex salt, of_hex hash) with
      | Some salt, Some password_hash ->
          Some
            {
              username;
              salt;
              iterations = Option.value (json_int j "iterations") ~default:default_iterations;
              password_hash;
            }
      | _ -> None)
  | _ -> None

let bool_of_env_string s =
  match String.lowercase_ascii (String.trim s) with
  | "1" | "true" | "yes" | "on" | "enabled" -> Some true
  | "0" | "false" | "no" | "off" | "disabled" -> Some false
  | _ -> None

(** Load (or initialise) the auth state for a data directory. An API key and a
    cookie secret are generated and persisted on first start. *)
let create ?(getenv = Sys.getenv_opt) ~data_dir () =
  let path = Filename.concat data_dir "auth.json" in
  let env name =
    match getenv ("PICKARR_" ^ name) with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  let* stored =
    if not (Sys.file_exists path) then Lwt.return (Ok `Null)
    else
      let* contents = Store.read_file path in
      match contents with
      | Error e -> Lwt.return (Error (Printf.sprintf "cannot read %s: %s" path e))
      | Ok "" -> Lwt.return (Ok `Null)
      | Ok body -> (
          match Yojson.Safe.from_string body with
          | exception Yojson.Json_error e ->
              Lwt.return (Error (Printf.sprintf "%s is not valid JSON: %s" path e))
          | json -> Lwt.return (Ok json))
  in
  match stored with
  | Error e -> Lwt.return (Error e)
  | Ok stored ->
      let env_credentials =
        match env "PASSWORD" with
        | Some password ->
            Some (hash_password ~username:(Option.value (env "USERNAME") ~default:"admin") password)
        | None -> None
      in
      let credentials =
        match env_credentials with Some c -> Some c | None -> credentials_of_yojson stored
      in
      let api_key =
        match env "API_KEY" with
        | Some k -> k
        | None -> (
            match json_string stored "api_key" with
            | Some k when String.length k >= 16 -> k
            | _ -> random_hex 16)
      in
      let auth_required =
        match Option.bind (env "AUTH_REQUIRED") bool_of_env_string with
        | Some b -> b
        | None -> Option.value (json_bool stored "auth_required") ~default:true
      in
      let secret =
        match json_string stored "secret" with
        | Some s when String.length s >= 32 -> s
        | _ -> random_hex 32
      in
      let t =
        {
          path;
          credentials;
          from_env = env_credentials <> None;
          api_key;
          auth_required;
          secret;
          mutex = Lwt_mutex.create ();
        }
      in
      (* Persist so the API key and cookie secret are stable across restarts. *)
      let* saved =
        Store.write_file_atomic t.path (Yojson.Safe.pretty_to_string (to_yojson t) ^ "\n")
      in
      (match saved with
      | Ok () -> Lwt.return (Ok t)
      | Error e -> Lwt.return (Error (Printf.sprintf "cannot write %s: %s" path e)))

let username t = match t.credentials with None -> "" | Some c -> c.username
let is_configured t = t.credentials <> None
let credentials_from_env t = t.from_env
let api_key t = t.api_key
let auth_required t = t.auth_required
let secret t = t.secret

let persist t = Store.write_file_atomic t.path (Yojson.Safe.pretty_to_string (to_yojson t) ^ "\n")

let save_change t change =
  Lwt_mutex.with_lock t.mutex (fun () ->
      let undo = change () in
      let* saved = persist t in
      match saved with
      | Ok () -> Lwt.return (Ok ())
      | Error e ->
          undo ();
          Lwt.return (Error (Printf.sprintf "could not save %s: %s" t.path e)))

let validate_password password =
  if String.length password < 8 then Error "the password must be at least 8 characters"
  else Ok ()

let validate_username username =
  if String.trim username = "" then Error "a user name is required" else Ok ()

(** Create the administrator account (first-run setup) or replace the stored
    credentials. Refuses when the credentials come from the environment. *)
let set_credentials t ~username ~password =
  if t.from_env then
    Lwt.return
      (Error "credentials come from PICKARR_USERNAME/PICKARR_PASSWORD and cannot be changed here")
  else
    match (validate_username username, validate_password password) with
    | Error e, _ | _, Error e -> Lwt.return (Error e)
    | Ok (), Ok () ->
        let previous = t.credentials in
        save_change t (fun () ->
            t.credentials <- Some (hash_password ~username:(String.trim username) password);
            fun () -> t.credentials <- previous)

let set_auth_required t value =
  let previous = t.auth_required in
  save_change t (fun () ->
      t.auth_required <- value;
      fun () -> t.auth_required <- previous)

(** Replace the API key with a fresh random one and return it. *)
let regenerate_api_key t =
  let previous = t.api_key in
  let* saved =
    save_change t (fun () ->
        t.api_key <- random_hex 16;
        fun () -> t.api_key <- previous)
  in
  match saved with Ok () -> Lwt.return (Ok t.api_key) | Error e -> Lwt.return (Error e)

(** Check a login attempt. *)
let check_login t ~username ~password =
  match t.credentials with
  | None -> Error "no account has been created yet"
  | Some c ->
      if verify_password c ~username ~password then Ok (String.trim username)
      else Error "Incorrect username or password"

let api_key_matches t = function
  | Some given -> equal_constant_time t.api_key given
  | None -> false

(* ------------------------------------------------------------------ *)
(* The access decision (pure)                                          *)
(* ------------------------------------------------------------------ *)

(** How the caller will interpret the answer: a browser can be redirected to a
    page, an API client gets a status code. *)
type request_kind = Browser_page | Api_call

type decision =
  | Allow
  | Redirect_login
  | Redirect_setup  (** No account exists yet: send the browser to /setup. *)
  | Unauthorized

(** Paths that are reachable without authentication:
    - /health for container health checks;
    - /login, /logout, /setup for the auth flow itself;
    - /static/* for the stylesheet used by those pages;
    - /api/auth/status so the UI can discover the auth state;
    - POST /api/webhook/:instance_id, because Sonarr/Radarr webhooks cannot
      send headers; they authenticate with ?apikey= in the configured URL and
      are checked separately by the webhook handler. *)
let exempt_path path =
  let prefix p = String.length path >= String.length p && String.sub path 0 (String.length p) = p in
  path = "/health" || path = "/login" || path = "/logout" || path = "/setup"
  || path = "/api/auth/status" || prefix "/static/" || prefix "/api/webhook/"

(** The pure authorisation decision for one request. *)
let decide ~(auth_required : bool) ~(configured : bool) ~(kind : request_kind)
    ~(path : string) ~(session_user : string option) ~(api_key_ok : bool) : decision =
  if exempt_path path then Allow
  else if not auth_required then Allow
  else if api_key_ok then Allow
  else
    match session_user with
    | Some user when String.trim user <> "" -> Allow
    | _ -> (
        match kind with
        | Api_call -> Unauthorized
        | Browser_page -> if configured then Redirect_login else Redirect_setup)

let status_to_yojson ?(authenticated = false) t =
  `Assoc
    [
      ("auth_required", `Bool t.auth_required);
      ("account_configured", `Bool (is_configured t));
      ("credentials_from_env", `Bool t.from_env);
      ("authenticated", `Bool authenticated);
      ("username", `String (username t));
    ]

(** The Security settings shown in the UI (includes the API key, which the
    logged-in user is allowed to see and copy). *)
let settings_to_yojson t =
  `Assoc
    [
      ("username", `String (username t));
      ("api_key", `String t.api_key);
      ("auth_required", `Bool t.auth_required);
      ("account_configured", `Bool (is_configured t));
      ("credentials_from_env", `Bool t.from_env);
    ]
