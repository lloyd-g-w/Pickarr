# "Select and grab doesn't work" — investigation notes

Reported symptom: pressing *Preview* or *Select & grab* on the Select page did
nothing useful. No error text was supplied.

Method: read the whole path (UI → routes → selection → arr client → HTTP),
then run the **real binary** against a fake Sonarr and a fake Radarr and
assert on what the fakes received. The harnesses are committed under
`test/smoke/` (see `test/smoke/README.md`); they are not part of `dune test`
because they start processes and bind ports 19100-19108.

## Summary

The selection pipeline and all four select routes work; the most likely cause
of the original report was the DNS/service-resolution defect fixed in
`60b2eaf` ("resolution failed: unknown scheme"), which made **every** outbound
Sonarr/Radarr call fail inside the slim Docker image — the same defect that
broke the instance *Test* button at the same time. Selecting could not work
before that fix, because stage 1 (search releases) never completed.

Two genuine defects remained and are fixed here, plus the missing
per-candidate grab that the *arr release cache makes necessary.

| # | Severity | Defect | Fix |
|---|----------|--------|-----|
| 1 | real bug | A 2xx response with a body that is not JSON made a *successful* grab report as failed (`invalid response: unexpected body from …`) | `Http.post_unit`: for grabs any 2xx counts as success; the body is not parsed |
| 2 | cosmetic bug | `decode_body` put the *parser error message* where the caller documents the *body*, producing `unexpected body …: Line 1, bytes 0-15:` | include the truncated body and the parse error |
| 3 | missing feature | Only the winner could be grabbed. Sonarr/Radarr only accept a grab for a release from the **last** search (30-minute cache keyed on `indexerId_guid`), so "grab that other one" needs a server round trip that re-searches | `POST /api/grab/:instance_id/:media_id {"release_id"}` + a **Grab** button on every candidate row |
| 4 | usability | The UI status line showed only the error text, so a 404/502 looked the same as a validation error | status line now shows `HTTP <status> · <server message>` |

## What was verified as working (evidence)

`bash test/smoke/select_grab_e2e.sh <mode>` → `E2E RESULT: all checks passed`
for every mode (`echo`, `nulls`, `empty`, `text`, `notfound`, `conflict`)
after the fixes below. The mode decides what the fake `POST /api/v3/release`
answers; the success modes must grab, the failure modes must report
`grabbed:false` with a `grab_error` and never a 5xx:

* Route order in `lib/server/routes.ml` is correct. `/select/radarr/movie/:id`
  and `/select/sonarr/episode/:id` are registered **before**
  `/select/:instance_id/:media_id`, and they cannot collide anyway: Dream
  matches on segment count (4 vs 3 segments after `/api`). Verified live:
  `POST /api/select/sonarr/episode/5150` and `POST /api/select/sonarr/5150`
  both return 200 and both grab.
* `Selection.options_of_json`: `{"grab":true}`, `{"grab":"true"}`, an empty
  body plus `?grab=true`, and `{}` all parse; `{"grab":"maybe"}` → 400.
* Grab bodies match the verified API (`docs/API_RESEARCH.md` §3.4 and
  `vendor/{sonarr,radarr}-ReleaseController.cs`, cache key
  `string.Concat(IndexerId, "_", Guid)`, 30-minute TTL):
  * Sonarr `{"guid":"…","indexerId":4,"episodeId":5150}`
  * Radarr `{"guid":"…","indexerId":2,"movieId":77}`
* Failure modes never 500 and always surface a reason:
  * 404 `Couldn't find requested release in cache, try searching again` →
    `grabbed:false`, `grab_error:"HTTP 404: Couldn't find requested release in cache, try searching again"`
  * 409 → `grabbed:false`, `grab_error:"HTTP 409: Unable to add release"`
  * empty 200 body → `grabbed:true` (decodes as `` `Null ``)
  * a 200 `ReleaseResource` full of nulls → `grabbed:true`
* AI enabled with the LLM unreachable → `method.kind =
  "deterministic_fallback"`, `llm_error` recorded, and the winner is **still
  grabbed**.
* AI enabled with a working LLM (a fake LLM that returns valid strict JSON) → `method.kind = "llm"`,
  confidence 0.93, the model's `influences` become the explanation, and the
  pick is grabbed (one `POST /api/v3/release`).
* Bad input: unknown instance → 404, non-numeric media id → 400.
* Grab-by-id refuses a release the hard rules rejected
  (a hard-rejected fixture release): HTTP 409 with the reasons, and **zero**
  `POST /api/v3/release` calls — deterministic rejections still outrank a
  manual pick. Empty/missing `release_id` → 400, unknown instance → 404,
  unknown id → 404.

## UI checks

* `node --check static/app.js` → clean.
* Every `$("#id")`/`getElementById` id referenced by `app.js` exists in
  `index.html` (48 referenced, 68 defined, 0 missing, 0 duplicates) —
  `test/smoke/check_element_ids.js`.
* `renderSelectionResult` survives real payloads and the awkward shapes
  (`selected:null`, empty `candidates`, missing optional fields, `grab_error`
  set) — `test/smoke/render_selection.js`. `el()` flattens arrays, so the
  `["Score","Title",…].map(...)` table headers are fine.
* The Select page's instance dropdown is filled from `state.config.instances`
  filtered on `enabled`, both in `loadConfig()` (page load) and in
  `saveConfigPatch()` (after saving instances, no reload needed).

Two UI traps that are *not* bugs but do look like "it doesn't work", now
addressed by better text/affordances:

* **Sonarr needs an *episode* id**, which Sonarr's own UI never shows. Typing
  a series id gives `404 could not load media <id>`. Use *Pick from wanted
  items*, which fills the field.
* If the instance dropdown is empty (no enabled instance) the buttons only
  toast "Configure an instance first".

## New endpoint

```
POST /api/grab/:instance_id/:media_id   {"release_id": "<release id>"}
```

Re-runs the search for that media item, matches `release.id` (the release's
`guid`, or a digest of title+indexer when the guid is absent), grabs it and
returns the usual selection-result payload with `selected` set to the release
the caller asked for. Status codes: 200, 400 (bad `release_id`/media id), 404
(unknown instance, media or release), 409 (release is hard-rejected), 502
(instance unreachable).

## Tests added

* `test/arr/test_arr.ml` "grab response handling" \u2014 serves 201-echo, 200-nulls,
  200-empty, 200-plain-text, 202, 404 and 409 from a throwaway loopback socket
  and asserts success/failure plus the preserved *arr message.
* `test/server/test_server.ml` "release id parsing" \u2014 `release_id_of_json`
  accepts a guid-shaped id, trims it, tolerates extra fields and rejects
  `{}`, `""`, whitespace, non-strings, `null`, arrays and a bare string.

## Residual, by design

* A grab can still legitimately fail with 404 *not in cache* if more than 30
  minutes pass between the search and the grab. `POST /api/grab/...` always
  re-searches first, so the UI button cannot hit that window.
* `Digest`-based release ids (used when a release has no `guid`) are stable
  across searches, so grab-by-id works for those too — but such a release has
  no guid to grab with and is rejected up front with
  `"has no guid, so Sonarr/Radarr cannot grab it"`.
