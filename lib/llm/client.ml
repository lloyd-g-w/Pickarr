(* OpenAI-compatible chat-completions client.  See client.mli. *)

module C = Pickarr_core.Config

type error =
  | Disabled
  | Connection of string
  | Http_status of int * string
  | Bad_response of string
  | Timeout

let error_to_string = function
  | Disabled -> "LLM is disabled or not configured"
  | Connection m -> "connection error: " ^ m
  | Http_status (code, m) -> Printf.sprintf "HTTP %d: %s" code m
  | Bad_response m -> "invalid response: " ^ m
  | Timeout -> "request timed out"

(* ------------------------------------------------------------------ *)
(* URL handling                                                        *)
(* ------------------------------------------------------------------ *)

let rec strip_trailing_slashes s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '/' then strip_trailing_slashes (String.sub s 0 (n - 1)) else s

let ends_with_version base =
  (* "/v1", "/v1beta", "/openai/v1", "/api/v3" ... *)
  match String.rindex_opt base '/' with
  | None -> false
  | Some i ->
      let last = String.sub base (i + 1) (String.length base - i - 1) in
      String.length last >= 2
      && (last.[0] = 'v' || last.[0] = 'V')
      && last.[1] >= '0'
      && last.[1] <= '9'

let chat_completions_url base_url =
  let base = strip_trailing_slashes (String.trim base_url) in
  if base = "" then ""
  else if ends_with_version base then base ^ "/chat/completions"
  else base ^ "/v1/chat/completions"

(* ------------------------------------------------------------------ *)
(* Request / response payloads                                         *)
(* ------------------------------------------------------------------ *)

let build_request_body (cfg : C.llm) ~system ~user ~json_mode : Yojson.Safe.t =
  let messages =
    `List
      [
        `Assoc [ ("role", `String "system"); ("content", `String system) ];
        `Assoc [ ("role", `String "user"); ("content", `String user) ];
      ]
  in
  let base =
    [
      ("model", `String cfg.C.llm_model);
      ("messages", messages);
      ("temperature", `Float cfg.C.llm_temperature);
      ("max_tokens", `Int cfg.C.llm_max_tokens);
      ("stream", `Bool false);
    ]
  in
  let fields =
    if json_mode then
      base @ [ ("response_format", `Assoc [ ("type", `String "json_object") ]) ]
    else base
  in
  `Assoc fields

let member key = function
  | `Assoc l -> ( match List.assoc_opt key l with Some `Null -> None | v -> v)
  | _ -> None

let string_member key j = match member key j with Some (`String s) -> Some s | _ -> None

let parse_completion (json : Yojson.Safe.t) : (string, string) result =
  match member "choices" json with
  | Some (`List (choice :: _)) when string_member "finish_reason" choice = Some "length" ->
      (* A truncated answer can never be valid JSON; fail loudly so the
         caller falls back to deterministic scoring instead of reporting a
         confusing parse error. *)
      Error "model output was cut off (finish_reason=length); raise max_tokens"
  | Some (`List (choice :: _)) -> (
      let from_message =
        match member "message" choice with
        | Some msg -> string_member "content" msg
        | None -> None
      in
      match from_message with
      | Some content -> Ok content
      | None -> (
          (* Legacy /completions-style servers, and reasoning models that put
             the answer in a differently named field. *)
          match string_member "text" choice with
          | Some t -> Ok t
          | None -> Error "choices[0] contained no message.content"))
  | Some (`List []) -> Error "response contained no choices"
  | _ -> Error "response contained no choices array"

let truncate n s =
  if String.length s <= n then s else String.sub s 0 n ^ "... (truncated)"

let parse_error_body code body =
  let message =
    match Yojson.Safe.from_string body with
    | json -> (
        match member "error" json with
        | Some (`String s) -> Some s
        | Some err -> (
            match string_member "message" err with
            | Some m -> (
                match string_member "code" err with
                | Some c -> Some (m ^ " (" ^ c ^ ")")
                | None -> Some m)
            | None -> None)
        | None -> string_member "message" json)
    | exception _ -> None
  in
  match message with
  | Some m -> Http_status (code, m)
  | None -> Http_status (code, truncate 500 (String.trim body))

(* ------------------------------------------------------------------ *)
(* Lenient JSON extraction                                             *)
(* ------------------------------------------------------------------ *)

let strip_fences text =
  let t = String.trim text in
  if String.length t >= 6 && String.sub t 0 3 = "```" then
    (* Drop the opening fence (with its optional language tag) and the
       closing fence if present. *)
    let after_open =
      match String.index_opt t '\n' with
      | Some i -> String.sub t (i + 1) (String.length t - i - 1)
      | None -> ""
    in
    let body =
      let n = String.length after_open in
      let rec find_close i =
        if i < 0 then None
        else if i + 3 <= n && String.sub after_open i 3 = "```" then Some i
        else find_close (i - 1)
      in
      match find_close (n - 3) with
      | Some i -> String.sub after_open 0 i
      | None -> after_open
    in
    String.trim body
  else t

(* Outermost balanced {...}, ignoring braces that occur inside strings. *)
let outermost_object text =
  let n = String.length text in
  match String.index_opt text '{' with
  | None -> None
  | Some start ->
      let rec go i depth in_string escaped =
        if i >= n then None
        else
          let c = text.[i] in
          if in_string then
            if escaped then go (i + 1) depth true false
            else if c = '\\' then go (i + 1) depth true true
            else if c = '"' then go (i + 1) depth false false
            else go (i + 1) depth true false
          else
            match c with
            | '"' -> go (i + 1) depth true false
            | '{' -> go (i + 1) (depth + 1) false false
            | '}' ->
                if depth = 1 then Some (String.sub text start (i - start + 1))
                else go (i + 1) (depth - 1) false false
            | _ -> go (i + 1) depth false false
      in
      go start 0 false false

let extract_json text =
  let candidate = strip_fences text in
  match Yojson.Safe.from_string candidate with
  | json -> Ok json
  | exception _ -> (
      match outermost_object candidate with
      | None -> Error ("model output was not JSON: " ^ truncate 300 (String.trim text))
      | Some obj -> (
          match Yojson.Safe.from_string obj with
          | json -> Ok json
          | exception Yojson.Json_error m -> Error ("model output was not JSON: " ^ m)
          | exception _ -> Error "model output was not JSON"))

(* ------------------------------------------------------------------ *)
(* Transport                                                           *)
(* ------------------------------------------------------------------ *)

let configured (cfg : C.llm) =
  String.trim cfg.C.llm_base_url <> "" && String.trim cfg.C.llm_model <> ""

let headers (cfg : C.llm) =
  let base =
    [ ("content-type", "application/json"); ("accept", "application/json") ]
  in
  let key = String.trim cfg.C.llm_api_key in
  let base =
    if key = "" then base
    else
      (* Both header spellings are accepted by every OpenAI-compatible
         server we target; api-key covers Azure-style deployments. *)
      ("authorization", "Bearer " ^ key) :: ("api-key", key) :: base
  in
  Cohttp.Header.of_list base

(* Perform the POST, returning the raw body text on success. *)
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

let post_raw (cfg : C.llm) (body : Yojson.Safe.t) : (string, error) result Lwt.t =
  let url = chat_completions_url cfg.C.llm_base_url in
  let uri = Uri.of_string url in
  let payload = Cohttp_lwt.Body.of_string (Yojson.Safe.to_string body) in
  let timeout = float_of_int (max 1 cfg.C.llm_timeout_seconds) in
  let request =
    Lwt.catch
      (fun () ->
        let open Lwt.Infix in
        Cohttp_lwt_unix.Client.post ~ctx:(Lazy.force ctx) ~headers:(headers cfg) ~body:payload uri
        >>= fun (resp, resp_body) ->
        Cohttp_lwt.Body.to_string resp_body >>= fun text ->
        let code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
        if code >= 200 && code < 300 then Lwt.return (Ok text)
        else Lwt.return (Error (parse_error_body code text)))
      (fun exn ->
        let msg =
          match exn with
          | Unix.Unix_error (e, _, _) -> Unix.error_message e
          | Failure m -> m
          | e -> Printexc.to_string e
        in
        Lwt.return (Error (Connection (msg ^ " (" ^ url ^ ")"))))
  in
  let timer =
    let open Lwt.Infix in
    Lwt_unix.sleep timeout >>= fun () -> Lwt.return (Error Timeout)
  in
  Lwt.pick [ request; timer ]

let complete (cfg : C.llm) ~system ~user ~json_mode : (string, error) result Lwt.t =
  if not (configured cfg) then Lwt.return (Error Disabled)
  else
    let open Lwt.Infix in
    post_raw cfg (build_request_body cfg ~system ~user ~json_mode) >>= function
    | Error e -> Lwt.return (Error e)
    | Ok raw -> (
        match Yojson.Safe.from_string raw with
        | exception Yojson.Json_error m ->
            Lwt.return (Error (Bad_response ("response body was not JSON: " ^ m)))
        | exception _ -> Lwt.return (Error (Bad_response "response body was not JSON"))
        | json -> (
            match parse_completion json with
            | Error m -> Lwt.return (Error (Bad_response m))
            | Ok content -> Lwt.return (Ok content)))

let chat_text cfg ~system ~user = complete cfg ~system ~user ~json_mode:false

(* Servers that do not implement response_format answer 400.  Retry once
   without it rather than losing AI selection entirely; the system prompt
   already demands JSON and the response is parsed leniently. *)
let complete_with_json_mode_fallback (cfg : C.llm) ~system ~user =
  let open Lwt.Infix in
  if not cfg.C.llm_json_mode then complete cfg ~system ~user ~json_mode:false
  else
    complete cfg ~system ~user ~json_mode:true >>= function
    | Error (Http_status (400, _)) -> complete cfg ~system ~user ~json_mode:false
    | other -> Lwt.return other


let chat_json (cfg : C.llm) ~system ~user =
  let open Lwt.Infix in
  complete_with_json_mode_fallback cfg ~system ~user >>= function
  | Error e -> Lwt.return (Error e)
  | Ok content -> (
      match extract_json content with
      | Ok json -> Lwt.return (Ok json)
      | Error m -> Lwt.return (Error (Bad_response m)))
