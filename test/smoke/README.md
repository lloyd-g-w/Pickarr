# Manual smoke tests

Not part of `dune test`: these drive the **real** binary against fake Sonarr,
Radarr, Seerr and LLM servers, and check the browser UI with a DOM stub. They
need `python3` and `node`, and they bind ports 19100-19299 on loopback.

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

## UI

```bash
# the Select page renders real payloads and awkward shapes without throwing
node test/smoke/render_selection.js /tmp/grabbug-last-preview-sonarr.json

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
