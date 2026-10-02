(* Job error messages that carry an HTTP status.

   A job runner can only fail with a string, but the synchronous endpoints
   that wait for a job must still answer 400/404/409/502 as they did before
   the queue existed.  A runner (or a job kind's parameter parser) therefore
   prefixes its message with the HTTP status it stands for:

     "[502] Radarr: release search failed for Come and See (1985): ..."

   The queue splits the prefix off when the job fails ([Jobs] stores the
   status as [error_status] and the bare message as [error]), and the
   /api/jobs handlers split it off parser errors, so clients never see it. *)

let make ~(status : int) (message : string) : string = Printf.sprintf "[%d] %s" status message

let is_digit c = c >= '0' && c <= '9'

(** [split s] is [(Some status, message)] when [s] starts with ["[ddd] "]
    (100..599), else [(None, s)]. *)
let split (s : string) : int option * string =
  let n = String.length s in
  if n >= 5 && s.[0] = '[' && is_digit s.[1] && is_digit s.[2] && is_digit s.[3] && s.[4] = ']'
  then
    let status = int_of_string (String.sub s 1 3) in
    if status >= 100 && status <= 599 then
      let rest = String.sub s 5 (n - 5) in
      let rest =
        if String.length rest > 0 && rest.[0] = ' ' then String.sub rest 1 (String.length rest - 1)
        else rest
      in
      (Some status, rest)
    else (None, s)
  else (None, s)

(** [split_default ~default s] is [split s] with [default] for a message
    without a prefix. *)
let split_default ~(default : int) (s : string) : int * string =
  match split s with Some status, m -> (status, m) | None, m -> (default, m)
