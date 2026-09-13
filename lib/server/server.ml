(* Process entry point: load configuration, build state, start the automatic
   scheduler and serve the HTTP API and UI. *)

module Config = Pickarr_core.Config

let default_port = 8484
let default_host = "0.0.0.0"

let log_level_of_string = function
  | "debug" -> `Debug
  | "info" -> `Info
  | "warning" | "warn" -> `Warning
  | "error" -> `Error
  | _ -> `Info

let env_port ?(getenv = Sys.getenv_opt) () =
  match getenv "PORT" with
  | Some p -> ( match int_of_string_opt (String.trim p) with Some p -> p | None -> default_port)
  | None -> default_port

let env_host ?(getenv = Sys.getenv_opt) () =
  match getenv "HOST" with
  | Some h when String.trim h <> "" -> String.trim h
  | _ -> default_host

(** Build the application state, or return a human readable reason why the
    service cannot start (almost always an unwritable DATA_DIR). *)
let init ?getenv () =
  let getenv = Option.value getenv ~default:Sys.getenv_opt in
  Lwt.bind (Store.create ~getenv ()) (function
    | Error e -> Lwt.return (Error e)
    | Ok store ->
        Lwt.bind (Auth.create ~getenv ~data_dir:(Store.data_dir store) ()) (function
          | Error e -> Lwt.return (Error e)
          | Ok auth -> Lwt.return (Ok (App_state.create ~getenv store auth))))

let describe (state : App_state.t) =
  let cfg = App_state.config state in
  Log_buffer.infof "Pickarr %s starting (data dir %s)" App_state.version
    (Store.data_dir state.App_state.store);
  List.iter
    (fun (i : Config.instance) ->
      Log_buffer.infof "instance %s: %s %s%s%s" i.inst_id
        (Pickarr_core.Types.app_to_string i.inst_app)
        i.inst_url
        (if i.inst_enabled then "" else " (disabled)")
        (if i.inst_automatic then " [automatic]" else ""))
    cfg.instances;
  if cfg.instances = [] then
    Log_buffer.warnf
      "no Sonarr/Radarr instance configured: set SONARR_URL/SONARR_API_KEY or \
       RADARR_URL/RADARR_API_KEY, or add one in the UI";
  Log_buffer.infof "AI selection %s%s"
    (if cfg.llm.llm_enabled then "enabled" else "disabled")
    (if cfg.llm.llm_enabled then
       Printf.sprintf " (model %s at %s)" cfg.llm.llm_model cfg.llm.llm_base_url
     else "");
  Log_buffer.infof "automatic mode %s%s"
    (if cfg.automatic.auto_enabled then "enabled" else "disabled")
    (if cfg.automatic.auto_enabled && not cfg.automatic.auto_grab then
       " (dry run: grabbing disabled)"
     else "");
  Log_buffer.infof "Seerr integration %s%s"
    (if cfg.seerr.seerr_enabled then "enabled" else "disabled")
    (if cfg.seerr.seerr_enabled then
       Printf.sprintf " (%s, %s approval, %s)" cfg.seerr.seerr_url
         (if cfg.seerr.seerr_auto_approve then "automatic" else "manual")
         (if cfg.seerr.seerr_grab then "grabbing" else "dry run")
     else "");
  let auth = state.App_state.auth in
  (if not (Auth.auth_required auth) then
     Log_buffer.warnf
       "authentication is DISABLED: everyone who can reach this port can change \
        the configuration. Enable it again under Security in the UI"
   else if Auth.is_configured auth then
     Log_buffer.infof "forms authentication is enabled for user %s%s" (Auth.username auth)
       (if Auth.credentials_from_env auth then " (from the environment)" else "")
   else
     Log_buffer.infof
       "no account exists yet: the UI will ask you to create one at /setup");
  match state.App_state.static_dir with
  | Some dir -> Log_buffer.infof "serving UI from %s" dir
  | None ->
      Log_buffer.warnf "no static UI directory found; the API is still available"

(** Run the service. Never returns under normal operation. *)
let main () =
  match Lwt_main.run (init ()) with
  | Error e ->
      prerr_endline ("pickarr: cannot start: " ^ e);
      prerr_endline
        "pickarr: set DATA_DIR to a writable directory (the Docker image uses \
         /data, which must be mounted as a writable volume)";
      exit 1
  | Ok state ->
      let cfg = App_state.config state in
      Dream.initialize_log ~level:(log_level_of_string cfg.log_level) ();
      describe state;
      Automatic.start state;
      Seerr_sync.start state;
      Dream.run ~interface:(env_host ()) ~port:(env_port ()) ~greeting:false
        (Routes.handler state)
