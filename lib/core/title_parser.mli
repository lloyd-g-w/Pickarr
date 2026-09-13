(** Best-effort parser for scene / p2p release titles.

    Sonarr and Radarr expose a quality model ({e source}, {e resolution},
    {e modifier}) but they do not tell us the video codec, the audio format,
    the HDR flavour or the Dolby Vision profile of a release.  Those have to
    be recovered from the release title, which is what this module does.

    The parser is pure, total (it never raises) and deliberately conservative:
    when a property cannot be identified with reasonable confidence the
    corresponding field is [None] / [[]] / [false] rather than a guess. *)

type parsed = {
  source : string option;
      (** Normalised source, highest specificity first: ["Remux"],
          ["Bluray"], ["WEB-DL"], ["WEBRip"], ["HDTV"], ["DVD"],
          ["Screener"], ["CAM"], ["TELESYNC"]. *)
  codec : string option;
      (** Normalised video codec: ["x264"], ["x265"], ["AV1"], ["VC-1"],
          ["MPEG-2"], ["XviD"], ["DivX"]. *)
  audio : string option;
      (** Normalised audio format, most specific first: ["Atmos"],
          ["DTS-X"], ["TrueHD"], ["DTS-HD MA"], ["DTS-HD"], ["DTS-ES"],
          ["DTS"], ["FLAC"], ["PCM"], ["DDP"], ["DD"], ["AAC"], ["Opus"],
          ["MP3"]. *)
  audio_channels : string option;  (** ["7.1"], ["5.1"], ["2.0"], ... *)
  hdr : string list;
      (** Subset of [["HDR10+"; "HDR10"; "HLG"; "HDR"]].  A title tagged
          [HDR10+] yields [["HDR10+"; "HDR10"]] because HDR10+ streams carry
          an HDR10 base layer; this keeps "does it have an HDR10 fallback"
          checks a simple [List.mem "HDR10"]. *)
  dolby_vision : bool;
  dv_profile : string option;
      (** ["P5"], ["P7"] or ["P8"] when the profile is stated in the title
          (["DV.P8"], ["Profile 8"], ["dvhe.05"]...).  [None] otherwise:
          absence of a profile does {e not} mean the release is DV-free. *)
  resolution : int option;  (** 480, 576, 720, 1080 or 2160. *)
  release_group : string option;
      (** Trailing [-GROUP] for scene/p2p names, or the leading [\[Group\]]
          tag used by anime releases. *)
  is_repack : bool;
  is_proper : bool;
  languages : string list;
      (** Language / dub markers found in the title, e.g. ["MULTi"],
          ["DUAL"], ["GERMAN"], ["FRENCH"].  Sonarr/Radarr report languages
          separately; this is only a fallback. *)
  bit_depth : int option;  (** 8 or 10 when the title says so. *)
}

val empty : parsed
(** A [parsed] value with every field unset.  Useful as a mapping fallback. *)

val parse : string -> parsed
(** [parse title] extracts everything it can from a release title.  Never
    raises. *)

val normalise_codec : string -> string
(** Canonicalise a codec name: ["hevc"], ["h265"], ["h.265"], ["x265"] all
    become ["x265"]; ["h264"], ["avc"] become ["x264"]; ["av1"] becomes
    ["AV1"].  Unrecognised input is returned unchanged. *)

val normalise_source : string -> string
(** Canonicalise a source name, including the Sonarr/Radarr [QualitySource]
    enum values: ["webdl"], ["web-dl"], ["web"] become ["WEB-DL"];
    ["webrip"] becomes ["WEBRip"]; ["bluray"], ["blurayRaw"], ["bdrip"],
    ["brrip"] become ["Bluray"]; ["remux"] becomes ["Remux"];
    ["television"], ["televisionRaw"] become ["HDTV"].  Unrecognised input is
    returned unchanged. *)
