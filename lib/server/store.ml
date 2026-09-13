(* Persistence for Pickarr: the JSON configuration file and the selection
   history log.

   Layout inside [DATA_DIR]:
     config.json    the full [Pickarr_core.Config.t]
     history.jsonl  one JSON object per selection, newest last

   Writes are atomic (temp file + rename) and serialised through an
   [Lwt_mutex]. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types

type t = {
  data_dir : string;
  config_path : string;
  history_path : string;
  mutable current : Config.t;
  mutex : Lwt_mutex.t;
}

(* ------------------------------------------------------------------ *)
(* Paths                                                               *)
(* ------------------------------------------------------------------ *)

let is_writable_dir path =
  match Sys.is_directory path with
  | true -> ( try Unix.access path [ Unix.W_OK ]; true with Unix.Unix_error _ -> false)
  | false -> false
  | exception Sys_error _ -> false

(** Pick the data directory: [DATA_DIR] when set, else "/data" when it exists
    and is writable, else "./data". The directory is not created here. *)
let resolve_data_dir ?(getenv = Sys.getenv_opt) () =
  match getenv "DATA_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> if is_writable_dir "/data" then "/data" else "./data"

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then Ok ()
  else if Sys.file_exists path then
    if (try Sys.is_directory path with Sys_error _ -> false) then Ok ()
    else Error (Printf.sprintf "%s exists but is not a directory" path)
  else
    match mkdir_p (Filename.dirname path) with
    | Error _ as e -> e
    | Ok () -> (
        try
          Unix.mkdir path 0o755;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
        | Unix.Unix_error (err, _, _) ->
            Error
              (Printf.sprintf "cannot create %s: %s" path (Unix.error_message err)))

(* ------------------------------------------------------------------ *)
(* Low level file helpers                                              *)
(* ------------------------------------------------------------------ *)

let read_file path =
  Lwt.catch
    (fun () ->
      Lwt_io.with_file ~mode:Lwt_io.Input path (fun ic ->
          Lwt.bind (Lwt_io.read ic) (fun s -> Lwt.return (Ok s))))
    (fun exn -> Lwt.return (Error (Printexc.to_string exn)))

(** Write [contents] to [path] atomically: a sibling temp file is written,
    flushed and renamed over the target. *)
let write_file_atomic path contents =
  let tmp = path ^ ".tmp" in
  Lwt.catch
    (fun () ->
      Lwt.bind
        (Lwt_io.with_file ~mode:Lwt_io.Output
           ~flags:[ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] ~perm:0o644 tmp
           (fun oc -> Lwt.bind (Lwt_io.write oc contents) (fun () -> Lwt_io.flush oc)))
        (fun () -> Lwt.bind (Lwt_unix.rename tmp path) (fun () -> Lwt.return (Ok ()))))
    (fun exn -> Lwt.return (Error (Printexc.to_string exn)))

let append_file path line =
  Lwt.catch
    (fun () ->
      Lwt_io.with_file ~mode:Lwt_io.Output
        ~flags:[ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] ~perm:0o644 path
        (fun oc ->
          Lwt.bind (Lwt_io.write oc (line ^ "\n")) (fun () -> Lwt_io.flush oc)))
    (fun exn ->
      ignore exn;
      Lwt.return_unit)

(* ------------------------------------------------------------------ *)
(* History                                                             *)
(* ------------------------------------------------------------------ *)

type history_entry = {
  h_timestamp : string;
  h_instance_id : string;
  h_app : string;
  h_media_id : int;
  h_media_label : string;
  h_media_kind : string;
  h_selected_title : string option;
  h_selected_size_gib : float option;
  h_selected_score : float option;
  h_method : string;
  h_confidence : float option;
  h_reason : string;
  h_explanation : string list;
  h_conflicts : string list;
  h_candidate_count : int;
  h_rejected_count : int;
  h_grabbed : bool;
  h_grab_error : string option;
  h_duration_ms : int;
}

let now_rfc3339 () = Ptime.to_rfc3339 ~tz_offset_s:0 (Ptime_clock.now ())

let media_label (m : Types.media) =
  let base =
    match m.year with
    | Some y -> Printf.sprintf "%s (%d)" m.title y
    | None -> m.title
  in
  match (m.season_number, m.episode_number) with
  | Some s, Some e ->
      let ep = match m.episode_title with Some t -> " - " ^ t | None -> "" in
      Printf.sprintf "%s S%02dE%02d%s" base s e ep
  | _ -> base

let method_to_string = function
  | Types.By_llm -> "llm"
  | Types.By_deterministic -> "deterministic"
  | Types.By_deterministic_fallback _ -> "deterministic_fallback"

(** Summarise a finished selection for the history log. *)
let history_entry_of_result ~instance_id (r : Types.selection_result) =
  {
    h_timestamp = now_rfc3339 ();
    h_instance_id = instance_id;
    h_app = Types.app_to_string r.media.app;
    h_media_id = r.media.media_id;
    h_media_label = media_label r.media;
    h_media_kind = r.media.media_kind;
    h_selected_title = Option.map (fun (s : Types.scored_release) -> s.scored.title) r.selected;
    h_selected_size_gib =
      Option.map
        (fun (s : Types.scored_release) ->
          Float.round (Types.gib_of_bytes s.scored.size_bytes *. 100.) /. 100.)
        r.selected;
    h_selected_score = Option.map (fun (s : Types.scored_release) -> s.score) r.selected;
    h_method = method_to_string r.method_;
    h_confidence = Option.map (fun (d : Types.llm_decision) -> d.confidence) r.llm;
    h_reason = r.reason;
    h_explanation = r.explanation;
    h_conflicts = r.conflicts;
    h_candidate_count = List.length r.candidates;
    h_rejected_count = List.length r.rejected;
    h_grabbed = r.grabbed;
    h_grab_error = r.grab_error;
    h_duration_ms = r.duration_ms;
  }

let history_entry_to_yojson (e : history_entry) : Yojson.Safe.t =
  let opt_str = function None -> `Null | Some s -> `String s in
  let opt_float = function None -> `Null | Some f -> `Float f in
  `Assoc
    [
      ("timestamp", `String e.h_timestamp);
      ("instance_id", `String e.h_instance_id);
      ("app", `String e.h_app);
      ("media_id", `Int e.h_media_id);
      ("media_label", `String e.h_media_label);
      ("media_kind", `String e.h_media_kind);
      ("selected_title", opt_str e.h_selected_title);
      ("selected_size_gib", opt_float e.h_selected_size_gib);
      ("selected_score", opt_float e.h_selected_score);
      ("method", `String e.h_method);
      ("confidence", opt_float e.h_confidence);
      ("reason", `String e.h_reason);
      ("explanation", `List (List.map (fun s -> `String s) e.h_explanation));
      ("conflicts", `List (List.map (fun s -> `String s) e.h_conflicts));
      ("candidate_count", `Int e.h_candidate_count);
      ("rejected_count", `Int e.h_rejected_count);
      ("grabbed", `Bool e.h_grabbed);
      ("grab_error", opt_str e.h_grab_error);
      ("duration_ms", `Int e.h_duration_ms);
    ]

let history_entry_of_yojson (j : Yojson.Safe.t) : (history_entry, string) result =
  let str k d = match Config.member_opt k j with Some (`String s) -> s | _ -> d in
  let int k d =
    match Config.member_opt k j with
    | Some (`Int i) -> i
    | Some (`Float f) -> int_of_float f
    | _ -> d
  in
  let bool k d = match Config.member_opt k j with Some (`Bool b) -> b | _ -> d in
  let str_opt k =
    match Config.member_opt k j with Some (`String s) -> Some s | _ -> None
  in
  let float_opt k =
    match Config.member_opt k j with
    | Some (`Float f) -> Some f
    | Some (`Int i) -> Some (float_of_int i)
    | _ -> None
  in
  let strs k =
    match Config.member_opt k j with
    | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  match j with
  | `Assoc _ ->
      Ok
        {
          h_timestamp = str "timestamp" "";
          h_instance_id = str "instance_id" "";
          h_app = str "app" "";
          h_media_id = int "media_id" 0;
          h_media_label = str "media_label" "";
          h_media_kind = str "media_kind" "";
          h_selected_title = str_opt "selected_title";
          h_selected_size_gib = float_opt "selected_size_gib";
          h_selected_score = float_opt "selected_score";
          h_method = str "method" "";
          h_confidence = float_opt "confidence";
          h_reason = str "reason" "";
          h_explanation = strs "explanation";
          h_conflicts = strs "conflicts";
          h_candidate_count = int "candidate_count" 0;
          h_rejected_count = int "rejected_count" 0;
          h_grabbed = bool "grabbed" false;
          h_grab_error = str_opt "grab_error";
          h_duration_ms = int "duration_ms" 0;
        }
  | _ -> Error "history entry must be a JSON object"

(* ------------------------------------------------------------------ *)
(* Store                                                               *)
(* ------------------------------------------------------------------ *)

(** Load the store. Reads [config.json] when present, then applies
    environment overrides. Returns [Error] when the data directory cannot be
    created or written to, or when an existing config file is unparseable. *)
let create ?data_dir ?(getenv = Sys.getenv_opt) () =
  let dir = match data_dir with Some d -> d | None -> resolve_data_dir ~getenv () in
  match mkdir_p dir with
  | Error e -> Lwt.return (Error e)
  | Ok () ->
      if not (is_writable_dir dir) then
        Lwt.return
          (Error (Printf.sprintf "data directory %s is not writable" dir))
      else
        let config_path = Filename.concat dir "config.json" in
        let history_path = Filename.concat dir "history.jsonl" in
        let finish stored =
          let current = Config.apply_env ~getenv stored in
          let t =
            {
              data_dir = dir;
              config_path;
              history_path;
              current;
              mutex = Lwt_mutex.create ();
            }
          in
          Lwt.return (Ok t)
        in
        if Sys.file_exists config_path then
          Lwt.bind (read_file config_path) (function
            | Error e ->
                Lwt.return (Error (Printf.sprintf "cannot read %s: %s" config_path e))
            | Ok "" -> finish Config.default
            | Ok body -> (
                match Yojson.Safe.from_string body with
                | exception Yojson.Json_error e ->
                    Lwt.return
                      (Error (Printf.sprintf "%s is not valid JSON: %s" config_path e))
                | json -> (
                    match Config.of_yojson json with
                    | Error e ->
                        Lwt.return
                          (Error (Printf.sprintf "%s is invalid: %s" config_path e))
                    | Ok c -> finish c)))
        else finish Config.default

let data_dir t = t.data_dir
let config_path t = t.config_path
let history_path t = t.history_path

(** The current in-memory configuration. *)
let config t = t.current

let persist t =
  write_file_atomic t.config_path
    (Yojson.Safe.pretty_to_string (Config.to_yojson t.current) ^ "\n")

(** Write the current configuration to disk. *)
let save t = Lwt_mutex.with_lock t.mutex (fun () -> persist t)

(** Apply [f] to the current configuration under the store lock and persist
    the result. [f] may reject the change with [Error]. On a persistence
    failure the in-memory value is rolled back. *)
let update t f =
  Lwt_mutex.with_lock t.mutex (fun () ->
      match f t.current with
      | Error e -> Lwt.return (Error e)
      | Ok updated ->
          let previous = t.current in
          t.current <- updated;
          Lwt.bind (persist t) (function
            | Ok () -> Lwt.return (Ok updated)
            | Error e ->
                t.current <- previous;
                Lwt.return (Error (Printf.sprintf "could not persist config: %s" e))))

(** Append one entry to history.jsonl. Failures are ignored: history is
    diagnostic and must never break a selection. *)
let append_history t entry =
  append_file t.history_path
    (Yojson.Safe.to_string (history_entry_to_yojson entry))

(** Read at most [limit] history entries, newest first. Unparseable lines are
    skipped. *)
let read_history t ~limit =
  if not (Sys.file_exists t.history_path) then Lwt.return []
  else
    Lwt.bind (read_file t.history_path) (function
      | Error _ -> Lwt.return []
      | Ok body ->
          let lines =
            String.split_on_char '\n' body
            |> List.filter (fun l -> String.trim l <> "")
          in
          let entries =
            List.rev lines
            |> List.filteri (fun i _ -> i < limit)
            |> List.filter_map (fun line ->
                   match Yojson.Safe.from_string line with
                   | exception Yojson.Json_error _ -> None
                   | json -> Result.to_option (history_entry_of_yojson json))
          in
          Lwt.return entries)
