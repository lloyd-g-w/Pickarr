(* Typed resources shared by the Sonarr v3/v4 and Radarr v3 APIs.

   Field names and types were taken from the upstream OpenAPI documents
   vendored under vendor/ (Sonarr.Api.V3/openapi.json,
   Radarr.Api.V3/openapi.json).  Both applications share these schemas
   verbatim. *)

module J = Jsonutil

(** [Language] schema: {id, name}. *)
type language = { lang_id : int; lang_name : string option }

let language_of_yojson j =
  { lang_id = J.int_def "id" 0 j; lang_name = J.non_empty (J.string_opt "name" j) }

(** [Quality] schema.  [modifier] only exists in Radarr; Sonarr encodes the
    same information in the quality [name] and [source]. *)
type quality = {
  quality_id : int;
  quality_name : string option;  (** "WEBDL-1080p", "Bluray-2160p", ... *)
  quality_source : string option;
      (** Sonarr [QualitySource]: unknown | television | televisionRaw | web
          | webRip | dvd | bluray | blurayRaw.
          Radarr [QualitySource]: unknown | cam | telesync | telecine |
          workprint | dvd | tv | webdl | webrip | bluray. *)
  quality_resolution : int option;
  quality_modifier : string option;
      (** Radarr [Modifier]: none | regional | screener | rawhd | brdisk |
          remux. *)
}

let quality_of_yojson j =
  {
    quality_id = J.int_def "id" 0 j;
    quality_name = J.non_empty (J.string_opt "name" j);
    quality_source = J.non_empty (J.string_opt "source" j);
    quality_resolution = J.int_opt "resolution" j;
    quality_modifier = J.non_empty (J.string_opt "modifier" j);
  }

(** [Revision] schema: {version, real, isRepack}. *)
type revision = { rev_version : int; rev_real : int; rev_is_repack : bool }

let revision_of_yojson j =
  {
    rev_version = J.int_def "version" 1 j;
    rev_real = J.int_def "real" 0 j;
    rev_is_repack = J.bool_def "isRepack" false j;
  }

(** [QualityModel] schema: {quality, revision}. *)
type quality_model = { qm_quality : quality option; qm_revision : revision option }

let quality_model_of_yojson j =
  {
    qm_quality = Option.map quality_of_yojson (J.member "quality" j);
    qm_revision = Option.map revision_of_yojson (J.member "revision" j);
  }

(** [CustomFormatResource] schema (only the fields Selectarr needs). *)
type custom_format = { cf_id : int; cf_name : string option }

let custom_format_of_yojson j =
  { cf_id = J.int_def "id" 0 j; cf_name = J.non_empty (J.string_opt "name" j) }

(** [TagResource] schema: {id, label}. *)
type tag = { tag_id : int; tag_label : string option }

let tag_of_yojson j =
  { tag_id = J.int_def "id" 0 j; tag_label = J.non_empty (J.string_opt "label" j) }

(** Subset of [SystemResource] used by the connection test. *)
type system_status = {
  sys_app_name : string;
  sys_version : string;
  sys_instance_name : string;
}

let system_status_of_yojson j =
  {
    sys_app_name = J.string_def "appName" "unknown" j;
    sys_version = J.string_def "version" "unknown" j;
    sys_instance_name = J.string_def "instanceName" "" j;
  }

(** Common shape of every [*PagingResource]. *)
type 'a paging = {
  page : int;
  page_size : int;
  total_records : int;
  records : 'a list;
}

let paging_of_yojson (decode : Yojson.Safe.t -> 'a) (j : Yojson.Safe.t) : 'a paging =
  {
    page = J.int_def "page" 1 j;
    page_size = J.int_def "pageSize" 0 j;
    total_records = J.int_def "totalRecords" 0 j;
    records = List.map decode (J.list_def "records" j);
  }

(** [QualityProfileResource] (name only; the profile items are Sonarr's
    business, not ours). *)
type quality_profile = { qp_id : int; qp_name : string option }

let quality_profile_of_yojson j =
  { qp_id = J.int_def "id" 0 j; qp_name = J.non_empty (J.string_opt "name" j) }

(* --- helpers shared by the mapping layer --------------------------------- *)

let language_names (j : Yojson.Safe.t) (key : string) : string list =
  J.list_def key j |> List.map language_of_yojson
  |> List.filter_map (fun l -> l.lang_name)

let custom_formats (j : Yojson.Safe.t) (key : string) : custom_format list =
  J.list_def key j |> List.map custom_format_of_yojson
