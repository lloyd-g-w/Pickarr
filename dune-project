(lang dune 3.0)
(name selectarr)
(generate_opam_files true)

(package
 (name selectarr)
 (synopsis "AI-assisted release selector sidecar for Sonarr and Radarr")
 (description
  "Selectarr asks Sonarr/Radarr for candidate releases, applies deterministic hard rules and scoring, optionally asks an OpenAI-compatible LLM to make the final pick, and then tells Sonarr/Radarr to grab it.")
 (depends
  (ocaml (>= 5.1))
  dune
  dream
  lwt
  lwt_ppx
  yojson
  cohttp-lwt-unix
  ptime
  logs
  fmt
  uri
  re
  digestif
  (alcotest :with-test)))
