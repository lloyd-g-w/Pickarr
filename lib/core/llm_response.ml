(* Stage 4 validation.  Pure module, never raises. *)

let ( let* ) r f = Result.bind r f

let member (key : string) (j : Yojson.Safe.t) : Yojson.Safe.t option =
  match j with
  | `Assoc l -> ( match List.assoc_opt key l with Some `Null -> None | v -> v)
  | _ -> None

let as_string (key : string) (j : Yojson.Safe.t) : (string, string) result =
  match j with
  | `String s -> Ok s
  | `Int i -> Ok (string_of_int i)
  | _ -> Error (Printf.sprintf "field %S must be a string" key)

let as_float (key : string) (j : Yojson.Safe.t) : (float, string) result =
  match j with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | `Intlit s | `String s -> (
      match float_of_string_opt (String.trim s) with
      | Some f -> Ok f
      | None -> Error (Printf.sprintf "field %S must be a number" key))
  | _ -> Error (Printf.sprintf "field %S must be a number" key)

(* Scores are whole numbers, but models happily emit 94.0 or "94"; those are
   accepted and rounded.  NaN and infinities are rejected. *)
let as_int (key : string) (j : Yojson.Safe.t) : (int, string) result =
  let* f = as_float key j in
  if Float.is_nan f || Float.abs f = Float.infinity then
    Error (Printf.sprintf "field %S must be a finite number" key)
  else if Float.abs f > 1e9 then
    Error (Printf.sprintf "field %S is out of range" key)
  else Ok (int_of_float (Float.round f))

let as_string_list (key : string) (j : Yojson.Safe.t) : (string list, string) result
    =
  match j with
  | `List items ->
      List.fold_left
        (fun acc item ->
          let* acc = acc in
          match item with
          | `String s -> Ok (s :: acc)
          | _ -> Error (Printf.sprintf "field %S must only contain strings" key))
        (Ok []) items
      |> Result.map List.rev
  | `String s -> Ok (if String.trim s = "" then [] else [ s ])
  | _ -> Error (Printf.sprintf "field %S must be an array of strings" key)

(* [label] is how the field is named in error messages, which is not always
   the JSON key: ranking entries report "ranking[].id" for their "id". *)
let required ?label (key : string) (j : Yojson.Safe.t) :
    (Yojson.Safe.t, string) result =
  match member key j with
  | Some v -> Ok v
  | None ->
      Error
        (Printf.sprintf "missing field %S" (Option.value label ~default:key))

let optional_string_list (key : string) (j : Yojson.Safe.t) :
    (string list, string) result =
  match member key j with None -> Ok [] | Some v -> as_string_list key v

let parse_ranking_entry ~(candidate_ids : string list) (j : Yojson.Safe.t) :
    (Types.llm_ranking_entry, string) result =
  match j with
  | `Assoc _ ->
      let* id_json = required ~label:"ranking[].id" "id" j in
      let* rank_id = as_string "ranking[].id" id_json in
      let* () =
        if List.mem rank_id candidate_ids then Ok ()
        else
          Error
            (Printf.sprintf "ranking contains unknown release id %S" rank_id)
      in
      let* score_json = required ~label:"ranking[].score" "score" j in
      let* rank_score = as_int "ranking[].score" score_json in
      let* () =
        if rank_score >= 0 && rank_score <= 100 then Ok ()
        else
          Error
            (Printf.sprintf "ranking score %d for %S is outside 0..100"
               rank_score rank_id)
      in
      let rank_reason =
        match member "reason" j with
        | Some (`String s) -> s
        | Some other -> Yojson.Safe.to_string other
        | None -> ""
      in
      Ok { Types.rank_id; rank_score; rank_reason }
  | _ -> Error "every entry of \"ranking\" must be an object"

let parse_ranking ~(candidate_ids : string list) (j : Yojson.Safe.t) :
    (Types.llm_ranking_entry list, string) result =
  match j with
  | `List items ->
      let* entries =
        List.fold_left
          (fun acc item ->
            let* acc = acc in
            let* entry = parse_ranking_entry ~candidate_ids item in
            Ok (entry :: acc))
          (Ok []) items
        |> Result.map List.rev
      in
      let rec duplicates seen = function
        | [] -> None
        | e :: tl ->
            if List.mem e.Types.rank_id seen then Some e.Types.rank_id
            else duplicates (e.Types.rank_id :: seen) tl
      in
      (match duplicates [] entries with
      | Some id ->
          Error (Printf.sprintf "ranking contains duplicate release id %S" id)
      | None -> Ok entries)
  | _ -> Error "field \"ranking\" must be an array"

let parse ~(candidate_ids : string list) (j : Yojson.Safe.t) :
    (Types.llm_decision, string) result =
  match j with
  | `Assoc _ ->
      let* selected_json = required "selected_id" j in
      let* selected_id = as_string "selected_id" selected_json in
      let* () =
        if List.mem selected_id candidate_ids then Ok ()
        else
          Error
            (Printf.sprintf "selected_id %S is not one of the candidates"
               selected_id)
      in
      let* confidence_json = required "confidence" j in
      let* confidence = as_float "confidence" confidence_json in
      let* () =
        if Float.is_nan confidence then Error "field \"confidence\" must be a number"
        else if confidence >= 0. && confidence <= 1. then Ok ()
        else
          Error
            (Printf.sprintf "confidence %g is outside 0..1" confidence)
      in
      let* ranking_json = required "ranking" j in
      let* ranking = parse_ranking ~candidate_ids ranking_json in
      let* llm_reason =
        match member "reason" j with
        | None -> Ok ""
        | Some v -> as_string "reason" v
      in
      let* influences = optional_string_list "influences" j in
      let* conflicts = optional_string_list "conflicts" j in
      Ok
        {
          Types.selected_id;
          confidence;
          llm_reason;
          ranking;
          influences;
          conflicts;
        }
  | `Null -> Error "the model returned no JSON object"
  | _ -> Error "the model response must be a JSON object"
