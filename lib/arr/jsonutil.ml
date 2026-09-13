(* Lenient JSON accessors for Sonarr/Radarr payloads.

   Every accessor is total: a missing key, a null, or a value of the wrong
   type yields the supplied default instead of raising.  That is deliberate.
   Sonarr and Radarr add and remove fields between releases, and Pickarr
   must keep working when a field it does not care about changes shape.

   Key lookup is case-insensitive because API resources are camelCase while
   webhook payloads have historically used PascalCase for some fields. *)

type t = Yojson.Safe.t

let assoc_find (key : string) (fields : (string * t) list) : t option =
  match List.assoc_opt key fields with
  | Some v -> Some v
  | None ->
      let lk = String.lowercase_ascii key in
      List.fold_left
        (fun acc (k, v) ->
          match acc with
          | Some _ -> acc
          | None -> if String.lowercase_ascii k = lk then Some v else None)
        None fields

(** [member key json] is the (non-null) value at [key], if any. *)
let member (key : string) (json : t) : t option =
  match json with
  | `Assoc fields -> ( match assoc_find key fields with Some `Null -> None | v -> v)
  | _ -> None

(** First key present among [keys]. *)
let member_any (keys : string list) (json : t) : t option =
  List.fold_left
    (fun acc k -> match acc with Some _ -> acc | None -> member k json)
    None keys

let string_opt key json =
  match member key json with
  | Some (`String s) -> Some s
  | Some (`Int i) -> Some (string_of_int i)
  | Some (`Intlit s) -> Some s
  | _ -> None

let string_def key default json = Option.value (string_opt key json) ~default

let int_opt key json =
  match member key json with
  | Some (`Int i) -> Some i
  | Some (`Intlit s) -> int_of_string_opt s
  | Some (`Float f) -> Some (int_of_float f)
  | Some (`String s) -> int_of_string_opt s
  | _ -> None

let int_def key default json = Option.value (int_opt key json) ~default

let int64_def key default json =
  match member key json with
  | Some (`Int i) -> Int64.of_int i
  | Some (`Intlit s) -> ( match Int64.of_string_opt s with Some i -> i | None -> default)
  | Some (`Float f) -> Int64.of_float f
  | Some (`String s) -> ( match Int64.of_string_opt s with Some i -> i | None -> default)
  | _ -> default

let float_opt key json =
  match member key json with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Intlit s) -> float_of_string_opt s
  | Some (`String s) -> float_of_string_opt s
  | _ -> None

let bool_def key default json =
  match member key json with
  | Some (`Bool b) -> b
  | Some (`String s) -> (
      match String.lowercase_ascii s with
      | "true" -> true
      | "false" -> false
      | _ -> default)
  | _ -> default

let list_def key json =
  match member key json with Some (`List l) -> l | _ -> []

let string_list key json =
  list_def key json
  |> List.filter_map (function
       | `String s -> Some s
       | `Int i -> Some (string_of_int i)
       | _ -> None)

let int_list key json =
  list_def key json
  |> List.filter_map (function
       | `Int i -> Some i
       | `Intlit s -> int_of_string_opt s
       | `Float f -> Some (int_of_float f)
       | `String s -> int_of_string_opt s
       | _ -> None)

(** Drop [None]s and empty strings from an optional string. *)
let non_empty = function Some "" -> None | v -> v

(** Decode a top-level array, returning [Error] when the payload is not one. *)
let as_list (what : string) (json : t) : (t list, string) result =
  match json with
  | `List l -> Ok l
  | _ -> Error (Printf.sprintf "expected a JSON array of %s" what)
