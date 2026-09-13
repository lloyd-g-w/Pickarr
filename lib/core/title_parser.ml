(* Best-effort release-title parser.  See title_parser.mli.

   Implementation notes:
   - ocaml-re does not support look-around, so every "token" match is written
     with explicit delimiter alternatives instead of \b look-aheads.
   - All regexes are compiled once at module initialisation. *)

type parsed = {
  source : string option;
  codec : string option;
  audio : string option;
  audio_channels : string option;
  hdr : string list;
  dolby_vision : bool;
  dv_profile : string option;
  resolution : int option;
  release_group : string option;
  is_repack : bool;
  is_proper : bool;
  languages : string list;
  bit_depth : int option;
}

let empty =
  {
    source = None;
    codec = None;
    audio = None;
    audio_channels = None;
    hdr = [];
    dolby_vision = false;
    dv_profile = None;
    resolution = None;
    release_group = None;
    is_repack = false;
    is_proper = false;
    languages = [];
    bit_depth = None;
  }

(* ------------------------------------------------------------------ *)
(* Regex helpers                                                       *)
(* ------------------------------------------------------------------ *)

(* Delimiters that separate tokens in a release title. *)
let pre = {|(?:^|[\s._\-\[\]()])|}
let post = {|(?:$|[\s._\-\[\]()])|}

(* Same as [post] but also accepts a digit, for tags such as "DDP5.1" or
   "DTS5.1" where the channel layout is glued to the format name. *)
let post_d = {|(?:$|[\s._\-\[\]()0-9])|}

let rx p = Re.Pcre.re ~flags:[ `CASELESS ] p |> Re.compile

(* [tok p] matches [p] as a delimited token. *)
let tok p = rx (pre ^ "(?:" ^ p ^ ")" ^ post)

(* [tokd p] matches [p] as a token that may be followed by digits. *)
let tokd p = rx (pre ^ "(?:" ^ p ^ ")" ^ post_d)

(* [lead p] matches [p] when preceded by a delimiter, ignoring what follows. *)
let lead p = rx (pre ^ "(?:" ^ p ^ ")")

let has re s = Re.execp re s

(* First capture group of the first match, if any. *)
let capture re s =
  match Re.exec_opt re s with
  | None -> None
  | Some g -> ( match Re.Group.get_opt g 1 with Some "" -> None | v -> v)

(* Return the first canonical value whose regex matches. *)
let first_match table s =
  List.fold_left
    (fun acc (re, value) ->
      match acc with Some _ -> acc | None -> if has re s then Some value else None)
    None table

(* ------------------------------------------------------------------ *)
(* Normalisation of externally supplied names                          *)
(* ------------------------------------------------------------------ *)

let lower = String.lowercase_ascii

(* Strip separators so "web-dl", "web dl", "WEB.DL" compare equal. *)
let squash s =
  String.to_seq s
  |> Seq.filter (fun c ->
         match c with ' ' | '.' | '_' | '-' -> false | _ -> true)
  |> String.of_seq |> lower

let normalise_codec s =
  match squash s with
  | "x265" | "h265" | "hevc" | "hx265" | "265" -> "x265"
  | "x264" | "h264" | "avc" | "h264avc" | "264" -> "x264"
  | "av1" | "avi1" -> "AV1"
  | "vc1" -> "VC-1"
  | "mpeg2" | "mpeg2video" -> "MPEG-2"
  | "mpeg4" -> "MPEG-4"
  | "xvid" -> "XviD"
  | "divx" -> "DivX"
  | _ -> s

let normalise_source s =
  match squash s with
  | "webdl" | "web" | "webdlrip" -> "WEB-DL"
  | "webrip" -> "WEBRip"
  | "bluray" | "blurayraw" | "bdrip" | "brrip" | "bdmv" | "bd" | "bluraydisk"
  | "brdisk" ->
      "Bluray"
  | "remux" | "bdremux" | "blurayremux" -> "Remux"
  | "television" | "televisionraw" | "hdtv" | "pdtv" | "sdtv" | "tv" -> "HDTV"
  | "dvd" | "dvdrip" | "dvdr" -> "DVD"
  | "screener" | "dvdscr" | "scr" -> "Screener"
  | "cam" | "camrip" | "hdcam" -> "CAM"
  | "telesync" | "ts" | "hdts" -> "TELESYNC"
  | "unknown" | "" -> s
  | _ -> s

(* ------------------------------------------------------------------ *)
(* Individual property matchers                                        *)
(* ------------------------------------------------------------------ *)

let re_remux = rx {|remux|}

let source_table =
  [
    (tok {|web[\s._-]?dl|}, "WEB-DL");
    (tok {|web[\s._-]?rip|}, "WEBRip");
    (tok {|blu[\s._-]?ray|bd[\s._-]?rip|br[\s._-]?rip|bd(?:25|50|66|100)|bdmv|}, "Bluray");
    (tok {|web|}, "WEB-DL");
    (tok {|hdtv|pdtv|sdtv|dsr|}, "HDTV");
    (tok {|dvd[\s._-]?scr(?:eener)?|screener|}, "Screener");
    (tok {|dvd[\s._-]?rip|dvd[59]?|dvdr|}, "DVD");
    (tok {|hd[\s._-]?cam|cam[\s._-]?rip|cam|}, "CAM");
    (tok {|tele[\s._-]?sync|hd[\s._-]?ts|}, "TELESYNC");
  ]

let parse_source title =
  if has re_remux title then Some "Remux" else first_match source_table title

let codec_table =
  [
    (tokd {|x[\s._-]?265|h[\s._-]?265|hevc|}, "x265");
    (tokd {|x[\s._-]?264|h[\s._-]?264|avc|}, "x264");
    (tokd {|av1|}, "AV1");
    (tokd {|vc[\s._-]?1|}, "VC-1");
    (tokd {|mpeg[\s._-]?2|}, "MPEG-2");
    (tokd {|xvid|}, "XviD");
    (tokd {|divx|}, "DivX");
  ]

let parse_codec title = first_match codec_table title

let audio_table =
  [
    (lead {|atmos|}, "Atmos");
    (lead {|dts[\s._-]?x|}, "DTS-X");
    (lead {|true[\s._-]?hd|}, "TrueHD");
    (lead {|dts[\s._-]?hd[\s._-]?ma|}, "DTS-HD MA");
    (lead {|dts[\s._-]?hd|}, "DTS-HD");
    (lead {|dts[\s._-]?es|}, "DTS-ES");
    (tokd {|dts|}, "DTS");
    (tokd {|flac|}, "FLAC");
    (tokd {|lpcm|pcm|}, "PCM");
    (lead {|ddp|dd\+|eac3|e[\s._-]ac[\s._-]3|ddplus|}, "DDP");
    (tokd {|dd|ac3|}, "DD");
    (tokd {|aac|}, "AAC");
    (tokd {|opus|}, "Opus");
    (tokd {|mp3|}, "MP3");
  ]

let parse_audio title = first_match audio_table title

(* Channel layouts such as 7.1, 5.1, 2.0.  The surrounding non-digit
   requirement keeps "H.264" and years out of the match. *)
let re_channels = rx {|(?:^|[^0-9])([1-9])\.([0-2])(?:$|[^0-9])|}

let parse_channels title =
  match Re.exec_opt re_channels title with
  | None -> None
  | Some g -> (
      match (Re.Group.get_opt g 1, Re.Group.get_opt g 2) with
      | Some a, Some b -> Some (a ^ "." ^ b)
      | _ -> None)

let re_hdr10plus =
  lead {|hdr[\s._-]?10[\s._-]?(?:\+|plus|p(?:$|[\s._\-\[\]()]))|}
let re_hdr10 = tokd {|hdr[\s._-]?10|}
let re_hlg = tok {|hlg|}
let re_hdr = tok {|hdr|}

let parse_hdr title =
  (* HDR10+ carries an HDR10 base layer, so report both. *)
  if has re_hdr10plus title then [ "HDR10+"; "HDR10" ]
  else
    let base = if has re_hdr10 title then [ "HDR10" ] else [] in
    let base = if has re_hlg title then base @ [ "HLG" ] else base in
    if base = [] && has re_hdr title then [ "HDR" ] else base

let re_dv = tok {|dv|dovi|do[\s._-]?vi|dolby[\s._-]?vision|dolbyvision|}

let re_dv_profile =
  rx
    {|(?:dv|dovi|dolby[\s._-]?vision)[\s._-]?(?:profile[\s._-]?|p[\s._-]?)([578])(?:$|[\s._\-\[\]()])|}

let re_profile_word = rx {|profile[\s._-]?([578])|}
let re_dvhe = rx {|dvh[ec][\s._-]?0?([578])|}

(* A "dvhe.05" / "dvh1.08" codec tag is itself proof of Dolby Vision, whereas a
   bare "profile 8" is not. *)
let parse_dolby_vision title = has re_dv title || has re_dvhe title

let parse_dv_profile title =
  let pick re = capture re title in
  match pick re_dvhe with
  | Some d -> Some ("P" ^ d)
  | None -> (
      match pick re_dv_profile with
      | Some d -> Some ("P" ^ d)
      | None -> ( match pick re_profile_word with Some d -> Some ("P" ^ d) | None -> None))

let resolution_table =
  [
    (tokd {|2160p?|4320p?|4k|uhd|3840[\s._-]?x[\s._-]?2160|}, 2160);
    (tokd {|1080[pi]|1920[\s._-]?x[\s._-]?1080|}, 1080);
    (tokd {|720p?|1280[\s._-]?x[\s._-]?720|}, 720);
    (tokd {|576[pi]|}, 576);
    (tokd {|480[pi]|848[\s._-]?x[\s._-]?480|}, 480);
  ]

let parse_resolution title =
  List.fold_left
    (fun acc (re, value) ->
      match acc with Some _ -> acc | None -> if has re title then Some value else None)
    None resolution_table

let re_repack = tokd {|repack|}
let re_proper = tokd {|proper|}
let re_bit10 = rx {|(?:10[\s._-]?bits?|hi10p?)|}
let re_bit8 = rx {|8[\s._-]?bits?|}

let parse_bit_depth title =
  if has re_bit10 title then Some 10 else if has re_bit8 title then Some 8 else None

let language_table =
  [
    (tok {|multi|multi\d?|}, "MULTi");
    (tok {|dual[\s._-]?audio|dual|}, "DUAL");
    (tok {|german|deutsch|}, "GERMAN");
    (tok {|french|truefrench|vff|vfq|vostfr|}, "FRENCH");
    (tok {|spanish|castellano|espanol|}, "SPANISH");
    (tok {|latino|}, "LATINO");
    (tok {|italian|ita|}, "ITALIAN");
    (tok {|dutch|nl|}, "DUTCH");
    (tok {|nordic|}, "NORDIC");
    (tok {|swedish|}, "SWEDISH");
    (tok {|danish|}, "DANISH");
    (tok {|norwegian|}, "NORWEGIAN");
    (tok {|finnish|}, "FINNISH");
    (tok {|polish|pldub|}, "POLISH");
    (tok {|czech|}, "CZECH");
    (tok {|hungarian|}, "HUNGARIAN");
    (tok {|russian|rus|}, "RUSSIAN");
    (tok {|ukrainian|}, "UKRAINIAN");
    (tok {|portuguese|}, "PORTUGUESE");
    (tok {|japanese|jpn|}, "JAPANESE");
    (tok {|korean|kor|}, "KOREAN");
    (tok {|chinese|mandarin|cantonese|}, "CHINESE");
    (tok {|hindi|}, "HINDI");
    (tok {|tamil|}, "TAMIL");
    (tok {|telugu|}, "TELUGU");
    (tok {|turkish|}, "TURKISH");
    (tok {|thai|}, "THAI");
    (tok {|arabic|}, "ARABIC");
    (tok {|hebrew|}, "HEBREW");
    (tok {|greek|}, "GREEK");
    (tok {|romanian|}, "ROMANIAN");
    (tok {|bulgarian|}, "BULGARIAN");
    (tok {|english|eng|}, "ENGLISH");
    (tok {|subbed|}, "SUBBED");
    (tok {|dubbed|}, "DUBBED");
  ]

let parse_languages title =
  List.filter_map (fun (re, name) -> if has re title then Some name else None) language_table
  |> List.sort_uniq compare

(* ------------------------------------------------------------------ *)
(* Release group                                                       *)
(* ------------------------------------------------------------------ *)

let re_extension = rx {|\.(mkv|mp4|avi|ts|m2ts|iso|img|wmv|mov|m4v)$|}

let strip_extension title =
  match Re.exec_opt re_extension title with
  | None -> title
  | Some g ->
      let start, _ = Re.Group.offset g 0 in
      String.sub title 0 start

(* Tokens that look like a group but are really format markers. *)
let non_group_tokens =
  [
    "dl"; "hd"; "ma"; "ray"; "rip"; "es"; "ex"; "x"; "sd"; "uhd"; "264"; "265";
    "dts"; "dd"; "ddp"; "ac3"; "eac3"; "aac"; "flac"; "opus"; "mp3"; "pcm";
    "atmos"; "truehd"; "hdr"; "hdr10"; "plus"; "dv"; "dovi"; "hevc"; "avc";
    "av1"; "xvid"; "divx"; "remux"; "bluray"; "blu"; "web"; "webrip"; "webdl";
    "hdtv"; "dvd"; "cam"; "proper"; "repack"; "internal"; "limited"; "extended";
    "unrated"; "uncut"; "imax"; "directors"; "cut"; "theatrical"; "multi";
    "dual"; "subs"; "sub"; "10bit"; "8bit"; "obfuscated"; "scene"; "nogrp";
    "rerip"; "final"; "complete"; "season"; "part"; "vostfr"; "ita"; "eng";
  ]

let is_digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

let is_hex_hash s =
  String.length s >= 6
  && String.for_all
       (fun c ->
         (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
       s

let valid_group candidate =
  let c = String.trim candidate in
  let l = lower c in
  String.length c >= 2 && String.length c <= 25
  && (not (is_digits c))
  && (not (List.mem l non_group_tokens))
  && (not (String.contains c ' '))
  && (* a bare resolution/codec token left over from something like
        "WEB-DL" is not a group *)
  not (has (rx {|^(?:1080[pi]|720p|2160p|480[pi]|576[pi])$|}) c)

(* Cut a candidate at the first character that cannot be part of a group. *)
let cut_candidate s =
  let stop = [ ' '; '['; '('; '{'; '<' ] in
  let rec go i = if i >= String.length s || List.mem s.[i] stop then i else go (i + 1) in
  String.sub s 0 (go 0)

(* Scene style: the text after the last '-' that is glued to both sides. *)
let trailing_dash_group title =
  let n = String.length title in
  let is_space c = c = ' ' || c = '\t' in
  let rec scan i =
    if i <= 0 then None
    else if
      title.[i] = '-' && i > 0
      && (not (is_space title.[i - 1]))
      && i + 1 < n
      && not (is_space title.[i + 1])
    then
      let candidate = cut_candidate (String.sub title (i + 1) (n - i - 1)) in
      if valid_group candidate then Some candidate else None
    else scan (i - 1)
  in
  scan (n - 1)

(* Anime style: "[Group] Title - 05 (1080p)". *)
let leading_bracket_group title =
  let t = String.trim title in
  if String.length t < 3 || t.[0] <> '[' then None
  else
    match String.index_opt t ']' with
    | None -> None
    | Some j ->
        let candidate = String.sub t 1 (j - 1) in
        if valid_group candidate && not (is_hex_hash candidate) then Some candidate
        else None

let parse_release_group title =
  let t = strip_extension (String.trim title) in
  match leading_bracket_group t with
  | Some g -> Some g
  | None -> trailing_dash_group t

(* ------------------------------------------------------------------ *)
(* Entry point                                                         *)
(* ------------------------------------------------------------------ *)

let parse title =
  if String.trim title = "" then empty
  else
    {
      source = parse_source title;
      codec = parse_codec title;
      audio = parse_audio title;
      audio_channels = parse_channels title;
      hdr = parse_hdr title;
      dolby_vision = parse_dolby_vision title;
      dv_profile = parse_dv_profile title;
      resolution = parse_resolution title;
      release_group = parse_release_group title;
      is_repack = has re_repack title;
      is_proper = has re_proper title;
      languages = parse_languages title;
      bit_depth = parse_bit_depth title;
    }
