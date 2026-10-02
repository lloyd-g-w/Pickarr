(* Response shapes and error statuses shared by the HTTP routes and the queue
   job runners (lib/server/job_kinds.ml), so a selection answers with the same
   JSON and the same status code whether it ran inline or as a job.

   Job errors and HTTP statuses
   ----------------------------
   A job runner can only fail with a string, but the synchronous endpoints
   that wait for a job must still answer 400/404/409/502 as they did before
   the queue existed.  A runner therefore prefixes its message with the HTTP
   status it stands for:

     "[502] Radarr: release search failed for Come and See (1985): ..."

   [status_error] builds such a message and [split_status_error] takes it
   apart again (both are lib/server/status_error.ml).  A message without the
   prefix (an exception, or a job kind that does not care) maps to the
   caller's default.  The queue strips the prefix when a job fails: the job
   JSON carries "error" without it and "error_status" with the code, and
   [job_error_status] reads them back. *)

module Config = Pickarr_core.Config

let status_error ~(status : int) (message : string) : string = Status_error.make ~status message

(** [split_status_error ~default s] is [(status, message)]: the status from a
    leading ["[ddd] "] (100..599), else [default] and [s] unchanged. *)
let split_status_error ~(default : int) (s : string) : int * string =
  Status_error.split_default ~default s

(** The HTTP status and message of a selection error, as the routes have
    always answered them. *)
let selection_error_status (e : Selection.error) : int * string =
  match e with
  | Selection.Bad_request m -> (400, m)
  | Selection.Instance_not_found id -> (404, Printf.sprintf "no instance \"%s\" is configured" id)
  | Selection.Media_not_found m -> (404, m)
  | Selection.Release_not_found m -> (404, m)
  | Selection.Release_rejected m -> (409, m)
  | Selection.Arr_error m -> (502, m)

let selection_error (e : Selection.error) : string =
  let status, message = selection_error_status e in
  status_error ~status message

(** The HTTP status and message of a Seerr request action error. *)
let seerr_error_status (e : Seerr_sync.request_error) : int * string =
  let message = Seerr_sync.request_error_message e in
  match e with
  | Seerr_sync.Req_bad_request _ -> (400, message)
  | Seerr_sync.Req_not_found _ -> (404, message)
  | Seerr_sync.Req_unconfigured _ | Seerr_sync.Req_pending _ | Seerr_sync.Req_nothing _ ->
      (409, message)
  | Seerr_sync.Req_upstream _ -> (502, message)

let seerr_error (e : Seerr_sync.request_error) : string =
  let status, message = seerr_error_status e in
  status_error ~status message

let unknown_instance (id : string) : string =
  status_error ~status:404 (Printf.sprintf "no instance \"%s\" is configured" id)

(** Add the "open in Sonarr/Radarr" and "open in Seerr" links to every media
    object in [json]; see {!Library.decorate}.  Without [instance_id] the
    media's app default is used, which is what the /select/sonarr/... routes
    select on. *)
let decorate (state : App_state.t) ?(instance_id : string option) (json : Yojson.Safe.t) :
    Yojson.Safe.t =
  let config = App_state.config state in
  let instance = Option.bind instance_id (App_state.find_instance state) in
  Library.decorate ~config ~instance json

(** The HTTP status and message of a failed job's JSON: "error_status" when
    present, else a status prefix still on "error" (jobs written by an older
    version), else [default]. *)
let job_error_status ?(default = 500) (job : Yojson.Safe.t) : int * string =
  let field k = match job with `Assoc l -> List.assoc_opt k l | _ -> None in
  let message =
    match field "error" with Some (`String s) when String.trim s <> "" -> s | _ -> "the job failed"
  in
  match field "error_status" with
  | Some (`Int status) when status >= 100 && status <= 599 ->
      (status, snd (Status_error.split message))
  | _ -> split_status_error ~default message
