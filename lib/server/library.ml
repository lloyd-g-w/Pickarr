(* Library browsing: searching the cached series/movie list, and the
   "open in …" links.

   Pure module: every function here is a plain data transformation, so the
   matching rules and the URL shapes are unit tested without a server.

   Link shapes, verified against the upstream front ends:
   - Sonarr:  {instance url}/series/{titleSlug}
              (frontend/src/App/AppRoutes.tsx: <Route path="/series/:titleSlug">)
   - Radarr:  {instance url}/movie/{titleSlug}
              (frontend/src/App/AppRoutes.tsx: <Route path="/movie/:titleSlug">,
              frontend/src/Movie/MovieTitleLink.tsx builds `/movie/${titleSlug}`,
              and MovieDetailsPage.tsx looks the movie up BY titleSlug, so a
              TMDB id in that position shows "Movie cannot be found")
   - Seerr:   {seerr url}/movie/{tmdbId} and {seerr url}/tv/{tmdbId}
              (server/lib/notifications/agents/discord.ts:
              `${applicationUrl}/${payload.media.mediaType}/${payload.media.tmdbId}`) *)

module Config = Pickarr_core.Config
module Types = Pickarr_core.Types
module Client = Pickarr_arr.Client

(* ------------------------------------------------------------------ *)
(* Search                                                              *)
(* ------------------------------------------------------------------ *)

let max_results = 25

let lower = String.lowercase_ascii

let contains ~(needle : string) ~(haystack : string) : bool =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec go i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else go (i + 1)
    in
    go 0

(** An "tt1234567" style IMDb id, normalised for comparison. *)
let imdb_id_of_query (q : string) : string option =
  let q = lower (String.trim q) in
  let looks_like_imdb =
    String.length q > 2
    && String.sub q 0 2 = "tt"
    && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub q 2 (String.length q - 2))
  in
  if looks_like_imdb then Some q else None

(** Does [item] answer [query]?  A number matches the *arr id and the
    external ids (so pasting a TMDB or TheTVDB id works); "tt…" matches the
    IMDb id; anything else is a case-insensitive substring of the title, the
    sort title or an alternate title. *)
let matches (query : string) (i : Client.library_item) : bool =
  let q = String.trim query in
  if q = "" then true
  else
    match (int_of_string_opt q, imdb_id_of_query q) with
    | Some n, _ ->
        i.Client.li_id = n
        || i.Client.li_tmdb_id = Some n
        || i.Client.li_tvdb_id = Some n
    | _, Some imdb -> (
        match i.Client.li_imdb_id with Some id -> lower id = imdb | None -> false)
    | None, None ->
        let needle = lower q in
        let hit s = contains ~needle ~haystack:(lower s) in
        hit i.Client.li_title
        || (match i.Client.li_sort_title with Some s -> hit s | None -> false)
        || List.exists hit i.Client.li_alternate_titles

(** Rank the matches so the most useful row is first: an exact title match,
    then a title that starts with the query, then everything else; ties go to
    the alphabetically first title.  Capped at {!max_results}. *)
let search (query : string) (items : Client.library_item list) : Client.library_item list =
  let q = lower (String.trim query) in
  let rank (i : Client.library_item) =
    let t = lower i.Client.li_title in
    if q = "" then 2
    else if t = q then 0
    else if String.length t >= String.length q && String.sub t 0 (String.length q) = q then 1
    else 2
  in
  items |> List.filter (matches query)
  |> List.stable_sort (fun a b ->
         match compare (rank a) (rank b) with
         | 0 -> compare (lower a.Client.li_title) (lower b.Client.li_title)
         | c -> c)
  |> List.filteri (fun n _ -> n < max_results)

(* ------------------------------------------------------------------ *)
(* Links                                                              *)
(* ------------------------------------------------------------------ *)

let strip_trailing_slash s =
  if String.length s > 0 && s.[String.length s - 1] = '/' then
    String.sub s 0 (String.length s - 1)
  else s

(** A media kind as the link builders see it: Sonarr episode/season/series
    rows all point at the series page. *)
type kind = Series | Movie

let kind_of_media_kind = function
  | "movie" -> Some Movie
  | "episode" | "season" | "series" -> Some Series
  | _ -> None

(** [arr_link inst ~title_slug] is the *arr web page for the item, or [None]
    when the instance has no URL or the resource carried no [titleSlug]
    (older Sonarr/Radarr versions and hand-made fixtures). *)
let arr_link (inst : Config.instance) ~(kind : kind) ~(title_slug : string option) :
    string option =
  match (String.trim inst.Config.inst_url, title_slug) with
  | "", _ | _, None -> None
  | url, Some slug when String.trim slug <> "" ->
      let path = match kind with Series -> "series" | Movie -> "movie" in
      Some (Printf.sprintf "%s/%s/%s" (strip_trailing_slash url) path (String.trim slug))
  | _ -> None

(** [seerr_link config ~kind ~tmdb_id] is the Seerr page for the item.  Seerr
    keys both movies and TV by TMDB id, so a TV item without a TMDB id has no
    link even when its TheTVDB id is known. *)
let seerr_link (config : Config.t) ~(kind : kind) ~(tmdb_id : int option) : string option =
  match (String.trim config.Config.seerr.seerr_url, tmdb_id) with
  | "", _ | _, None -> None
  | url, Some id when id > 0 ->
      let path = match kind with Series -> "tv" | Movie -> "movie" in
      Some (Printf.sprintf "%s/%s/%d" (strip_trailing_slash url) path id)
  | _ -> None

(** The [links] object used everywhere in the API: absent keys mean "not
    linkable", and an empty object is returned rather than [null] so the UI
    can read [links.arr] without a guard. *)
let links_json ?(instance : Config.instance option) ~(config : Config.t) ~(kind : kind)
    ~(title_slug : string option) ~(tmdb_id : int option) () : Yojson.Safe.t =
  let arr = match instance with None -> None | Some i -> arr_link i ~kind ~title_slug in
  let seerr = seerr_link config ~kind ~tmdb_id in
  `Assoc
    (List.filter_map
       (fun (k, v) -> match v with None -> None | Some url -> Some (k, `String url))
       [ ("arr", arr); ("seerr", seerr) ])

let links_of_item ?instance ~(config : Config.t) (i : Client.library_item) : Yojson.Safe.t =
  let kind = if i.Client.li_kind = "movie" then Movie else Series in
  links_json ?instance ~config ~kind ~title_slug:i.Client.li_title_slug
    ~tmdb_id:i.Client.li_tmdb_id ()

let item_to_yojson ?instance ~(config : Config.t) (i : Client.library_item) : Yojson.Safe.t =
  match Client.library_item_to_yojson i with
  | `Assoc fields -> `Assoc (fields @ [ ("links", links_of_item ?instance ~config i) ])
  | other -> other

(* ------------------------------------------------------------------ *)
(* Decorating responses                                                *)
(* ------------------------------------------------------------------ *)

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_member key j =
  match member key j with Some (`String s) when String.trim s <> "" -> Some s | _ -> None

let int_member key j =
  match member key j with
  | Some (`Int i) -> Some i
  | Some (`Intlit s) | Some (`String s) -> int_of_string_opt (String.trim s)
  | _ -> None

(** Does this JSON object look like a serialised {!Pickarr_core.Types.media}?
    Those three keys together appear nowhere else in the API. *)
let is_media (j : Yojson.Safe.t) : bool =
  member "media_kind" j <> None && member "media_id" j <> None && member "app" j <> None

let links_of_media_json ~(config : Config.t) ~(instance : Config.instance option)
    (j : Yojson.Safe.t) : Yojson.Safe.t option =
  match Option.bind (string_member "media_kind" j) kind_of_media_kind with
  | None -> None
  | Some kind ->
      (* For the app-default routes the caller does not know which instance
         served the request; the media says which app it came from, and that
         app's first enabled instance is the one the route used. *)
      let instance =
        match instance with
        | Some i -> Some i
        | None ->
            Option.bind
              (Option.bind (string_member "app" j) Types.app_of_string)
              (Config.default_instance config)
      in
      let links =
        links_json ?instance ~config ~kind
          ~title_slug:(string_member "title_slug" j)
          ~tmdb_id:(int_member "tmdb_id" j) ()
      in
      Some links

(** Add a [links] object to every media object inside [json], wherever it
    sits: a selection result, a whole-series result with one media per
    season, a series overview or a Seerr payload.  One traversal at the
    response boundary keeps the link shapes in a single place and out of
    {!Pickarr_core.Types}. *)
let decorate ~(config : Config.t) ~(instance : Config.instance option)
    (json : Yojson.Safe.t) : Yojson.Safe.t =
  let rec go (j : Yojson.Safe.t) : Yojson.Safe.t =
    match j with
    | `Assoc fields ->
        let mapped = `Assoc (List.map (fun (k, v) -> (k, go v)) fields) in
        if is_media j && member "links" j = None then
          match links_of_media_json ~config ~instance mapped with
          | Some (`Assoc []) | None -> mapped
          | Some links -> (
              match mapped with
              | `Assoc fields -> `Assoc (fields @ [ ("links", links) ])
              | other -> other)
        else mapped
    | `List items -> `List (List.map go items)
    | leaf -> leaf
  in
  go json

(** The links for a media value, used when writing a history entry. *)
let links_of_media ~(config : Config.t) ~(instance : Config.instance option)
    (media : Types.media) : Yojson.Safe.t =
  match links_of_media_json ~config ~instance (Types.media_to_yojson media) with
  | Some links -> links
  | None -> `Assoc []
