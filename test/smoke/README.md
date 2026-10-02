# Manual smoke tests

Not part of `dune test`: these drive the **real** binary against fake Sonarr,
Radarr, Seerr and LLM servers, and check the browser UI with a DOM stub. They
need `python3` and `node`, and they bind ports 19100-19521 on loopback.

Build first, from the repository root, and run them from anywhere — each
script resolves the repository from its own location:

```bash
dune build
```

## Selection and grabbing

```bash
# select + grab against fake *arr instances; grab-mode chooses what
# POST /api/v3/release answers: echo | nulls | empty | text | notfound | conflict
bash test/smoke/select_grab_e2e.sh echo
```

Asserts the four select routes, the grab bodies Sonarr/Radarr receive, the
AI and deterministic-fallback paths, grab-by-release-id (including that a
hard-rejected release is refused), and that no failure mode answers 5xx.
See `docs/GRAB_BUG_NOTES.md`.

## Every path a grab can take

```bash
bash test/smoke/grab_paths_e2e.sh
```

Eleven scenarios against a scriptable fake (`fake_grab_arr.py`): a direct
grab; a cache miss that is recovered by searching again; a cache miss where
the release is really gone; Sonarr and Radarr demanding `shouldOverride` (with
the exact override body asserted); a release with `indexerId: 0` refused
before any POST; a download-queue warning surfaced after a successful grab; a
409 that must not be retried; a hard-rejected release still refused; an
unknown release id answering 404; and the flaky-indexer case that used to
break the Grab button. See `docs/GRAB_BUG_NOTES.md`.

## AI selection with magnet-link guids

```bash
bash test/smoke/llm_e2e.sh
```

Reproduces the reported "AI unavailable, used deterministic scoring: invalid
response: ranking contains unknown release id "magnet:?xt=urn:btih:…"" against
a fake Sonarr whose guids are 200-320 character magnet links. Asserts that the
prompt contains no guid/URL/magnet/info hash and uses `r1..rN` ids, that a
clean answer selects the real release, that a mangled magnet id in the ranking
is dropped with a visible note instead of losing the AI pick, that a title or
`#2` as the id still resolves, that `confidence: 85` is read as `0.85`, that
prose and truncated answers fall back to deterministic scoring, and that the
grab still carries the full magnet guid.

## Seasons and whole series

```bash
bash test/smoke/seasons_e2e.sh
```

Prints what each step produced (season overview, one pack selection, a whole
series, the pack/episode policy at three thresholds, the pack-unavailable
fallback, and the error responses of the season routes) against
`fake_sonarr_seasons.py`, whose series 12 has season 1 missing 1 of 4 and
season 2 missing 2 of 2. Read the output; it exits non-zero only if a step
crashes.

## Library browsing and open-in links

```bash
bash test/smoke/library_e2e.sh
```

Serves two fake *arr instances with a browsable library
(`fake_library_arr.py`) and asserts the Search page's flow: searching by name,
by alternate title, by *arr id, TMDB id, TheTVDB id and `tt…` IMDb id; the
season list of a picked series (specials dropped, monitored-only missing
counts); a season's episodes; a picked movie's card; the error codes; a
search + grab through the picked item; that the Sonarr/Radarr/Seerr links
appear in the search results, the selection result and the history entry; and
that repeated searches reuse the cached library listing.

## Seerr: movie requests

```bash
bash test/smoke/seerr_e2e.sh
```

Asserts the connection test, the request list with looked-up titles, the dry
run (search but no grab), 4K routing to the "Radarr 4K" instance, that an
already-available request is never touched, auto-approval, an explicit
*Fulfil now* grab with a `{guid, indexerId, movieId}` body, declining, and
the poller status.

## Seerr: TV requests use season packs

```bash
bash test/smoke/seerr_tv_e2e.sh
```

An approved request for one season must resolve the series by TheTVDB id and
be satisfied by a **single season pack**: it asserts the
`GET /api/v3/series?tvdbId=` lookup, the season-pack search, that no
per-episode search was needed, exactly one grab with a
`{guid, indexerId, seriesId}` body, and that the pass summary and
`/api/seerr/status` carry the per-season outcome the Requests tab shows.

## Seerr: working a request like the Search page

```bash
bash test/smoke/seerr_ux_e2e.sh
```

Asserts the two routes the Requests tab drives: `resolve` (a movie request
maps to its Radarr movie id, a TV request to the series id plus the requested
seasons with missing/total, and neither searches nor grabs), `select` with
`grab:false` (candidates, `grabbed:false`, no `POST /api/v3/release`), with
`grab:true` (one grab, correct body), a pending request refused with 409 and
accepted with `approve:true` (approved in Seerr first), one season selected as
a pack, the whole request as a series run, the new season grab route, and that
a non-pack release is refused with 409.

## Release-search timeout

```bash
bash test/smoke/timeout_e2e.sh
```

Reproduces the reported `HTTP 502 - Radarr: release search failed ...
timed out after 30s (.../api/v3/release?movieId=440)` against a Radarr whose
interactive search sleeps, and asserts the two-timeout fix: the configured
values are stored and clamped, a quick call is unaffected by a short read
timeout, a 2 s search succeeds under a 10 s search timeout, an 8 s search
fails under a 5 s one with a 502 naming
`network.arr_search_timeout_seconds`, and raising the setting fixes it
without restarting. Takes about 20 s, most of it deliberate waiting.

## UI

```bash
# the Search page renders real payloads and awkward shapes without throwing
# (runs standalone; pass a saved payload to render that instead)
node test/smoke/render_selection.js /tmp/grabbug-last-preview-sonarr.json

# the Requests tab's per-request panel renders (uses the payloads
# seerr_ux_e2e.sh leaves in /tmp, or built-in samples)
node test/smoke/render_seerr_panel.js

# every element id app.js reaches for exists in index.html
node test/smoke/check_element_ids.js
```

## Fakes

| File | Serves |
| --- | --- |
| `fake_arr.py` | Sonarr/Radarr for `select_grab_e2e.sh` (configurable grab response) |
| `fake_sonarr_seasons.py` | Sonarr with seasons, `?tvdbId=` lookup, pack and episode searches, recorded grabs at `/__grabs` |
| `fake_seerr.py` | Seerr `/api/v1`; `FAKE_SEERR_MODE=tv` serves one approved TV request instead of the movie ones |
| `fake_radarr_seerr.py` | Radarr for the Seerr tests, recording searches and grabs to a JSON state file |
| `fake_sonarr_magnet.py` | Sonarr whose releases have magnet-link guids (`fixtures/sonarr_releases_magnet.json`) |
| `fake_llm.py` | OpenAI-compatible server answering `short`, `mangled`, `titles`, `percent`, `prose` or `truncated` |
| `fake_slow_radarr.py` | Radarr whose `GET /api/v3/release` sleeps; the delay is changeable at `/__delay?seconds=`, calls recorded at `/__state` |

## Queue integration

```bash
bash test/smoke/queue_integration_e2e.sh
```

Ports 19650-19699. Fake Sonarr (`fake_arr.py`) plus a slow fake Radarr
(`fake_slow_radarr.py`, 2 s per search). Asserts that the action endpoints
answer exactly as before while running as queue jobs (search, grab_release,
grab_best, the error statuses 400/404, the passes), that two identical
concurrent searches share one job (one release search for both), that a
Radarr webhook queues a job that searches, and that the work emits the
expected events (`auth.login`, `config.updated` without secrets,
`instance.tested`, `search.*` and `grab.*` tagged with their job,
`automatic.pass`, `seerr.pass`, `webhook.received`). Events come from
`GET /api/events` when present, else from the stub module's
`PICKARR_STUB_EVENTS_LOG` file.
