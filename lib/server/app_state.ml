(* Process-wide mutable state: the config store, cached per-instance *arr
   clients, and the automatic-mode scheduler state.

   Clients are cached per instance id and rebuilt whenever the instance's URL
   or API key changes, so a config update takes effect without a restart. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client

type scheduler = {
  mutex : Lwt_mutex.t;
      (** Held for the duration of a scheduler pass: passes never overlap. *)
  mutable enabled : bool;
  mutable runs : int;
  mutable last_run_at : string option;
  mutable last_run_unix : float option;
  mutable next_run_at : string option;
  mutable last_error : string option;
  mutable last_results : Yojson.Safe.t list;
  attempted : (string * int, float) Hashtbl.t;
      (** (instance id, media id) -> unix time of the last attempt. Used as a
          cooldown so a failing item is not retried every pass. *)
}

type t = {
  store : Store.t;
  auth : Auth.t;
      (** Optional password login and API key. When nothing is configured the
          API is open. *)
  clients : (string, Config.instance * Client.t) Hashtbl.t;
  scheduler : scheduler;
  started_at : float;
  static_dir : string option;
}

let version = "0.1.0"

let resolve_static_dir ?(getenv = Sys.getenv_opt) () =
  let is_dir p = try Sys.is_directory p with Sys_error _ -> false in
  match getenv "STATIC_DIR" with
  | Some d when String.trim d <> "" && is_dir (String.trim d) -> Some (String.trim d)
  | Some d when String.trim d <> "" -> None
  | _ ->
      List.find_opt is_dir [ "/app/static"; "static"; "./static" ]

let create ?(getenv = Sys.getenv_opt) (store : Store.t) (auth : Auth.t) =
  {
    store;
    auth;
    clients = Hashtbl.create 8;
    scheduler =
      {
        mutex = Lwt_mutex.create ();
        enabled = false;
        runs = 0;
        last_run_at = None;
        last_run_unix = None;
        next_run_at = None;
        last_error = None;
        last_results = [];
        attempted = Hashtbl.create 64;
      };
    started_at = Unix.gettimeofday ();
    static_dir = resolve_static_dir ~getenv ();
  }

(** Current configuration. *)
let config t = Store.config t.store

(** The *arr client for [inst], created on first use and rebuilt when the
    connection details change. *)
let client t (inst : Config.instance) =
  match Hashtbl.find_opt t.clients inst.inst_id with
  | Some (cached, c)
    when cached.inst_url = inst.inst_url && cached.inst_api_key = inst.inst_api_key ->
      c
  | _ ->
      let c = Client.create inst in
      Hashtbl.replace t.clients inst.inst_id (inst, c);
      c

(** Drop cached clients for instances that no longer exist. *)
let prune_clients t =
  let live = List.map (fun (i : Config.instance) -> i.inst_id) (config t).instances in
  Hashtbl.iter
    (fun id _ -> if not (List.mem id live) then Hashtbl.remove t.clients id)
    (Hashtbl.copy t.clients)

let find_instance t id = Config.find_instance (config t) id
let default_instance t app = Config.default_instance (config t) app
let uptime_seconds t = Unix.gettimeofday () -. t.started_at

(** Instances that automatic mode should poll. *)
let automatic_instances t =
  List.filter
    (fun (i : Config.instance) -> i.inst_enabled && i.inst_automatic)
    (config t).instances

let status_to_yojson t =
  let c = config t in
  `Assoc
    [
      ("version", `String version);
      ("uptime_seconds", `Float (Float.round (uptime_seconds t)));
      ("data_dir", `String (Store.data_dir t.store));
      ("instances", `Int (List.length c.instances));
      ( "instances_enabled",
        `Int (List.length (List.filter (fun (i : Config.instance) -> i.inst_enabled) c.instances)) );
      ("llm_enabled", `Bool c.llm.llm_enabled);
      ("llm_model", `String c.llm.llm_model);
      ("automatic_enabled", `Bool c.automatic.auto_enabled);
      ("automatic_grab", `Bool c.automatic.auto_grab);
      ("auth_required", `Bool (Auth.auth_required t.auth));
      ("account_configured", `Bool (Auth.is_configured t.auth));
      ("static_dir", match t.static_dir with None -> `Null | Some d -> `String d);
    ]
