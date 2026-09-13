(* "Convert to structured rules".  Pure module, never raises. *)

let ( let* ) r f = Result.bind r f

(* ------------------------------------------------------------------------ *)
(* Field whitelist                                                           *)
(* ------------------------------------------------------------------------ *)

(* The JSON kind a field accepts.  The names match the keys produced by
   [Config.preferences_to_yojson], [Config.hard_rules_to_yojson] and
   [Config.weights_to_yojson] so that the resulting patch can be handed
   straight to [Config.patch]. *)
type kind =
  | Str_list
  | Int_list
  | Bool
  | Number
  | Number_or_null
  | Enum of string list

type field = { name : string; kind : kind; label : string }

let preferences_fields =
  [
    { name = "preferred_codecs"; kind = Str_list; label = "Preferred codecs" };
    { name = "disliked_codecs"; kind = Str_list; label = "Disliked codecs" };
    { name = "preferred_sources"; kind = Str_list; label = "Preferred sources" };
    { name = "preferred_groups"; kind = Str_list; label = "Preferred groups" };
    { name = "disliked_groups"; kind = Str_list; label = "Disliked groups" };
    {
      name = "preferred_languages";
      kind = Str_list;
      label = "Preferred languages";
    };
    {
      name = "preferred_resolutions";
      kind = Int_list;
      label = "Preferred resolutions";
    };
    { name = "preferred_audio"; kind = Str_list; label = "Preferred audio" };
    {
      name = "hdr_preference";
      kind = Enum [ "prefer"; "neutral"; "avoid" ];
      label = "HDR preference";
    };
    {
      name = "dolby_vision_preference";
      kind = Enum [ "prefer"; "neutral"; "avoid" ];
      label = "Dolby Vision preference";
    };
    { name = "prefer_remux"; kind = Bool; label = "Prefer remuxes" };
    { name = "prefer_repacks"; kind = Bool; label = "Prefer repacks" };
    {
      name = "ideal_size_gib";
      kind = Number_or_null;
      label = "Ideal size (GiB)";
    };
    {
      name = "size_tolerance_gib";
      kind = Number;
      label = "Size tolerance (GiB)";
    };
  ]

let hard_rules_fields =
  [
    {
      name = "max_size_gib";
      kind = Number_or_null;
      label = "Maximum size (GiB)";
    };
    {
      name = "min_size_gib";
      kind = Number_or_null;
      label = "Minimum size (GiB)";
    };
    { name = "min_seeders"; kind = Number_or_null; label = "Minimum seeders" };
    { name = "blocked_groups"; kind = Str_list; label = "Blocked groups" };
    { name = "blocked_codecs"; kind = Str_list; label = "Blocked codecs" };
    { name = "allowed_codecs"; kind = Str_list; label = "Allowed codecs" };
    {
      name = "blocked_languages";
      kind = Str_list;
      label = "Blocked languages";
    };
    {
      name = "required_languages";
      kind = Str_list;
      label = "Required languages";
    };
    { name = "allow_remux"; kind = Bool; label = "Allow remuxes" };
    { name = "allow_dolby_vision"; kind = Bool; label = "Allow Dolby Vision" };
    {
      name = "require_hdr10_fallback_for_dv";
      kind = Bool;
      label = "Require HDR10 fallback for Dolby Vision";
    };
    { name = "allow_hdr"; kind = Bool; label = "Allow HDR" };
    {
      name = "blocked_hdr_formats";
      kind = Str_list;
      label = "Blocked HDR formats";
    };
    {
      name = "allowed_resolutions";
      kind = Int_list;
      label = "Allowed resolutions";
    };
  ]

let weights_fields =
  [
    { name = "custom_format"; kind = Number; label = "Custom Format weight" };
    {
      name = "web_dl_over_webrip";
      kind = Number;
      label = "WEB-DL over WEBRip bonus";
    };
    {
      name = "bluray_over_web";
      kind = Number;
      label = "Blu-ray over web bonus";
    };
    { name = "remux"; kind = Number; label = "Remux bonus" };
    { name = "preferred_codec"; kind = Number; label = "Preferred codec bonus" };
    { name = "disliked_codec"; kind = Number; label = "Disliked codec penalty" };
    {
      name = "preferred_source";
      kind = Number;
      label = "Preferred source bonus";
    };
    { name = "preferred_group"; kind = Number; label = "Preferred group bonus" };
    { name = "disliked_group"; kind = Number; label = "Disliked group penalty" };
    {
      name = "preferred_language";
      kind = Number;
      label = "Preferred language bonus";
    };
    {
      name = "preferred_resolution";
      kind = Number;
      label = "Preferred resolution bonus";
    };
    { name = "preferred_audio"; kind = Number; label = "Preferred audio bonus" };
    { name = "hdr"; kind = Number; label = "HDR bonus" };
    { name = "dolby_vision"; kind = Number; label = "Dolby Vision bonus" };
    { name = "repack"; kind = Number; label = "Repack bonus" };
    { name = "seeders"; kind = Number; label = "Seeders weight" };
    { name = "seeders_cap"; kind = Number; label = "Seeders cap" };
    {
      name = "size_penalty_per_gib";
      kind = Number;
      label = "Size penalty per GiB";
    };
    { name = "arr_approved"; kind = Number; label = "Sonarr/Radarr approval bonus" };
  ]

let sections =
  [
    ("preferences", preferences_fields);
    ("hard_rules", hard_rules_fields);
    ("weights", weights_fields);
  ]

(* ------------------------------------------------------------------------ *)
(* Prompt                                                                    *)
(* ------------------------------------------------------------------------ *)

let system_prompt =
  String.concat "\n"
    [
      "You convert a user's natural-language media release preferences into \
       Pickarr's structured settings.";
      "";
      "RULES";
      "1. Only propose changes that the prose clearly asks for. Do not invent \
       preferences and do not restate the current values.";
      "2. Prefer soft settings in `preferences` and `weights`. Only propose a \
       `hard_rules` change when the user is unambiguous (\"never\", \
       \"always\", \"reject\", \"no more than\"); hard rules make releases \
       impossible to pick.";
      "3. You may only use the sections and fields listed in \
       `allowed_fields`, with the JSON types shown there.";
      "4. Nothing is applied automatically; the user reviews your proposals \
       first. Give a short `rationale` quoting the part of the prose that \
       motivates each change.";
      "";
      "RESPONSE FORMAT";
      "Reply with STRICT JSON ONLY, no prose and no code fences:";
      "{ \"proposals\": [ { \"section\": \"preferences\", \"field\": \
       \"preferred_codecs\", \"value\": [\"x265\"], \"rationale\": \"you said \
       you prefer x265 when quality is similar\" } ] }";
      "Return an empty `proposals` array when the prose does not map onto any \
       structured setting.";
    ]

let kind_to_string = function
  | Str_list -> "array of strings"
  | Int_list -> "array of integers"
  | Bool -> "boolean"
  | Number -> "number"
  | Number_or_null -> "number or null"
  | Enum values -> "one of " ^ String.concat " | " values

let allowed_fields_json () : Yojson.Safe.t =
  `Assoc
    (List.map
       (fun (section, fields) ->
         ( section,
           `Assoc
             (List.map
                (fun f -> (f.name, `String (kind_to_string f.kind)))
                fields) ))
       sections)

let build_prompt (config : Config.t) (text : string) : string =
  `Assoc
    [
      ("natural_language_preferences", `String text);
      ( "current_preferences",
        Config.preferences_to_yojson config.Config.preferences );
      ( "current_hard_rules",
        Config.hard_rules_to_yojson config.Config.hard_rules );
      ("current_weights", Config.weights_to_yojson config.Config.weights);
      ("allowed_fields", allowed_fields_json ());
    ]
  |> Yojson.Safe.to_string

(* ------------------------------------------------------------------------ *)
(* Parsing and validation                                                    *)
(* ------------------------------------------------------------------------ *)

let member key j =
  match j with `Assoc l -> List.assoc_opt key l | _ -> None

let as_string key j =
  match j with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field %S must be a string" key)
  | None -> Error (Printf.sprintf "missing field %S" key)

let is_number = function
  | `Int _ | `Float _ | `Intlit _ -> true
  | _ -> false

let check_value (f : field) (v : Yojson.Safe.t) : (Yojson.Safe.t, string) result =
  let type_error () =
    Error
      (Printf.sprintf "value for %S must be %s" f.name (kind_to_string f.kind))
  in
  match (f.kind, v) with
  | Str_list, `List items ->
      if List.for_all (function `String _ -> true | _ -> false) items then Ok v
      else type_error ()
  | Int_list, `List items ->
      if List.for_all is_number items then Ok v else type_error ()
  | Bool, `Bool _ -> Ok v
  | Number, x when is_number x -> Ok v
  | Number_or_null, `Null -> Ok v
  | Number_or_null, x when is_number x -> Ok v
  | Enum values, `String s ->
      if List.mem (String.lowercase_ascii s) values then
        Ok (`String (String.lowercase_ascii s))
      else type_error ()
  | (Str_list | Int_list | Bool | Number | Number_or_null | Enum _), _ ->
      type_error ()

let number_to_string (v : Yojson.Safe.t) : string =
  match v with
  | `Int i -> string_of_int i
  | `Intlit s -> s
  | `Float f ->
      if Float.is_integer f then Printf.sprintf "%.0f" f
      else Printf.sprintf "%g" f
  | other -> Yojson.Safe.to_string other

let summary_line (section : string) (f : field) (v : Yojson.Safe.t) : string =
  let value_text =
    match v with
    | `List items ->
        if items = [] then "(none)"
        else
          String.concat ", "
            (List.map
               (function `String s -> s | other -> number_to_string other)
               items)
    | `Bool b -> if b then "yes" else "no"
    | `Null -> "(unset)"
    | `String s -> s
    | other ->
        let n = number_to_string other in
        if section = "weights" then
          match other with
          | `Int i when i >= 0 -> "+" ^ string_of_int i
          | `Float fl when fl >= 0. -> "+" ^ n
          | _ -> n
        else n
  in
  Printf.sprintf "%s: %s" f.label value_text

let parse_proposal (j : Yojson.Safe.t) :
    (string * string * Yojson.Safe.t * string, string) result =
  match j with
  | `Assoc _ ->
      let* section = as_string "section" (member "section" j) in
      let* fields =
        match List.assoc_opt section sections with
        | Some fs -> Ok fs
        | None ->
            Error
              (Printf.sprintf
                 "unknown section %S (expected preferences, hard_rules or \
                  weights)"
                 section)
      in
      let* field_name = as_string "field" (member "field" j) in
      let* field =
        match List.find_opt (fun f -> f.name = field_name) fields with
        | Some f -> Ok f
        | None ->
            Error
              (Printf.sprintf "unknown field %S in section %S" field_name
                 section)
      in
      let* value =
        match member "value" j with
        | Some v -> check_value field v
        | None -> Error (Printf.sprintf "missing field %S" "value")
      in
      let rationale =
        match member "rationale" j with Some (`String s) -> s | _ -> ""
      in
      let line = summary_line section field value in
      let line =
        if String.trim rationale = "" then line else line ^ " — " ^ rationale
      in
      Ok (section, field_name, value, line)
  | _ -> Error "every entry of \"proposals\" must be an object"

let parse (j : Yojson.Safe.t) : (Yojson.Safe.t * string list, string) result =
  let* proposals =
    match member "proposals" j with
    | Some (`List items) -> Ok items
    | Some _ -> Error "field \"proposals\" must be an array"
    | None -> Error "missing field \"proposals\""
  in
  let* parsed =
    List.fold_left
      (fun acc item ->
        let* acc = acc in
        let* p = parse_proposal item in
        Ok (p :: acc))
      (Ok []) proposals
    |> Result.map List.rev
  in
  (* Group the proposals per section; a later proposal for the same field
     wins. *)
  let patch_of section =
    let fields =
      List.filter_map
        (fun (s, field, value, _) ->
          if s = section then Some (field, value) else None)
        parsed
    in
    let deduped =
      List.fold_left
        (fun acc (field, value) ->
          (field, value) :: List.filter (fun (f, _) -> f <> field) acc)
        [] fields
      |> List.rev
    in
    deduped
  in
  let patch =
    List.filter_map
      (fun (section, _) ->
        match patch_of section with
        | [] -> None
        | fields -> Some (section, `Assoc fields))
      sections
  in
  let summary = List.map (fun (_, _, _, line) -> line) parsed in
  Ok (`Assoc patch, summary)
