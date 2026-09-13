(* Tests for Selectarr_core.Title_parser. *)

module TP = Selectarr_core.Title_parser

let opt_string = Alcotest.(check (option string))
let opt_int = Alcotest.(check (option int))
let strings = Alcotest.(check (list string))

let remux_4k = "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-GROUP"
let webdl_1080 = "Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-NTb"
let webrip_x265 = "Show.S01E02.1080p.AMZN.WEBRip.x265-FLUX"
let bluray_x264 = "Movie.1999.1080p.BluRay.x264.DTS-HD.MA.5.1-FGT"
let webdl_dv_plus = "Movie.2023.2160p.WEB-DL.DV.HDR10+.HEVC.DDP5.1.Atmos-FLUX"
let anime = "[SubsPlease] Anime - 05 (1080p) [ABCDEF12].mkv"
let multi_bluray = "Movie 2020 MULTi 1080p BluRay x264-GROUP"
let season_pack = "Show.S01.1080p.WEB.H264-GROUP"

let test_remux () =
  let p = TP.parse remux_4k in
  opt_string "source" (Some "Remux") p.TP.source;
  opt_string "codec" (Some "x265") p.TP.codec;
  opt_string "audio" (Some "Atmos") p.TP.audio;
  opt_string "channels" (Some "7.1") p.TP.audio_channels;
  strings "hdr" [ "HDR10" ] p.TP.hdr;
  Alcotest.(check bool) "dv" true p.TP.dolby_vision;
  opt_int "resolution" (Some 2160) p.TP.resolution;
  opt_string "group" (Some "GROUP") p.TP.release_group

let test_web_dl () =
  let p = TP.parse webdl_1080 in
  opt_string "source" (Some "WEB-DL") p.TP.source;
  opt_string "codec" (Some "x264") p.TP.codec;
  opt_string "audio" (Some "DDP") p.TP.audio;
  opt_string "channels" (Some "5.1") p.TP.audio_channels;
  opt_int "resolution" (Some 1080) p.TP.resolution;
  opt_string "group" (Some "NTb") p.TP.release_group;
  Alcotest.(check bool) "no dv" false p.TP.dolby_vision;
  strings "no hdr" [] p.TP.hdr

let test_webrip () =
  let p = TP.parse webrip_x265 in
  opt_string "source" (Some "WEBRip") p.TP.source;
  opt_string "codec" (Some "x265") p.TP.codec;
  opt_string "group" (Some "FLUX") p.TP.release_group

let test_bluray () =
  let p = TP.parse bluray_x264 in
  opt_string "source" (Some "Bluray") p.TP.source;
  opt_string "codec" (Some "x264") p.TP.codec;
  opt_string "audio" (Some "DTS-HD MA") p.TP.audio;
  opt_string "channels" (Some "5.1") p.TP.audio_channels;
  opt_string "group" (Some "FGT") p.TP.release_group

let test_hdr10_plus_implies_hdr10 () =
  let p = TP.parse webdl_dv_plus in
  strings "hdr" [ "HDR10+"; "HDR10" ] p.TP.hdr;
  Alcotest.(check bool) "dv" true p.TP.dolby_vision;
  opt_string "source" (Some "WEB-DL") p.TP.source;
  opt_string "codec" (Some "x265") p.TP.codec;
  opt_string "group" (Some "FLUX") p.TP.release_group

let test_anime_bracket_group () =
  let p = TP.parse anime in
  opt_string "group" (Some "SubsPlease") p.TP.release_group;
  opt_int "resolution" (Some 1080) p.TP.resolution

let test_space_separated () =
  let p = TP.parse multi_bluray in
  opt_string "source" (Some "Bluray") p.TP.source;
  opt_string "group" (Some "GROUP") p.TP.release_group;
  strings "languages" [ "MULTi" ] p.TP.languages

let test_season_pack_bare_web () =
  let p = TP.parse season_pack in
  opt_string "source" (Some "WEB-DL") p.TP.source;
  opt_string "codec" (Some "x264") p.TP.codec;
  opt_string "group" (Some "GROUP") p.TP.release_group

let test_av1_and_bit_depth () =
  let p = TP.parse "Movie.2022.1080p.WEB-DL.AV1.10bit.Opus.5.1-NoGrp" in
  opt_string "codec" (Some "AV1") p.TP.codec;
  opt_int "bit depth" (Some 10) p.TP.bit_depth;
  opt_string "audio" (Some "Opus") p.TP.audio

let test_dv_profiles () =
  let p8 = TP.parse "Movie.2021.REPACK.2160p.BluRay.DV.P8.HDR10.x265.TrueHD.7.1.Atmos-TERM" in
  opt_string "P8" (Some "P8") p8.TP.dv_profile;
  Alcotest.(check bool) "repack" true p8.TP.is_repack;
  let p7 = TP.parse "Movie.2020.2160p.WEB.DL.DoVi.P7.HEVC.DDP.5.1-CMRG" in
  opt_string "P7" (Some "P7") p7.TP.dv_profile;
  let p5 = TP.parse "Anime.S01E01.1080p.Dual.Audio.AV1.dvhe.05.FLAC-Grp" in
  opt_string "P5" (Some "P5") p5.TP.dv_profile;
  Alcotest.(check bool) "dvhe implies dv" true p5.TP.dolby_vision;
  strings "dual audio" [ "DUAL" ] p5.TP.languages

let test_proper_and_hdtv () =
  let p = TP.parse "Show.S02E05.PROPER.720p.HDTV.x264-KILLERS[eztv]" in
  Alcotest.(check bool) "proper" true p.TP.is_proper;
  opt_string "source" (Some "HDTV") p.TP.source;
  opt_int "resolution" (Some 720) p.TP.resolution;
  opt_string "group strips trailing tag" (Some "KILLERS") p.TP.release_group

let test_no_false_group () =
  (* "WEB-DL" must not be mistaken for a group named "DL". *)
  let p = TP.parse "Movie.2024.1080p.WEB-DL" in
  opt_string "group" None p.TP.release_group;
  (* Nor "DTS-HD" for "HD". *)
  let p2 = TP.parse "Movie.2024.1080p.BluRay.x264.DTS-HD" in
  opt_string "group2" None p2.TP.release_group

let test_empty_and_junk () =
  let p = TP.parse "" in
  opt_string "source" None p.TP.source;
  opt_string "codec" None p.TP.codec;
  let p2 = TP.parse "totally unparseable" in
  opt_string "source2" None p2.TP.source;
  opt_int "resolution2" None p2.TP.resolution

let test_normalisers () =
  Alcotest.(check string) "hevc" "x265" (TP.normalise_codec "HEVC");
  Alcotest.(check string) "h.265" "x265" (TP.normalise_codec "h.265");
  Alcotest.(check string) "avc" "x264" (TP.normalise_codec "AVC");
  Alcotest.(check string) "av1" "AV1" (TP.normalise_codec "av1");
  Alcotest.(check string) "unknown codec passthrough" "wat" (TP.normalise_codec "wat");
  (* Sonarr QualitySource values *)
  Alcotest.(check string) "web" "WEB-DL" (TP.normalise_source "web");
  Alcotest.(check string) "webRip" "WEBRip" (TP.normalise_source "webRip");
  Alcotest.(check string) "television" "HDTV" (TP.normalise_source "television");
  Alcotest.(check string) "blurayRaw" "Bluray" (TP.normalise_source "blurayRaw");
  (* Radarr QualitySource values *)
  Alcotest.(check string) "webdl" "WEB-DL" (TP.normalise_source "webdl");
  Alcotest.(check string) "tv" "HDTV" (TP.normalise_source "tv");
  Alcotest.(check string) "bluray" "Bluray" (TP.normalise_source "bluray")

let tests =
  [
    ("remux 4k", `Quick, test_remux);
    ("web-dl", `Quick, test_web_dl);
    ("webrip", `Quick, test_webrip);
    ("bluray", `Quick, test_bluray);
    ("hdr10+ implies hdr10", `Quick, test_hdr10_plus_implies_hdr10);
    ("anime bracket group", `Quick, test_anime_bracket_group);
    ("space separated", `Quick, test_space_separated);
    ("season pack bare WEB", `Quick, test_season_pack_bare_web);
    ("av1 and bit depth", `Quick, test_av1_and_bit_depth);
    ("dolby vision profiles", `Quick, test_dv_profiles);
    ("proper and hdtv", `Quick, test_proper_and_hdtv);
    ("no false release group", `Quick, test_no_false_group);
    ("empty and junk", `Quick, test_empty_and_junk);
    ("normalisers", `Quick, test_normalisers);
  ]

let () = Alcotest.run "title_parser" [ ("title_parser", tests) ]
