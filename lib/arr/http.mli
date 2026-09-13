(** HTTP transport for the Sonarr/Radarr REST APIs.

    Authentication uses the [X-Api-Key] header, which both applications
    accept on every [/api/v3] endpoint. *)

type error =
  | Connection of string  (** DNS failure, refused connection, timeout. *)
  | Http_status of int * string
      (** Non-2xx status; the string is the *arr error message when the body
          could be decoded, otherwise the truncated raw body. *)
  | Json of string  (** Body was not JSON, or did not decode to what we need. *)

val error_to_string : error -> string

val timeout_seconds : float ref
(** Per-request timeout, 30s by default.  Exposed so the server can lower it
    for connection tests. *)

val get :
  base_url:string ->
  api_key:string ->
  ?query:(string * string) list ->
  string ->
  (Yojson.Safe.t, error) result Lwt.t
(** [get ~base_url ~api_key ~query path] issues [GET base_url ^ path].
    [path] must start with ["/"]. *)

val post :
  base_url:string ->
  api_key:string ->
  string ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, error) result Lwt.t
(** POST a JSON body.  An empty response body decodes as [`Null]. *)

val post_unit :
  base_url:string -> api_key:string -> string -> Yojson.Safe.t -> (unit, error) result Lwt.t
(** POST a JSON body to an action endpoint where the status code alone is the
    outcome (for example [POST /api/v3/release]).  Any 2xx is a success and
    the response body is never parsed, so an empty, plain-text or
    proxy-rewritten body cannot turn a completed action into a reported
    failure. *)

val put :
  base_url:string ->
  api_key:string ->
  string ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, error) result Lwt.t

val join : string -> string -> string
(** [join base path] concatenates a base URL (with or without a trailing
    slash, optionally including a URL base such as ["/sonarr"]) and an
    absolute path.  Pure; exposed for tests. *)

val parse_error_body : int -> string -> error
(** Decode an *arr error body ([{"message": ...}] or a validation-failure
    array) into an {!error}.  Pure; exposed for tests. *)
