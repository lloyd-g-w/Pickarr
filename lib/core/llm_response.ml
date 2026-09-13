(* Stage 4 validation.  Pure module, never raises. *)

let member (key : string) (j : Yojson.Safe.t) : Yojson.Safe.t option =
  match j with
  | `Assoc l -> ( match List.assoc_opt key l with Some `Null -> None | v -> v)
  | _ -> None

let float_of_json (j : Yojson.Safe.t) : float option =
  match j with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | `Intlit s | `String s -> float_of_string_opt (String.trim s)
  | `Bool _ | `Null | `Assoc _ | `List _ -> None

let finite (f : float) : float option =
  if Float.is_nan f || Float.abs f = Float.infinity then None else Some f

let string_of_json (j : Yojson.Safe.t) : string option =
  match j with
  | `String s -> Some s
  | `Int i -> Some (string_of_int i)
  | `Intlit s -> Some s
  | `Float f -> Some (Printf.sprintf "%g" f)
  | _ -> None

(* ------------------------------------------------------------------------ *)
(* Id resolution                                                             *)
(* ------------------------------------------------------------------------ *)

(* Models quote ids, bold them, append a colon, write "Candidate 3" or "#3",
   or answer with the title instead of the id.  All of those are recoverable;
   what is never allowed is inventing an id that is not a candidate. *)

let is_wrapper = function
  | '"' | '\'' | '`' | '*' | '[' | ']' | '(' | ')' | ' ' | '\t' | '\n' | '\r' ->
      true
  | _ -> false

let is_trailing_punct = function
  | ':' | '.' | ',' | ';' | '!' | '-' -> true
  | c -> is_wrapper c

let trim_with (f : char -> bool) (s : string) : string =
  let n = String.length s in
  let i = ref 0 and j = ref (n - 1) in
  while !i < n && f s.[!i] do
    incr i
  done;
  while !j >= !i && f s.[!j] do
    decr j
  done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)

(* Lowercase and drop every space, so "R 3" and "r3" are the same key and a
   title matches whatever spacing the model used. *)
let squash (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' -> ()
      | 'A' .. 'Z' -> Buffer.add_char b (Char.lowercase_ascii c)
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let normalise_id (s : string) : string =
  s |> trim_with is_wrapper
  |> (fun s ->
       (* Only trailing punctuation is dropped: a leading '#' is meaningful
          and handled by the prefix stripping below. *)
       let n = String.length s in
       let j = ref (n - 1) in
       while !j >= 0 && is_trailing_punct s.[!j] do
         decr j
       done;
       if !j < 0 then "" else String.sub s 0 (!j + 1))
  |> squash

let is_digits (s : string) : bool =
  s <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) s

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let drop_prefix ~prefix s =
  String.sub s (String.length prefix) (String.length s - String.length prefix)

(* "#3", "candidate3", "release3", "id:3" (already squashed) -> "3". *)
let rec strip_id_prefixes (s : string) : string =
  let prefixes = [ "#"; "candidate"; "release"; "option"; "choice"; "id"; "no."; "no"; "number" ] in
  match List.find_opt (fun p -> starts_with ~prefix:p s && s <> p) prefixes with
  | Some p -> strip_id_prefixes (drop_prefix ~prefix:p s)
  | None -> s

type table = { exact : (string, string) Hashtbl.t; ambiguous : (string, unit) Hashtbl.t }

(** [make_table ~candidate_ids ~aliases] maps every accepted spelling to the
    canonical candidate id.  An alias that would point at two different
    candidates is dropped rather than guessed. *)
let make_table ~(candidate_ids : string list) ~(aliases : (string * string) list)
    : table =
  let t = { exact = Hashtbl.create 64; ambiguous = Hashtbl.create 8 } in
  let add key value =
    if key <> "" then
      match Hashtbl.find_opt t.exact key with
      | None -> Hashtbl.replace t.exact key value
      | Some existing -> if existing <> value then Hashtbl.replace t.ambiguous key ()
  in
  List.iter
    (fun id ->
      let key = normalise_id id in
      add key id;
      (* "r3" is also reachable as "3". *)
      if starts_with ~prefix:"r" key && is_digits (drop_prefix ~prefix:"r" key)
      then add (drop_prefix ~prefix:"r" key) id)
    candidate_ids;
  (* Aliases are added last so a real id always wins. *)
  List.iter (fun (alias, id) -> add (normalise_id alias) id) aliases;
  t

let resolve (t : table) (raw : string) : string option =
  let attempt key =
    if key = "" || Hashtbl.mem t.ambiguous key then None
    else Hashtbl.find_opt t.exact key
  in
  let key = normalise_id raw in
  match attempt key with
  | Some id -> Some id
  | None -> attempt (strip_id_prefixes key)

(* ------------------------------------------------------------------------ *)
(* Warnings                                                                  *)
(* ------------------------------------------------------------------------ *)

let max_warnings = 6

let collect (warnings : string list ref) (w : string) : unit =
  if (not (List.mem w !warnings)) && List.length !warnings < max_warnings then
    warnings := !warnings @ [ w ]

let truncate n s =
  if String.length s <= n then s else String.sub s 0 n ^ "..."

(* ------------------------------------------------------------------------ *)
(* Pieces                                                                    *)
(* ------------------------------------------------------------------------ *)

let default_confidence = 0.5

let parse_confidence ~(warn : string -> unit) (j : Yojson.Safe.t) : float =
  match member "confidence" j with
  | None ->
      warn "the model gave no confidence, assuming 0.5";
      default_confidence
  | Some v -> (
      match Option.bind (float_of_json v) finite with
      | None ->
          warn "the model's confidence was not a number, assuming 0.5";
          default_confidence
      | Some f ->
          (* Models routinely answer 85 or 95% instead of 0.85. *)
          let f =
            if f > 1. && f <= 100. then (
              warn
                (Printf.sprintf "confidence %g was read as %.2f" f (f /. 100.));
              f /. 100.)
            else f
          in
          if f < 0. then (
            warn "confidence below 0 was clamped to 0";
            0.)
          else if f > 1. then (
            warn "confidence above 1 was clamped to 1";
            1.)
          else f)

let reason_of (key : string) (j : Yojson.Safe.t) : string =
  match member key j with
  | Some (`String s) -> String.trim s
  | Some other -> Yojson.Safe.to_string other
  | None -> ""

(* Non-string items are skipped rather than failing the whole answer: these
   fields are shown to the user, they are not used for any decision. *)
let string_list ~(warn : string -> unit) (key : string) (j : Yojson.Safe.t) :
    string list =
  match member key j with
  | None -> []
  | Some (`String s) -> if String.trim s = "" then [] else [ String.trim s ]
  | Some (`List items) ->
      let kept =
        List.filter_map
          (function
            | `String s when String.trim s <> "" -> Some (String.trim s)
            | `Null -> None
            | other ->
                warn
                  (Printf.sprintf "an entry of %S was not a sentence and was dropped"
                     key);
                ignore other;
                None)
          items
      in
      kept
  | Some _ ->
      warn (Printf.sprintf "%S was not a list of sentences and was ignored" key);
      []

let clamp_score ~(warn : string -> unit) ~(id : string) (score : int) : int =
  if score < 0 then (
    warn (Printf.sprintf "score %d for %s was clamped to 0" score id);
    0)
  else if score > 100 then (
    warn (Printf.sprintf "score %d for %s was clamped to 100" score id);
    100)
  else score

(** Ranking is advisory: it only orders the candidate list the user sees, so
    every recoverable problem is a warning and the entry is kept or dropped,
    never fatal. *)
let parse_ranking ~(warn : string -> unit) ~(table : table)
    ~(selected_id : string) ~(llm_reason : string) (j : Yojson.Safe.t option) :
    Types.llm_ranking_entry list =
  let only_selected () =
    [ { Types.rank_id = selected_id; rank_score = 100; rank_reason = llm_reason } ]
  in
  match j with
  | None ->
      warn "the model returned no ranking, only its pick was recorded";
      only_selected ()
  | Some (`List []) ->
      warn "the model returned an empty ranking, only its pick was recorded";
      only_selected ()
  | Some (`List items) ->
      let seen = Hashtbl.create 16 in
      let entries =
        List.concat
          (List.mapi
             (fun i item ->
               match item with
               | `Assoc _ -> (
                   let raw_id =
                     match member "id" item with
                     | Some v -> Option.value (string_of_json v) ~default:""
                     | None -> ""
                   in
                   match resolve table raw_id with
                   | None ->
                       warn
                         (Printf.sprintf
                            "a ranking entry named an unknown release (%s) and \
                             was dropped"
                            (if String.trim raw_id = "" then "no id"
                             else "\"" ^ truncate 40 (String.trim raw_id) ^ "\""));
                       []
                   | Some id ->
                       if Hashtbl.mem seen id then (
                         warn
                           (Printf.sprintf
                              "the ranking listed %s twice, the first entry was \
                               kept"
                              id);
                         [])
                       else (
                         Hashtbl.replace seen id ();
                         let score =
                           match Option.bind (member "score" item) float_of_json with
                           | Some f when finite f <> None ->
                               clamp_score ~warn ~id
                                 (int_of_float (Float.round f))
                           | _ ->
                               warn
                                 (Printf.sprintf
                                    "no usable score for %s, its position in the \
                                     ranking was used"
                                    id);
                               max 0 (100 - (5 * i))
                         in
                         [
                           {
                             Types.rank_id = id;
                             rank_score = score;
                             rank_reason = reason_of "reason" item;
                           };
                         ]))
               | _ ->
                   warn "a ranking entry was not an object and was dropped";
                   [])
             items)
      in
      if entries = [] then (
        warn "no ranking entry could be used, only the pick was recorded";
        only_selected ())
      else entries
  | Some _ ->
      warn "the ranking was not a list, only the pick was recorded";
      only_selected ()

(* ------------------------------------------------------------------------ *)
(* Entry points                                                              *)
(* ------------------------------------------------------------------------ *)

let parse_with_warnings ~(candidate_ids : string list)
    ?(aliases : (string * string) list = []) (j : Yojson.Safe.t) :
    (Types.llm_decision * string list, string) result =
  match j with
  | `Assoc _ -> (
      let warnings = ref [] in
      let warn = collect warnings in
      let table = make_table ~candidate_ids ~aliases in
      let raw_selected =
        match member "selected_id" j with
        | Some v -> string_of_json v
        | None -> None
      in
      match raw_selected with
      | None -> Error "the model did not name a release in \"selected_id\""
      | Some raw -> (
          match resolve table raw with
          | None ->
              Error
                (Printf.sprintf "selected_id %S is not one of the candidates"
                   (truncate 80 (String.trim raw)))
          | Some selected_id ->
              let confidence = parse_confidence ~warn j in
              let llm_reason = reason_of "reason" j in
              let ranking =
                parse_ranking ~warn ~table ~selected_id ~llm_reason
                  (member "ranking" j)
              in
              let influences = string_list ~warn "influences" j in
              let conflicts = string_list ~warn "conflicts" j in
              Ok
                ( {
                    Types.selected_id;
                    confidence;
                    llm_reason;
                    ranking;
                    influences;
                    conflicts;
                  },
                  !warnings )))
  | `Null -> Error "the model returned no JSON object"
  | _ -> Error "the model response must be a JSON object"

let parse ~(candidate_ids : string list) (j : Yojson.Safe.t) :
    (Types.llm_decision, string) result =
  Result.map fst (parse_with_warnings ~candidate_ids j)
