(** Minimal client for OpenAI-compatible [/chat/completions] endpoints.

    Works against api.openai.com as well as self-hosted servers that
    implement the same shape (llama.cpp server, Ollama's OpenAI endpoint,
    vLLM, LM Studio, OpenRouter, ...).  Only the chat-completions call is
    implemented; Selectarr needs nothing else. *)

type error =
  | Disabled  (** AI selection is off, or no model/base URL configured. *)
  | Connection of string  (** DNS failure, refused connection, TLS error. *)
  | Http_status of int * string
      (** Non-2xx response; the string is the provider's error message when
          it could be decoded, otherwise the raw body (truncated). *)
  | Bad_response of string
      (** 2xx response that did not contain usable content, or content that
          was supposed to be JSON and was not. *)
  | Timeout  (** No response within [llm_timeout_seconds]. *)

val error_to_string : error -> string

val chat_json :
  Selectarr_core.Config.llm ->
  system:string ->
  user:string ->
  (Yojson.Safe.t, error) result Lwt.t
(** [chat_json cfg ~system ~user] performs one chat completion and returns the
    assistant message parsed as JSON.  Markdown fences and surrounding prose
    are tolerated (see {!extract_json}).  Sends
    [response_format: {"type": "json_object"}] when [cfg.llm_json_mode] is
    set, retrying once without it if the server answers 400 (not every
    OpenAI-compatible server implements JSON mode).  Never raises: transport
    and decoding problems become [Error]. *)

val chat_text :
  Selectarr_core.Config.llm ->
  system:string ->
  user:string ->
  (string, error) result Lwt.t
(** Same as {!chat_json} but returns the raw assistant text.  Used by the
    "test LLM connection" action.  [response_format] is never sent. *)

(** {1 Pure helpers}

    Exposed so they can be unit-tested without a network. *)

val chat_completions_url : string -> string
(** Join a configured base URL with the [chat/completions] path.  Accepts
    ["http://host:8080/v1"], ["http://host:8080/v1/"] and
    ["http://host:8080"] (in which case ["/v1"] is added, since every
    OpenAI-compatible server mounts the API under a version prefix). *)

val build_request_body :
  Selectarr_core.Config.llm -> system:string -> user:string -> json_mode:bool -> Yojson.Safe.t
(** The [/chat/completions] request body. *)

val extract_json : string -> (Yojson.Safe.t, string) result
(** Recover a JSON object from model output: strips ```/```json fences and,
    if the text still is not valid JSON, extracts the outermost balanced
    [{...}] (ignoring braces inside strings). *)

val parse_completion : Yojson.Safe.t -> (string, string) result
(** Extract [choices[0].message.content] from a chat-completion response.
    Falls back to [choices[0].text] for legacy completion servers, and
    reports an error when [finish_reason] is ["length"] because a truncated
    answer can never be valid JSON. *)

val parse_error_body : int -> string -> error
(** Turn a non-2xx body into an {!error}, decoding the OpenAI
    [{"error": {"message": ...}}] shape when present. *)
