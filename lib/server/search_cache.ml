(* The releases the last search returned, per (instance, media).

   Why this exists: a per-candidate Grab used to re-run the release search and
   look the chosen release up in the *new* result.  Indexer searches are not
   deterministic — an indexer that timed out, a dropped release, or a
   different [indexerId] after Sonarr/Radarr's guid de-duplication — so the
   grab intermittently failed with "no release with id ... is currently
   offered" even though Sonarr/Radarr still had the release in their own
   30-minute cache and would happily have grabbed it.

   Keeping the search result means a grab uses exactly the release the user
   clicked, with no second search at all. Entries expire with the *arr's own
   release cache (30 minutes), after which a grab falls back to searching
   again. *)

module Types = Pickarr_core.Types

(* Sonarr/Radarr keep a searched release for 30 minutes
   (docs/API_RESEARCH.md "3.4"); an entry older than that is useless because
   the grab would miss their cache anyway. *)
let ttl_seconds = 30. *. 60.

let max_entries = 64

type entry = {
  stored_at : float;
  candidates : Types.scored_release list;
  rejected : Types.rejected_release list;
}

type t = { table : (string, entry) Hashtbl.t }

let create () = { table = Hashtbl.create 16 }

(* A season has no media id of its own, so the key carries the kind and the
   season number too. *)
let key ~(instance_id : string) ~(media : Types.media) : string =
  Printf.sprintf "%s|%s|%d|%s" instance_id media.Types.media_kind media.Types.media_id
    (match media.Types.season_number with Some n -> string_of_int n | None -> "-")

let drop_expired (t : t) ~(now : float) =
  Hashtbl.iter
    (fun k (e : entry) -> if now -. e.stored_at > ttl_seconds then Hashtbl.remove t.table k)
    (Hashtbl.copy t.table)

(* Bounded so a long-running instance cannot accumulate every media item ever
   searched; the oldest entry goes first. *)
let drop_oldest (t : t) =
  if Hashtbl.length t.table > max_entries then
    let oldest =
      Hashtbl.fold
        (fun k (e : entry) acc ->
          match acc with
          | Some (_, at) when at <= e.stored_at -> acc
          | _ -> Some (k, e.stored_at))
        t.table None
    in
    match oldest with Some (k, _) -> Hashtbl.remove t.table k | None -> ()

let store ?(now = Unix.gettimeofday ()) (t : t) ~(instance_id : string)
    ~(media : Types.media) ~(candidates : Types.scored_release list)
    ~(rejected : Types.rejected_release list) : unit =
  drop_expired t ~now;
  Hashtbl.replace t.table
    (key ~instance_id ~media)
    { stored_at = now; candidates; rejected };
  drop_oldest t

(** The cached search for this media, or [None] when nothing was searched
    recently enough to be grabbable. *)
let find ?(now = Unix.gettimeofday ()) (t : t) ~(instance_id : string)
    ~(media : Types.media) : entry option =
  match Hashtbl.find_opt t.table (key ~instance_id ~media) with
  | Some e when now -. e.stored_at <= ttl_seconds -> Some e
  | Some _ | None -> None

(** How old the cached search is, in seconds. *)
let age ?(now = Unix.gettimeofday ()) (e : entry) : float = now -. e.stored_at

let forget (t : t) ~(instance_id : string) ~(media : Types.media) : unit =
  Hashtbl.remove t.table (key ~instance_id ~media)

(** Forget every remembered search.  Called when the configuration changes,
    because the candidates were filtered and scored with the old rules. *)
let clear (t : t) : unit = Hashtbl.reset t.table
