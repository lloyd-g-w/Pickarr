(* Grab orchestration.

   A grab is one [POST /api/v3/release], but three things make it fail
   intermittently in practice (see docs/GRAB_BUG_NOTES.md):

   - the release must still be in Sonarr/Radarr's 30-minute release cache,
     keyed on [indexerId_guid], and that cache is only filled by a search;
   - Sonarr/Radarr sometimes cannot map a release (typically a season pack)
     to the series/episodes themselves and demand an explicit override;
   - a 200 only means "accepted"; the download client can still reject it.

   This module wraps those three concerns so every caller (the Search page,
   the per-candidate Grab buttons, automatic mode, the Seerr paths) behaves
   the same and reports the same diagnostics. *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client
module Http = Pickarr_arr.Http
module Mapping = Pickarr_arr.Mapping
module Resources = Pickarr_arr.Resources

let ( let* ) = Lwt.bind

type outcome = {
  grabbed : bool;
  error : string option;
  notes : string list;  (** Which path was taken, and what the queue said. *)
}

(* A guid is long (magnet links run to hundreds of characters); logs and notes
   only need enough to correlate with Sonarr/Radarr's own log line. *)
let short_guid (guid : string option) : string =
  match guid with
  | None -> "(none)"
  | Some g ->
      let g = String.trim g in
      if String.length g <= 48 then g else String.sub g 0 45 ^ "..."

let http_status_and_message (e : Http.error) : (int * string) option =
  match e with Http.Http_status (status, msg) -> Some (status, msg) | _ -> None

(** What a failed attempt means, using only the verified *arr messages. *)
let failure_kind (e : Http.error) : Mapping.grab_failure =
  match http_status_and_message e with
  | Some (status, message) -> Mapping.classify_grab_failure ~status ~message
  | None -> Mapping.Permanent

(* ------------------------------------------------------------------ *)
(* Queue verification                                                  *)
(* ------------------------------------------------------------------ *)

(* Anything in this state means the download client took the release. *)
let is_active_status = function
  | None -> false
  | Some s -> (
      match String.lowercase_ascii s with
      | "queued" | "paused" | "downloading" | "completed" | "delay" | "fallback" -> true
      | _ -> false)

let queue_note_of_details (details : Resources.queue_detail list) : string option =
  match details with
  | [] -> None
  | items ->
      let warned =
        List.filter
          (fun (d : Resources.queue_detail) ->
            let tracked =
              match d.qd_tracked_status with
              | Some s -> String.lowercase_ascii s <> "ok"
              | None -> false
            in
            tracked || d.qd_error_message <> None
            || (not (is_active_status d.qd_status))
               && d.qd_status <> None)
          items
      in
      let describe (d : Resources.queue_detail) =
        let parts =
          List.filter_map
            (fun x -> x)
            [
              d.qd_status;
              (match d.qd_error_message with Some m -> Some m | None -> None);
              (match d.qd_status_messages with [] -> None | l -> Some (String.concat "; " l));
            ]
        in
        String.concat " · " parts
      in
      if warned <> [] then
        Some
          (Printf.sprintf "queue warning: %s"
             (String.concat " | " (List.map describe warned)))
      else
        let client =
          List.find_map (fun (d : Resources.queue_detail) -> d.qd_download_client) items
        in
        Some
          (Printf.sprintf "in the download queue%s"
             (match client with Some c -> " via " ^ c | None -> ""))

(* Sonarr/Radarr add the item to the queue asynchronously after the grab, so
   an immediate check often sees nothing; two short waits cover the normal
   case without making the UI feel stuck. *)
let queue_check_delays = [ 1.0; 3.0 ]

let verify_queue (state : App_state.t) (inst : Config.instance) (media : Types.media) :
    string option Lwt.t =
  let client = App_state.client state inst in
  Activity.progress "checking the download queue\xe2\x80\xa6";
  let rec go = function
    | [] -> Lwt.return (Some "not seen in the download queue yet")
    | delay :: rest ->
        let* () = Lwt_unix.sleep delay in
        let* r = Client.queue_details client media in
        (match r with
        | Error e ->
            (* Never fail a grab because the queue could not be read. *)
            Log_buffer.warnf "%s: could not read the download queue after the grab: %s"
              inst.inst_name (Client.error_to_string e);
            Lwt.return None
        | Ok details -> (
            match queue_note_of_details details with
            | Some note -> Lwt.return (Some note)
            | None -> go rest))
  in
  go queue_check_delays

(* ------------------------------------------------------------------ *)
(* The grab itself                                                     *)
(* ------------------------------------------------------------------ *)

(** [perform state inst media ~release ~research ~episode_ids ()] grabs
    [release] and reports what happened.

    Attempt 1 is the plain grab.  Then, depending on Sonarr/Radarr's answer:

    - 404 "couldn't find requested release in cache": [research ()] is called
      to re-run the search (which refills the cache) and the grab is retried
      once with the refreshed release, because a new search can hand back the
      same guid under a different [indexerId];
    - 404 "will need to be manually provided": retried once with
      [shouldOverride], the ids, and the release's own quality and languages.

    [episode_ids] are the episodes an overridden Sonarr pack should be mapped
    to (empty for a movie or a single episode).

    On success the download queue is polled briefly so that "grabbed" can be
    distinguished from "grabbed but the download client did not take it".
    That check never turns a success into a failure. *)
let perform ?(verify_queue_state = true) (state : App_state.t) (inst : Config.instance)
    (media : Types.media) ~(release : Types.release)
    ~(research : unit -> (Types.release option, string) result Lwt.t)
    ~(episode_ids : int list) () : outcome Lwt.t =
  let client = App_state.client state inst in
  let label = Store.media_label media in
  let describe (r : Types.release) =
    Printf.sprintf "guid %s indexerId %s" (short_guid r.Types.guid)
      (match r.Types.indexer_id with Some i -> string_of_int i | None -> "(none)")
  in
  let release_data (r : Types.release) path =
    [
      ("instance", `String inst.inst_name);
      ("release", `String r.Types.title);
      ("indexer", match r.Types.indexer with Some i -> `String i | None -> `Null);
      ("indexer_id", match r.Types.indexer_id with Some i -> `Int i | None -> `Null);
      ("guid", `String (short_guid r.Types.guid));
      ("path", `String path);
    ]
  in
  let event ?level typ msg data =
    Activity.event ?level ~instance_id:inst.inst_id ~media:label ~data typ msg
  in
  let sent (r : Types.release) path =
    event "grab.sent"
      (Printf.sprintf "%s: sending %s to %s (%s)" inst.inst_name r.Types.title
         (Types.app_to_string inst.inst_app) path)
      (release_data r path)
  in
  let finish ~notes = function
    | Ok () ->
        event "grab.accepted"
          (Printf.sprintf "%s accepted %s for %s" inst.inst_name release.Types.title label)
          (release_data release (String.concat "; " notes));
        let* queue_note =
          if verify_queue_state then verify_queue state inst media else Lwt.return None
        in
        (match queue_note with
        | None -> ()
        | Some note ->
            let warned =
              String.length note >= 13 && String.sub note 0 13 = "queue warning"
            in
            event
              ?level:(if warned then Some Events.Warn else None)
              "grab.queue_check"
              (Printf.sprintf "%s: %s: %s" inst.inst_name release.Types.title note)
              [ ("instance", `String inst.inst_name); ("note", `String note) ]);
        let notes = notes @ Option.to_list queue_note in
        Log_buffer.infof "%s: grabbed %s for %s (%s)" inst.inst_name release.Types.title
          label (String.concat "; " notes);
        Lwt.return { grabbed = true; error = None; notes }
    | Error e ->
        let msg = Client.error_to_string e in
        Log_buffer.errorf "%s: grab failed for %s (%s) for %s: %s" inst.inst_name
          release.Types.title (describe release) label msg;
        let http =
          match http_status_and_message e with
          | Some (status, m) -> [ ("http_status", `Int status); ("arr_message", `String m) ]
          | None -> [ ("http_status", `Null); ("arr_message", `String msg) ]
        in
        event ~level:Events.Error "grab.failed"
          (Printf.sprintf "%s: grab failed for %s: %s" inst.inst_name release.Types.title msg)
          (release_data release (String.concat "; " notes) @ http);
        Lwt.return { grabbed = false; error = Some msg; notes }
  in
  (* Identity problems are worth their own message: nothing can be grabbed
     without a guid and a usable indexerId, and sending indexerId 0 would
     only produce an opaque 400/404 from the *arr. *)
  match Mapping.grab_identity release with
  | Error e ->
      let msg = Mapping.grab_error_message e in
      Log_buffer.errorf "%s: refusing to grab %s for %s: %s" inst.inst_name
        release.Types.title label msg;
      event ~level:Events.Error "grab.failed"
        (Printf.sprintf "%s: not sending %s: %s" inst.inst_name release.Types.title msg)
        (release_data release "refused" @ [ ("http_status", `Null); ("arr_message", `String msg) ]);
      Lwt.return
        {
          grabbed = false;
          error = Some msg;
          notes = [ "not sent to " ^ Types.app_to_string inst.inst_app ];
        }
  | Ok _ -> (
      Log_buffer.infof "%s: grabbing %s for %s (%s)" inst.inst_name release.Types.title
        label (describe release);
      Activity.progress (Printf.sprintf "grabbing %s" release.Types.title);
      sent release "direct";
      let* first = Client.grab client media release in
      match first with
      | Ok () -> finish ~notes:[ "grabbed directly" ] (Ok ())
      | Error e -> (
          match failure_kind e with
          | Mapping.Permanent -> finish ~notes:[ "grabbed directly" ] (Error e)
          | Mapping.Cache_miss -> (
              Log_buffer.warnf
                "%s: %s is no longer in %s's release cache; searching again and retrying"
                inst.inst_name release.Types.title
                (Types.app_to_string inst.inst_app);
              event ~level:Events.Warn "grab.retry"
                (Printf.sprintf "%s: %s left the release cache; searching again" inst.inst_name
                   release.Types.title)
                (release_data release "cache miss: search again"
                @ [ ("arr_message", `String (Client.error_to_string e)) ]);
              Activity.progress "searching again (release left the cache)\xe2\x80\xa6";
              let* refreshed = research () in
              match refreshed with
              | Error m ->
                  finish
                    ~notes:
                      [
                        "the release left the 30-minute cache and the new search failed: "
                        ^ m;
                      ]
                    (Error e)
              | Ok None ->
                  finish
                    ~notes:
                      [
                        "the release left the 30-minute cache and the new search no \
                         longer offers it";
                      ]
                    (Error e)
              | Ok (Some fresh) ->
                  sent fresh "searched again";
                  let* second = Client.grab client media fresh in
                  finish ~notes:[ "searched again, then grabbed" ] second)
          | Mapping.Needs_override ->
              Log_buffer.warnf
                "%s: %s could not map %s to %s; retrying with shouldOverride"
                inst.inst_name
                (Types.app_to_string inst.inst_app)
                release.Types.title label;
              event ~level:Events.Warn "grab.retry"
                (Printf.sprintf "%s: retrying %s with shouldOverride" inst.inst_name
                   release.Types.title)
                (release_data release "shouldOverride"
                @ [ ("arr_message", `String (Client.error_to_string e)) ]);
              sent release "shouldOverride";
              let* second = Client.grab_override client media release ~episode_ids in
              finish ~notes:[ "retried with shouldOverride" ] second))

(** Apply an outcome to a selection result. *)
let apply (outcome : outcome) (result : Types.selection_result) : Types.selection_result =
  {
    result with
    Types.grabbed = outcome.grabbed;
    grab_error = outcome.error;
    grab_notes = outcome.notes;
  }
