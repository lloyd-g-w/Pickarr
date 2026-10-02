(* STUB (queue-integration worktree) — discard at merge. *)

type level = Info | Warn | Error

let level_to_string = function Info -> "info" | Warn -> "warn" | Error -> "error"

let level_of_string = function
  | "info" -> Some Info
  | "warn" | "warning" -> Some Warn
  | "error" -> Some Error
  | _ -> None

let init ~data_dir:_ = Lwt.return_unit

(* When PICKARR_STUB_EVENTS_LOG is set, events are appended there as JSON
   lines so the smoke test can assert on them; otherwise a no-op. *)
let emit ?(level = Info) ?job_id ?instance_id ?media ?(data = []) event_type message =
  match Sys.getenv_opt "PICKARR_STUB_EVENTS_LOG" with
  | None | Some "" -> ()
  | Some path -> (
      let opt_s = function None -> `Null | Some s -> `String s in
      let json =
        `Assoc
          [
            ("level", `String (level_to_string level));
            ("type", `String event_type);
            ("message", `String message);
            ("job_id", match job_id with None -> `Null | Some i -> `Int i);
            ("instance_id", opt_s instance_id);
            ("media", opt_s media);
            ("data", `Assoc data);
          ]
      in
      try
        let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
        output_string oc (Yojson.Safe.to_string json ^ "\n");
        close_out oc
      with _ -> ())

let query ?since_id:_ ?limit:_ ?type_prefix:_ ?min_level:_ ?job_id:_ ?text:_ () = ([], 0)
