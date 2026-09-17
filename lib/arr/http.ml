(* HTTP transport for the Sonarr/Radarr REST APIs.  See http.mli. *)

type error =
  | Connection of string
  | Http_status of int * string
  | Json of string

let error_to_string = function
  | Connection m -> "connection error: " ^ m
  | Http_status (code, m) -> Printf.sprintf "HTTP %d: %s" code m
  | Json m -> "invalid response: " ^ m

let timeout_seconds = ref 30.

(* What a call is, for the timeout message and for choosing which setting to
   name in it.  [`Search] is [GET /api/v3/release] and the whole-library
   listings; everything else is [`Quick]. *)
type kind = [ `Quick | `Search ]

let rec strip_trailing_slashes s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '/' then strip_trailing_slashes (String.sub s 0 (n - 1)) else s

let join base path =
  let base = strip_trailing_slashes (String.trim base) in
  if path = "" then base
  else if String.length path > 0 && path.[0] = '/' then base ^ path
  else base ^ "/" ^ path

let truncate n s =
  let s = String.trim s in
  if String.length s <= n then s else String.sub s 0 n ^ "... (truncated)"

(* Sonarr/Radarr report errors either as {"message": "..."} or as a list of
   validation failures [{"errorMessage": "...", "propertyName": "..."}]. *)
let parse_error_body code body =
  let message =
    match Yojson.Safe.from_string body with
    | exception _ -> None
    | json -> (
        match json with
        | `Assoc _ -> (
            match Jsonutil.string_opt "message" json with
            | Some m -> Some m
            | None -> Jsonutil.string_opt "error" json)
        | `List items ->
            let msgs =
              List.filter_map
                (fun item ->
                  match Jsonutil.string_opt "errorMessage" item with
                  | Some m -> (
                      match Jsonutil.string_opt "propertyName" item with
                      | Some p -> Some (p ^ ": " ^ m)
                      | None -> Some m)
                  | None -> None)
                items
            in
            if msgs = [] then None else Some (String.concat "; " msgs)
        | _ -> None)
  in
  match message with
  | Some m when String.trim m <> "" -> Http_status (code, m)
  | _ -> Http_status (code, truncate 500 body)

let headers api_key =
  Cohttp.Header.of_list
    [
      ("X-Api-Key", api_key);
      ("accept", "application/json");
      ("content-type", "application/json");
    ]

let describe_exn url exn =
  let msg =
    match exn with
    | Unix.Unix_error (e, _, _) -> Unix.error_message e
    | Failure m -> m
    | e -> Printexc.to_string e
  in
  Connection (msg ^ " (" ^ url ^ ")")

(* The timeout message has to say which setting to raise, because "timed out
   after 30s" on a release search reads like a broken connection when it is
   really Sonarr/Radarr still waiting on the indexers. *)
let format_seconds s =
  (* Configured timeouts are whole seconds; tests use fractions. *)
  if Float.is_integer s then Printf.sprintf "%.0f" s else Printf.sprintf "%g" s

let timeout_message ~(kind : kind) ~(seconds : float) ~(url : string) =
  match kind with
  | `Search ->
      Printf.sprintf
        "timed out after %ss waiting for the release search (Sonarr/Radarr search all \
         indexers; raise network.arr_search_timeout_seconds if your indexers are slow) (%s)"
        (format_seconds seconds) url
  | `Quick ->
      Printf.sprintf
        "timed out after %ss (raise network.arr_timeout_seconds if Sonarr/Radarr is slow \
         to respond) (%s)"
        (format_seconds seconds) url

(* Run [f] under the request timeout.  [timeout] defaults to the process-wide
   quick-call timeout. *)
let with_timeout ?timeout ?(kind : kind = `Quick) url (f : unit -> ('a, error) result Lwt.t) =
  let seconds = match timeout with Some t when t > 0. -> t | _ -> !timeout_seconds in
  let timer =
    let open Lwt.Infix in
    Lwt_unix.sleep seconds >>= fun () ->
    Lwt.return (Error (Connection (timeout_message ~kind ~seconds ~url)))
  in
  Lwt.pick [ f (); timer ]

let decode_body ?parse_error url code body =
  if code < 200 || code >= 300 then parse_error_body code body
  else
    Json
      (Printf.sprintf "unexpected body from %s: %s%s" url (truncate 300 body)
         (match parse_error with None -> "" | Some m -> " (" ^ m ^ ")"))

(* Cohttp's default resolver maps the URI scheme to a port with
   getservbyname(3), i.e. /etc/services, which minimal container images do
   not ship; the symptom is "resolution failed: unknown scheme" for every
   request. Use the built-in port table first and only then the system one. *)
let resolver =
  let service name =
    let open Lwt.Infix in
    Resolver_lwt_unix.static_service name >>= function
    | Some s -> Lwt.return (Some s)
    | None -> Resolver_lwt_unix.system_service name
  in
  Resolver_lwt.init ~service ~rewrites:[ ("", Resolver_lwt_unix.system_resolver) ] ()

let ctx = lazy (Cohttp_lwt_unix.Net.init ~resolver ())

(* [ignore_body] controls what a 2xx body means.  Most endpoints need the
   decoded JSON; for action endpoints such as POST /api/v3/release the status
   code alone carries the outcome, and insisting on JSON would turn a
   successful grab into a reported failure on any deployment whose body is
   empty, plain text or rewritten by a proxy. *)
let request ~meth ~url ~api_key ?body ?(ignore_body = false) ?timeout ?kind () :
    (Yojson.Safe.t, error) result Lwt.t =
  let uri = Uri.of_string url in
  with_timeout ?timeout ?kind url (fun () ->
      Lwt.catch
        (fun () ->
          let open Lwt.Infix in
          let body = Option.map (fun j -> Cohttp_lwt.Body.of_string (Yojson.Safe.to_string j)) body in
          Cohttp_lwt_unix.Client.call ~ctx:(Lazy.force ctx) ~headers:(headers api_key) ?body meth uri
          >>= fun (resp, resp_body) ->
          Cohttp_lwt.Body.to_string resp_body >>= fun text ->
          let code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
          if code < 200 || code >= 300 then Lwt.return (Error (parse_error_body code text))
          else if ignore_body then Lwt.return (Ok `Null)
          else if String.trim text = "" then Lwt.return (Ok `Null)
          else
            match Yojson.Safe.from_string text with
            | json -> Lwt.return (Ok json)
            | exception Yojson.Json_error m ->
                Lwt.return (Error (decode_body ~parse_error:m url code text))
            | exception _ -> Lwt.return (Error (Json ("could not parse response from " ^ url))))
        (fun exn -> Lwt.return (Error (describe_exn url exn))))

let get ~base_url ~api_key ?(query = []) ?timeout ?kind path =
  let url = join base_url path in
  let url =
    if query = [] then url
    else
      Uri.to_string
        (Uri.add_query_params' (Uri.of_string url) query)
  in
  request ~meth:`GET ~url ~api_key ?timeout ?kind ()

let post ~base_url ~api_key ?timeout ?kind path body =
  request ~meth:`POST ~url:(join base_url path) ~api_key ~body ?timeout ?kind ()

let post_unit ~base_url ~api_key ?timeout ?kind path body =
  Lwt.map
    (function Ok (_ : Yojson.Safe.t) -> Ok () | Error e -> Error e)
    (request ~meth:`POST ~url:(join base_url path) ~api_key ~body ~ignore_body:true ?timeout
       ?kind ())

let put ~base_url ~api_key ?timeout ?kind path body =
  request ~meth:`PUT ~url:(join base_url path) ~api_key ~body ?timeout ?kind ()
