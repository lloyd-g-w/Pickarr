(* What the currently running queue job is, for code that runs inside it.

   Selections, grabs and passes are deep call chains (Selection -> Grab ->
   Client); threading a job handle through every signature would touch every
   caller, including the pure helpers the tests use.  Instead the job runner
   (lib/server/job_kinds.ml) installs a context with [with_ctx], and Lwt's
   implicit callback arguments carry it into every promise the runner
   creates.  Outside a job (unit tests, startup) every function here is a
   no-op apart from [event], which still emits an untagged event. *)

type ctx = {
  job_id : int;
  instance_id : string option;
  progress : string -> unit;  (** The job's progress line. *)
  set_title : string -> unit;
      (** Refine the job's label once the media title is known. *)
  mutable prefix : string;
      (** Prepended to every progress message, e.g. "item 2/5: Film (2001) — ". *)
  mutable titled : bool;  (** The first title wins: a series beats its seasons. *)
}

let key : ctx Lwt.key = Lwt.new_key ()
let current () = Lwt.get key

(** Run [f] with [c] as the current job context. *)
let with_ctx (c : ctx) (f : unit -> 'a Lwt.t) : 'a Lwt.t = Lwt.with_value key (Some c) f

let job_id () = Option.map (fun c -> c.job_id) (current ())

let progress (message : string) =
  match current () with None -> () | Some c -> c.progress (c.prefix ^ message)

let set_prefix (prefix : string) =
  match current () with None -> () | Some c -> c.prefix <- prefix

(** The current prefix, so a nested step can extend it and restore it. *)
let get_prefix () = match current () with None -> "" | Some c -> c.prefix

(** Give the job a human title (the media label).  Only the first call per job
    has an effect, so the outermost caller (a whole series, a Seerr request)
    names the job rather than whatever it runs inside. *)
let set_title (title : string) =
  match current () with
  | Some c when not c.titled ->
      c.titled <- true;
      c.set_title title
  | _ -> ()

(** Emit a structured event, tagged with the current job and its instance
    unless [instance_id] is given. *)
let event ?level ?instance_id ?media ?data (event_type : string) (message : string) : unit
    =
  let c = current () in
  let instance_id =
    match instance_id with
    | Some _ -> instance_id
    | None -> Option.bind c (fun c -> c.instance_id)
  in
  Events.emit ?level ?job_id:(Option.map (fun c -> c.job_id) c) ?instance_id ?media ?data
    event_type message
