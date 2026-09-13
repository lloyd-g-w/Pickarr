(* One place where a selection is actually performed, shared by the manual
   HTTP routes and by automatic mode:

     fetch media -> search releases -> pipeline (filter, score, AI) ->
     optionally grab -> append history. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Pipeline = Pickarr_core.Pipeline
module Client = Pickarr_arr.Client
module Llm = Pickarr_llm.Client

type options = {
  grab : bool;  (** Actually tell Sonarr/Radarr to grab the winner. *)
  instruction : string option;
      (** Temporary natural-language instruction for this request only; never
          persisted. *)
  use_ai : bool option;  (** Overrides [config.llm.llm_enabled] when set. *)
}

let default_options = { grab = false; instruction = None; use_ai = None }

type error =
  | Bad_request of string
  | Instance_not_found of string
  | Media_not_found of string
  | Arr_error of string
      (** The *arr instance could not be reached or returned an error. *)

let error_to_string = function
  | Bad_request m -> m
  | Instance_not_found id -> Printf.sprintf "unknown instance \"%s\"" id
  | Media_not_found m -> m
  | Arr_error m -> m

let bool_of_json_value = function
  | `Bool b -> Some b
  | `String s -> (
      match String.lowercase_ascii s with
      | "1" | "true" | "yes" | "on" -> Some true
      | "0" | "false" | "no" | "off" -> Some false
      | _ -> None)
  | `Int 1 -> Some true
  | `Int 0 -> Some false
  | _ -> None

(** Parse the request body of a selection request. Accepts
    [{"grab":bool,"instruction":string,"use_ai":bool}] with every field
    optional, an empty body, and a [?grab=true] query override. Pure, so the
    parsing rules can be unit tested. *)
let options_of_json ?(grab_query : string option) (body : Yojson.Safe.t) :
    (options, string) result =
  let from_query =
    match grab_query with
    | None -> Ok None
    | Some s -> (
        match bool_of_json_value (`String s) with
        | Some b -> Ok (Some b)
        | None -> Error (Printf.sprintf "invalid grab query value \"%s\"" s))
  in
  match from_query with
  | Error e -> Error e
  | Ok query_grab -> (
      let base = { default_options with grab = Option.value query_grab ~default:false } in
      match body with
      | `Null -> Ok base
      | `Assoc fields ->
          let result = ref (Ok base) in
          let set f = match !result with Ok o -> result := Ok (f o) | Error _ -> () in
          let fail e = match !result with Ok _ -> result := Error e | Error _ -> () in
          List.iter
            (fun (key, value) ->
              match (key, value) with
              | "grab", v -> (
                  match bool_of_json_value v with
                  | Some b -> set (fun o -> { o with grab = b })
                  | None -> fail "\"grab\" must be a boolean")
              | "use_ai", `Null -> ()
              | "use_ai", v -> (
                  match bool_of_json_value v with
                  | Some b -> set (fun o -> { o with use_ai = Some b })
                  | None -> fail "\"use_ai\" must be a boolean")
              | "instruction", `Null -> ()
              | "instruction", `String s ->
                  let s = String.trim s in
                  if s <> "" then set (fun o -> { o with instruction = Some s })
              | "instruction", _ -> fail "\"instruction\" must be a string"
              | ("media_id" | "mediaId"), _ -> ()
              | _ -> ())
            fields;
          !result
      | _ -> Error "request body must be a JSON object")

(** The LLM callback handed to the pipeline. Errors are flattened to strings
    so the pipeline can fall back to deterministic scoring. *)
let llm_fn (cfg : Config.t) : Pipeline.llm_fn =
 fun ~system ~user ->
  Lwt.map
    (function
      | Ok json -> Ok json
      | Error e -> Error (Llm.error_to_string e))
    (Llm.chat_json cfg.llm ~system ~user)

(** Run the full pipeline for one media item on one instance.

    [grab_allowed] lets automatic mode veto the grab after seeing the result
    (for example when the LLM confidence is too low). *)
let run ?(grab_allowed = fun (_ : Types.selection_result) -> true) (state : App_state.t)
    (inst : Config.instance) ~(media_id : int) (opts : options) :
    (Types.selection_result, error) result Lwt.t =
  let cfg = App_state.config state in
  let client = App_state.client state inst in
  let ( let* ) = Lwt.bind in
  let* media = Client.fetch_media client media_id in
  match media with
  | Error e ->
      let msg =
        Printf.sprintf "%s: could not load media %d: %s" inst.inst_name media_id
          (Client.error_to_string e)
      in
      Lwt.return
        (Error
           (match e with
           | Pickarr_arr.Http.Http_status (404, _) -> Media_not_found msg
           | Pickarr_arr.Http.Http_status _ | Pickarr_arr.Http.Connection _
           | Pickarr_arr.Http.Json _ ->
               Arr_error msg))
  | Ok media -> (
      let* releases = Client.search_releases client media in
      match releases with
      | Error e ->
          Lwt.return
            (Error
               (Arr_error
                  (Printf.sprintf "%s: release search failed for %s: %s" inst.inst_name
                     (Store.media_label media) (Client.error_to_string e))))
      | Ok releases ->
          Log_buffer.infof "%s: %d candidate release(s) for %s" inst.inst_name
            (List.length releases) (Store.media_label media);
          let* result =
            Pipeline.run ~config:cfg ~instance:(Some inst) ~media ~releases
              ?instruction:opts.instruction ~llm:(llm_fn cfg) ?use_ai:opts.use_ai ()
          in
          let* result =
            match (opts.grab, result.selected) with
            | false, _ | _, None -> Lwt.return result
            | true, Some selected ->
                if not (grab_allowed result) then Lwt.return result
                else
                  let* grabbed = Client.grab client media selected.scored in
                  (match grabbed with
                  | Ok () ->
                      Log_buffer.infof "%s: grabbed %s for %s" inst.inst_name
                        selected.scored.title (Store.media_label media);
                      Lwt.return { result with grabbed = true; grab_error = None }
                  | Error e ->
                      let msg = Client.error_to_string e in
                      Log_buffer.errorf "%s: grab failed for %s: %s" inst.inst_name
                        selected.scored.title msg;
                      Lwt.return { result with grabbed = false; grab_error = Some msg })
          in
          let* () =
            Store.append_history state.store
              (Store.history_entry_of_result ~instance_id:inst.inst_id result)
          in
          Lwt.return (Ok result))

(** Resolve an instance by id and run a selection. *)
let run_on_instance_id (state : App_state.t) ~(instance_id : string) ~(media_id : int)
    (opts : options) =
  match App_state.find_instance state instance_id with
  | None -> Lwt.return (Error (Instance_not_found instance_id))
  | Some inst -> run state inst ~media_id opts

(** Resolve the default instance for an app and run a selection. *)
let run_on_default (state : App_state.t) ~(app : Types.app) ~(media_id : int)
    (opts : options) =
  match App_state.default_instance state app with
  | None -> Lwt.return (Error (Instance_not_found (Types.app_to_string app)))
  | Some inst -> run state inst ~media_id opts
