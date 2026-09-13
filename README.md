# Pickarr

**AI-assisted release selection for Sonarr and Radarr.**

Pickarr is a small OCaml service that runs beside Sonarr and Radarr. It asks
them which releases are available for a movie or episode, throws away
everything that breaks your hard rules, scores what is left, optionally asks an
LLM to make the final call using preferences you wrote in plain English, and
then tells Sonarr/Radarr to grab the winner — and explains why.

It does not replace Sonarr/Radarr, and it never talks to your download client
directly.

```
                  ┌────────────────┐          ┌──────────────────┐
   Prowlarr ─────▶│     Sonarr     │◀────────▶│     Pickarr      │─────▶ OpenAI-compatible
   (indexers)     │     Radarr     │  HTTP    │     (OCaml)      │        LLM (optional)
                  └────────────────┘   API    └──────────────────┘
                          │                            │
                          ▼                     /data/config.json
                    qBittorrent                 /data/history.jsonl
                  (downloads + import)
```

| Responsibility | Owner |
| --- | --- |
| Library management, metadata, monitoring | Sonarr / Radarr |
| Indexers | Prowlarr → Sonarr / Radarr |
| Download client, importing, renaming | Sonarr / Radarr → qBittorrent |
| Which release gets grabbed, and why | **Pickarr** |

## Quick start

```bash
git clone https://github.com/lloyd-g-w/Pickarr.git && cd Pickarr
docker compose up -d
```

Open <http://localhost:8484> and create the admin account. That is the whole
installation — no environment variables are required, everything else is
configured in the UI.

The compose file stores `config.json`, `history.jsonl` and `auth.json` in
`./data`. Like the *arr images, the container honours `PUID`/`PGID` (default
`1000`/`1000`) and fixes the ownership of `/data` on start, so set them to
the user that owns your config directory (e.g. `568` on TrueNAS SCALE).

Using **Portainer**? Paste `docker-compose.portainer.yml` into a new stack —
it pulls the prebuilt `ghcr.io/lloyd-g-w/pickarr` image and needs no host
paths. See [Portainer](#portainer).

Want the whole media stack in one file? `docker-compose.full.example.yml` runs
Pickarr next to Sonarr, Radarr, Prowlarr and qBittorrent on one network, so the
instance URLs are simply `http://sonarr:8989` and `http://radarr:7878`.

## Configure

Everything below is done in the UI; `.env.example` lists the optional
environment overrides.

1. **Create the admin account.** The first page asks for a user name and
   password, like Sonarr's first run. Afterwards every page and API call needs
   a session or the API key. You can change the password, copy or regenerate
   the API key, and disable the login requirement under **Security**.
2. **Add your instances.** *Instances* → *Add Sonarr instance* /
   *Add Radarr instance*: name, URL (for example `http://sonarr:8989`) and the
   API key from the *arr's Settings → General. Save, then press **Test** — it
   reports the application name, version and instance name, or the exact
   error. Repeat for as many instances as you have (4K Radarr, Anime Sonarr,
   …), each with its own natural-language preferences.
3. **Set up the AI (optional).** *AI & Automatic*: enable AI selection, set the
   base URL of any OpenAI-compatible server, the API key if it needs one, and
   the model. Press **Test AI connection**. Without AI, Pickarr still works and
   uses deterministic scoring only.
4. **Write your preferences in plain English.** *Rules & Preferences*: the
   large **Natural language preferences** editor is the point of Pickarr. Add
   hard rules (maximum size, minimum seeders, blocked codecs/groups) for the
   things that must never happen.
5. **Search for a release.** *Search*: choose an instance, type a title into
   **Search your library** and press **Pick** on the result you want — no ids
   to look up. A movie gives you a card with **Search** and **Grab**; a series
   gives you its seasons, each with **Search**/**Grab** for a season pack and
   an **Episodes** expander for single episodes, plus tickboxes and
   **Search selected seasons** (nothing ticked = the whole series). Optionally
   add a one-off instruction first. You get the winner, the "why" bullets, the
   full candidate ranking and every rejected release with its reason. Nothing
   is grabbed until you press **Grab selected** on the result card, **Grab
   this** on any candidate row, or one of the **Grab** buttons (which search
   and grab in one go).

   The search box also takes ids, so anything you can paste works: a Sonarr
   series id, a Radarr movie id, a TMDB or TheTVDB id, or an IMDb `tt…` id.
   Every result, result card, request row and history row carries **Open in
   Sonarr/Radarr** and **Open in Seerr** links (the Seerr one appears once a
   Seerr URL is configured).
6. **Let it run by itself (optional).** Enable *automatic* on an instance and
   automatic mode under *AI & Automatic*, leaving *Actually grab* off until the
   dry-run passes look right. See [automatic mode](#automatic-mode).

For faster reactions, add a webhook in Sonarr/Radarr (Settings → Connect →
Webhook) pointing at:

```text
http://pickarr:8484/api/webhook/<instance_id>?apikey=<your-api-key>
```

`<instance_id>` is the id shown on the *Instances* tab and `<your-api-key>` is
the key from *Security* — the query parameter is needed because the *arr
webhook UI cannot send headers.

### Seerr / Overseerr / Jellyseerr

If requests come in through Seerr, point its webhook notification agent
(Settings → Notifications → Webhook) at Pickarr so an approved request is
selected within seconds instead of on the next poll:

```text
Webhook URL:          http://pickarr:8484/api/webhook/seerr
Authorization Header: <your-api-key>          (or use ?apikey=<key> in the URL)
JSON Payload:         leave the default template
Notification types:   Request Approved, Request Automatically Approved
```

Pickarr reads `media.media_type`, `media.tmdbId` / `media.tvdbId` and the
"Requested Seasons" extra, waits for Sonarr/Radarr to finish adding the item
(retrying for a few minutes), then runs a selection for the monitored, missing
movie or episodes and grabs when *Actually grab* is on. Pickarr still searches
and grabs through Sonarr/Radarr; Seerr is only a trigger. Requests for media
that already has a file are ignored.

The webhook is optional. Connecting Pickarr to the Seerr **API** as well (next
section) is what makes it watch the queue, so nothing is missed when Pickarr is
restarted or a webhook is lost.

## Seerr integration

Beyond the webhook, Pickarr can talk to the Seerr API and work the request
queue itself. On the **Requests** tab, fill in:

```text
Seerr URL        http://seerr:5055
Seerr API key    Seerr → Settings → General → API Key   (an admin key)
```

Press **Test** (it reads `GET /api/v1/status` and the request counts), then
choose what Pickarr should do every poll:

| Setting | Effect |
| --- | --- |
| Approve pending requests | Approves everything waiting for approval (`POST /request/{id}/approve`). Off by default: leave it off if you want to keep vetting requests yourself, in Seerr or from this tab. |
| Fulfil approved requests | For every approved-but-not-available request, resolves the movie/episodes in Sonarr/Radarr and runs the normal pipeline. |
| Actually grab | Off = dry run: the pass logs the release it would have grabbed. |
| Poll interval / Max requests per run | How often, and how much work one pass may create. |

Why an **admin** API key: approving or declining needs Seerr's
`MANAGE_REQUESTS` permission. If you only want fulfilment, a key without it
still works as long as *Approve pending requests* stays off.

What happens per request:

1. The request type picks the app — `movie` → Radarr, `tv` → Sonarr.
2. Among the enabled instances of that app, a 4K request prefers instances
   whose name or id contains "4k" (Seerr models 4K as a separate server;
   Pickarr has only the name to go on). A normal request prefers the others.
   With a single instance, that one is always used.
3. The media is resolved by TMDB id (Radarr) or TheTVDB id (Sonarr), and only
   **monitored, still missing** items are selected. Specials (season 0) are
   skipped. Seerr approves and pushes to the *arr asynchronously, so the
   lookup is retried (15s, then 60s) while the item is still being added.
4. **A TV request is fulfilled season by season, as a season pack.** Each
   requested season (all seasons when Seerr recorded none) goes through the
   same policy as a manual whole-series run — see
   [Seasons and whole series](#seasons-and-whole-series): a pack when enough
   of the season is missing, the missing episodes individually otherwise or
   when no acceptable pack exists. A request for one season is therefore
   normally a single grab, not one per episode. Seasons that are already
   complete are skipped.
5. Each selection goes through the usual pipeline — hard rules, deterministic
   scoring, AI if enabled — and is grabbed through Sonarr/Radarr. The
   **Requests** tab shows, per season, whether a pack was grabbed, how many
   episodes were taken instead, or why the season was skipped.

The webhook and the poller share one implementation (`lib/server/fulfil.ml`),
so a request that arrives by webhook is fulfilled exactly the same way.

A request is retried at most once every six hours, so one that nothing can be
found for does not occupy every pass. Requests whose media is already
available are never touched.

On the Requests tab, **Approve** approves in Seerr and does nothing else,
while **Approve & grab** approves and then searches and grabs straight away.

### Working a request by hand

The poller decides on its own. When you want to look first, every request row
also has **Search** and **Grab**, which open the request in a panel that works
exactly like the Search page:

1. Pickarr resolves the request against your instances *without searching* —
   the movie id for a Radarr request, or the series id and the requested
   seasons (with how many episodes each is missing) for a Sonarr one. A
   request Seerr has not pushed to the *arr yet says so instead.
2. **Search** runs the full pipeline and shows the ranked candidates, the
   rejected releases with their reasons, the explanation and the AI decision.
   Nothing is grabbed.
3. You can add an **instruction for this search** ("pick the highest quality
   regardless of size") and toggle **Use AI** for that run only. Neither is
   saved.
4. **Grab selected** takes the winner; **Grab this** on any candidate row
   takes that release instead. Hard-rejected releases are still refused.
5. For a TV request each requested season has its own *Search* and *Grab*, so
   one season can be worked on its own; running the whole request covers every
   requested season under the usual pack policy.

A request that is still pending shows **Approve & grab** (and, in the panel,
**Approve & search**): it approves in Seerr first, waits for Seerr to push the
item to Sonarr/Radarr, and then searches. Searching a pending request without
approving it is refused (HTTP 409) — Pickarr never approves anything
implicitly.

Only an actual grab starts the six-hour cooldown, so searching a request as
often as you like does not stop the poller from working on it.

Note on Seerr's own "search on add": in sidecar mode you disable automatic
search on your indexers (see [automatic mode](#automatic-mode)), so Sonarr and
Radarr will not grab anything by themselves when Seerr adds the item —
Pickarr's pass is what finds the release. Seerr's request status still tracks
the media normally: it flips to available once the download is imported.

## Features

* **Works with both** Sonarr (v4) and Radarr (v5), multiple instances of each.
* **Hard rules** enforced deterministically in OCaml: maximum/minimum size,
  minimum seeders, blocked groups/codecs/languages/HDR formats, resolution and
  protocol allow-lists, remux and Dolby Vision policy, title patterns.
* **Deterministic scoring** with fully configurable weights: Sonarr/Radarr
  custom-format score, WEB-DL vs WEBRip, Blu-ray vs web, remux, codec, release
  group, language, resolution, audio, HDR, repacks, seeders, size sanity, age.
* **Natural-language preferences**: describe what you want in prose — global,
  per instance, or just for one request — and the model applies the parts that
  are relevant to the item being evaluated.
* **Explainability**: every pick comes with a "why" list, and with the
  preferences that could *not* be honoured because a hard rule won.
* **AI is optional and never authoritative.** If the model is unreachable, or
  answers with malformed JSON, or names a release that does not exist,
  Pickarr falls back to deterministic scoring. Rejected releases are never
  sent to the model and can never be selected.
* **Manual and automatic modes**, with a dry-run default for automatic mode.
* **Season packs and whole series** for Sonarr: fill a season from one pack,
  or walk a series season by season, with a configurable "how much has to be
  missing" threshold and a per-episode fallback. See
  [Seasons and whole series](#seasons-and-whole-series).
* **A web UI** with no build step and no CDN dependencies (works offline).

## The selection pipeline

| Stage | What happens |
| --- | --- |
| 1. Retrieve | `GET /api/v3/release?episodeId=…`, `?seriesId=…&seasonNumber=…` (season packs) or `?movieId=…`, mapped into an internal `release` type (title, size, seeders, quality, source, codec, audio, HDR/DV, group, languages, custom formats, and Sonarr/Radarr's own rejections) |
| 2. Hard filtering | Deterministic OCaml rules. Every rejection carries a structured reason. The LLM never sees rejected releases and can never overturn a rejection |
| 3. Deterministic scoring | Pure, weighted, unit-tested scoring of the survivors |
| 4. AI ranking (optional) | The top N candidates plus your preferences go to an OpenAI-compatible `/chat/completions` endpoint, which must answer with strict JSON. The pick is validated against the candidates that were sent; a pick Pickarr cannot resolve falls back to stage 3 (see [what the model sees](#what-the-model-sees)) |
| 5. Grab | `POST /api/v3/release` with the chosen `guid` + `indexerId`, only when you asked for it |

### Priority order

```
1. Sonarr/Radarr hard rejection
2. Pickarr hard rules
3. Explicit structured preferences
4. Natural language preferences
5. Deterministic scoring
6. General default AI preferences
```

If you write *"I really like AV1 releases"* but AV1 is in the blocked-codec
list, AV1 is still rejected — and the UI tells you so:

```
You said you prefer AV1, but AV1 is blocked by a hard codec rule.
```

### What the model sees

Candidates are presented to the model with **short ids** — `r1`, `r2`, `r3` —
and nothing else identifies them: no guid, download URL, magnet link or info
hash. A torrent guid is frequently a magnet link of several hundred
characters, and models (small local ones especially) truncate or re-encode
them, which used to make the whole answer unusable:

```
AI unavailable, used deterministic scoring: invalid response:
ranking contains unknown release id "magnet:?xt=urn:btih:C3A8…"
```

Pickarr translates the short ids back to the real releases itself, so that
cannot happen any more. The prompt is also compact: absent fields are
omitted, each candidate carries its `deterministic_score` and
`deterministic_rank`, and the model is asked to rank at most five candidates
with one-sentence reasons.

The answer is then read leniently, because only one thing actually matters:

* **`selected_id` must resolve to a candidate.** It is matched ignoring case,
  spaces, quotes, backticks, `**bold**` and trailing punctuation, and `#2`,
  `candidate 2`, `2` and the release's exact title all resolve to `r2`. If it
  still cannot be resolved, Pickarr falls back to deterministic scoring — the
  model can never cause a release outside the candidate list, or one rejected
  by a hard rule, to be grabbed.
* **Everything else is advisory** and is repaired rather than thrown away: a
  ranking entry with an unusable id is dropped, a repeated id keeps its first
  entry, scores outside 0–100 are clamped, a missing score falls back to the
  entry's position, a missing ranking becomes the pick alone, and a
  confidence of `85` is read as `0.85`.

Every repair is shown with the result, so a sloppy model is visible instead
of silent:

```
AI response note: a ranking entry named an unknown release ("magnet:?xt=…") and was dropped
```

If the server stops mid-answer (`finish_reason=length`), Pickarr says so and
suggests raising `max_tokens` instead of reporting a confusing parse error.

**Overriding Sonarr/Radarr's own rejections.** Level 1 is a switch: the hard
rule *Respect Sonarr/Radarr rejections* (on by default). Turn it off and their
policy rejections — quality not wanted in the profile, cutoff already met,
minimum custom-format score, size limits, "waiting for a better release" —
stop being hard. The release is instead penalised in scoring (weight
`arr_rejected`, default −25), the reasons are shown in the candidate's
explanation and passed to the AI as advisory `arr_rejections`, and Pickarr
may grab it (`POST /api/v3/release` does not enforce them). Rejections that
would make the grab fail anyway — unknown series/movie, unparseable release,
blocklisted — remain hard regardless.

## Seasons and whole series

Besides a single movie or episode, Pickarr can fill a whole **season** from
one season pack, or walk a whole **series** season by season. On the *Search*
page choose *What* → *Season (pack)* or *Whole series*, enter the Sonarr
series id and press *Load seasons* to see what is missing per season, with
*Search* / *Grab* buttons per row.

A season selection searches `GET /api/v3/release?seriesId=…&seasonNumber=…`.
That search also returns single episodes, so Pickarr hard-rejects anything
that is not a pack for the requested season (rule `not_season_pack`) — they
stay visible in the *rejected* list. The winner is grabbed with
`POST /api/v3/release` carrying `guid`, `indexerId` and `seriesId`.

### Season-pack policy

*AI & Automatic → Season packs* decides when a pack is used instead of
individual episodes:

| Setting | Default | Meaning |
| --- | --- | --- |
| Prefer season packs | on | off = always select episode by episode |
| Use a pack when this much of the season is missing (%) | 50 | a pack is only tried when at least this share of the season's monitored episodes is missing, so filling one gap does not re-download the season |
| Fall back to single episodes | on | when no acceptable pack exists (or the pack grab fails), select the missing episodes individually |

The same policy drives automatic mode: wanted episodes are grouped by season,
and a season whose missing share reaches the threshold is fetched as one pack
(counting as one item for *max items per run*, with every missing episode of
that season entering the cooldown). It also drives
[Seerr](#seerr-integration) TV requests, so a requested season arrives as one
pack.

A whole-series run answers with one outcome per season:

```bash
curl -s -X POST http://localhost:8484/api/select/sonarr/series/12 \
  -H 'Content-Type: application/json' \
  -d '{"grab": true, "seasons": [2, 3]}'
```

```json
{
  "series": { "title": "Some Show", "media_kind": "series", "media_id": 12 },
  "seasons": [
    { "season_number": 2, "missing": 2, "total": 2,
      "outcome": { "kind": "pack", "selection": { "selected": { "…": "…" } } } },
    { "season_number": 3, "missing": 1, "total": 10,
      "outcome": { "kind": "episodes", "selections": [ { "…": "…" } ] } }
  ],
  "summary": { "seasons": 2, "selections": 2, "selected": 2, "grabbed": 2 }
}
```

Seasons with nothing missing are reported as
`{"kind": "skipped", "reason": "nothing missing"}`. Omit `seasons` to consider
every season; specials (season 0) are skipped unless the series has no other
season. Radarr instances have no seasons, so these endpoints answer 502 for
them.

## Natural-language preferences

A large editor on the **Rules & Preferences** page. The text is persisted and
sent with every ranking request, together with the metadata of the item being
evaluated, so conditional instructions work:

```text
Prefer reasonably sized 1080p WEB-DLs rather than huge files.
Prefer x265/HEVC when quality is comparable.
FLUX, NTb and HONE are usually good.
Avoid WEBRip if a WEB-DL exists.
For movies I care more about quality than file size.
For TV shows I would rather save space.
Avoid Dolby Vision unless there is HDR10 fallback.
I don't care much about Atmos.
For animation, AV1 is fine.
For 4K content, prefer HDR10 over Dolby Vision.
For older movies, prefer Blu-ray encodes over WEB-DL.
```

Three scopes, combined into the effective prompt:

* **Global** — `nl_preferences`, or the `NL_PREFERENCES` environment variable.
* **Per instance** — a textarea on each instance ("4K Radarr: quality matters
  much more than storage, prefer Remux"; "Anime Sonarr: prefer dual audio and
  trusted anime groups").
* **Per request** — the optional `instruction` field, which applies to that
  selection only and is never saved.

The AI request keeps the layers explicit and tells the model that
`hard_constraints` cannot be violated:

```json
{
  "hard_constraints": {},
  "structured_preferences": {},
  "natural_language_preferences": "...",
  "temporary_instruction": "...",
  "media": {},
  "candidates": []
}
```

### Convert to structured rules

The **Convert to structured rules** button asks the model to translate your
prose into structured settings (for example *"prefer x265 when quality is
similar"* → preferred codec HEVC, +15 bonus). The proposal is displayed and
**nothing is saved until you press "Apply selected"**. Natural-language
preferences are never silently turned into hard rules.

## Configuration

Everything is configurable in the UI and stored in `$DATA_DIR/config.json`.
Environment variables are applied on top of the stored file at startup, so they
always win after a restart — handy for Docker.

| Variable | Meaning |
| --- | --- |
| `SONARR_URL`, `SONARR_API_KEY` | Creates/updates the `sonarr` instance |
| `RADARR_URL`, `RADARR_API_KEY` | Creates/updates the `radarr` instance |
| `LLM_ENABLED` (`AI_SELECTION_ENABLED`) | Whether AI selection is used |
| `LLM_PROVIDER` | Free-form label, e.g. `openai-compatible`, `ollama` |
| `LLM_BASE_URL` | e.g. `https://api.openai.com/v1`, `http://ollama:11434/v1` |
| `LLM_API_KEY`, `LLM_MODEL` | Credentials and model name |
| `MAX_RELEASE_SIZE_GIB` | Hard maximum release size |
| `MIN_SEEDERS` | Hard minimum seeders (torrents) |
| `DISALLOWED_CODECS` | Comma separated, hard rule |
| `BLOCKED_RELEASE_GROUPS` | Comma separated, hard rule |
| `ALLOW_REMUX` | Hard rule |
| `PREFERRED_CODECS`, `PREFERRED_SOURCES`, `PREFERRED_RELEASE_GROUPS`, `PREFERRED_LANGUAGES` | Comma separated soft preferences |
| `HDR_PREFERENCE`, `DOLBY_VISION_PREFERENCE` | `prefer` / `neutral` / `avoid` |
| `PREFER_REMUX` | Soft preference |
| `NL_PREFERENCES` | Global natural-language preferences |
| `AUTO_MODE_ENABLED`, `AUTO_MODE_GRAB`, `AUTO_MODE_INTERVAL_SECONDS` | Automatic mode |
| `DATA_DIR` | Config + history directory (default `/data`, else `./data`) |
| `STATIC_DIR` | UI assets (default `/app/static`, else `./static`) |
| `HOST`, `PORT` | Listen address (default `0.0.0.0:8484`) |
| `LOG_LEVEL` | `debug` / `info` / `warning` / `error` |
| `PICKARR_API_KEY` | Fixed API key; otherwise one is generated on first start |
| `PICKARR_USERNAME`, `PICKARR_PASSWORD` | Login defined by the environment instead of the first-run setup |
| `PICKARR_AUTH_REQUIRED` | `false` disables the login requirement |

Structured preferences, scoring weights, the LLM settings and the automatic
mode settings all have full forms in the UI; anything not covered by an
environment variable lives there.

## Access control

Pickarr decides what your Sonarr and Radarr download, so it authenticates like
they do: a **login page** (Sonarr/Radarr's "Forms" mode) plus an **API key**.

* **First run** shows a one-time *Create admin account* page. Nothing else is
  reachable until the account exists.
* **Login** is a server-rendered form at `/login` (no JavaScript required,
  CSRF-protected) that starts a session cookie. `POST /login` also accepts
  `{"username":..., "password":...}` as JSON for scripts.
* **Passwords** are stored as PBKDF2-HMAC-SHA256 derived keys (210 000
  iterations, random 16-byte salt) in `$DATA_DIR/auth.json` — never in
  plaintext, and never in `config.json`. Comparisons are constant-time.
* **The API key** is generated on first start, shown under *Security* with
  copy and regenerate buttons, and accepted as `X-Api-Key: <key>` or
  `?apikey=<key>`. The query form exists because the *arr webhook UI cannot
  send headers.
* **Authentication required** can be switched off under *Security* (or with
  `PICKARR_AUTH_REQUIRED=false`), mirroring the *arr setting. The login page
  keeps working; everything simply stops demanding it. Pickarr warns loudly in
  the log while it is off.
* **Environment credentials**: `PICKARR_USERNAME` / `PICKARR_PASSWORD` define
  the login without writing `auth.json`, for immutable deployments. They take
  precedence over the stored account and cannot be changed from the UI.

Unauthenticated browser requests are redirected to `/login` (or `/setup`);
unauthenticated API requests get `401 {"error":"unauthorized"}`. `/health`,
`/login`, `/logout`, `/setup`, `/static/*` and `GET /api/auth/status` are
always reachable; `POST /api/webhook/:instance_id` authenticates with the API
key in its URL.

## API

All endpoints answer JSON. Errors are `{"error": "..."}` with 400 for bad
input, 404 for an unknown instance or media id, 502 when Sonarr/Radarr or the
LLM fails, and 500 for anything unexpected.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Liveness (never requires authentication) |
| GET | `/api/auth/status` | Whether auth is required/configured and whether this caller is authenticated |
| GET, POST | `/setup` | First-run account creation page and form |
| GET, POST | `/login` | Login page and form (POST also accepts JSON) |
| POST | `/logout` | End the session |
| GET | `/api/security` | User name, API key and the auth-required flag |
| POST | `/api/security/credentials` | Change user name/password (needs `current_password`) |
| POST | `/api/security/apikey` | Regenerate the API key |
| POST | `/api/security/auth-required` | Enable/disable the login requirement |
| GET | `/api/status` | Version, uptime, instance count, AI/automatic state |
| GET | `/api/config` | Current configuration, secrets redacted |
| PUT | `/api/config` | Full or partial configuration update |
| GET | `/api/instances` | Configured instances |
| POST | `/api/instances/:id/test` | Test an instance connection |
| POST | `/api/llm/test` | Test the LLM connection |
| POST | `/api/select/radarr/movie/:id` | Select for the default Radarr instance |
| POST | `/api/select/sonarr/episode/:id` | Select for the default Sonarr instance |
| POST | `/api/select/:instance_id/:media_id` | Select on a specific instance |
| POST | `/api/select/sonarr/season/:series_id/:season_number` | Select a season pack (default Sonarr instance) |
| POST | `/api/select/sonarr/series/:series_id` | Select a whole series, season by season |
| POST | `/api/select/:instance_id/season/:series_id/:season_number` | Season pack on a specific instance |
| POST | `/api/select/:instance_id/series/:series_id` | Whole series on a specific instance |
| POST | `/api/grab/:instance_id/:media_id` | Grab one named candidate (`{"release_id": "..."}`), re-searching first |
| POST | `/api/grab/:instance_id/season/:series_id/:season_number` | Grab one named season pack |
| GET | `/api/series/:instance_id/:series_id` | Series and per-season missing/total counts |
| GET | `/api/library/:instance_id/search` | Search the instance's library (`?q=` a title or any id); 25 results with `links` |
| GET | `/api/library/:instance_id/series/:series_id` | Picked series: seasons with missing/total counts |
| GET | `/api/library/:instance_id/series/:series_id/season/:n` | Episodes of one season |
| GET | `/api/library/:instance_id/movie/:movie_id` | Picked movie: file status and links |
| GET | `/api/wanted/:instance_id` | Wanted items (`?kind=missing\|cutoff`) |
| GET | `/api/history` | Recent selections (`?limit=`) |
| GET | `/api/logs` | Recent log lines |
| POST | `/api/rules/propose` | Propose structured rules from prose (saves nothing) |
| POST | `/api/rules/apply` | Apply an approved proposal |
| GET | `/api/automatic/status` | Scheduler status and last pass |
| POST | `/api/automatic/run` | Run a scheduler pass now |
| POST | `/api/webhook/:instance_id` | Sonarr/Radarr webhook receiver |
| POST | `/api/webhook/seerr` | Seerr / Overseerr / Jellyseerr webhook receiver (default payload) |
| GET | `/api/seerr/status` | Seerr poller status and last pass |
| POST | `/api/seerr/test` | Test the saved Seerr connection |
| GET | `/api/seerr/requests` | Requests (`?filter=pending\|processing\|approved\|available\|failed\|all`, `?take=`) |
| POST | `/api/seerr/requests/:id/approve` | Approve in Seerr and fulfil immediately |
| POST | `/api/seerr/requests/:id/decline` | Decline in Seerr |
| POST | `/api/seerr/requests/:id/fulfil` | Search and grab for that request in the background (what the UI's *Grab* does synchronously; kept for scripts) |
| POST | `/api/seerr/requests/:id/resolve` | What the request maps to in Sonarr/Radarr, without searching |
| POST | `/api/seerr/requests/:id/select` | Run the pipeline for the request and answer like `/api/select` (`{grab?, instruction?, use_ai?, instance_id?, season_number?, approve?}`) |
| POST | `/api/seerr/run` | Run a Seerr pass now |

Requests below assume no authentication; add `-H 'X-Api-Key: <key>'` when an
API key is configured.

### Search without grabbing

```bash
curl -s -X POST http://localhost:8484/api/select/radarr/movie/123 \
  -H 'Content-Type: application/json' \
  -d '{"grab": false}' | jq
```

### Search and grab, with a one-off instruction

```bash
curl -s -X POST http://localhost:8484/api/select/sonarr/episode/4567 \
  -H 'Content-Type: application/json' \
  -d '{
        "grab": true,
        "use_ai": true,
        "instruction": "For this episode specifically, pick the smallest acceptable 1080p release."
      }' | jq
```

`?grab=true` works as well; a body field wins over the query parameter. Both
`instruction` and `use_ai` are optional, and an empty body is fine.

### Response shape

```json
{
  "media": { "app": "radarr", "media_id": 123, "title": "Some Movie", "year": 2026, "...": "..." },
  "selected": {
    "release": {
      "id": "abc123", "title": "Some.Movie.2026.1080p.WEB-DL.x265-FLUX",
      "size_bytes": 6600000000, "size_gib": 6.15, "seeders": 42,
      "source": "WEB-DL", "codec": "x265", "release_group": "FLUX",
      "custom_format_score": 20, "...": "..."
    },
    "score": 88.5,
    "components": [ { "component": "preferred_codec", "points": 15.0, "detail": "x265 is preferred" } ]
  },
  "candidates": [ { "release": {}, "score": 88.5, "components": [] } ],
  "rejected": [
    { "release": {},
      "reasons": [ { "rule": "max_size", "message": "62.1 GiB exceeds the 25 GiB limit", "stage": "hard_rule" } ] }
  ],
  "reason": "highest AI rank with confidence 0.91",
  "explanation": [
    "matches your preference for WEB-DL over WEBRip",
    "matches your preference for x265",
    "FLUX is in your preferred groups",
    "6.2 GB is within your preferred size range"
  ],
  "conflicts": [ "You said you prefer AV1, but AV1 is blocked by a hard codec rule." ],
  "method": { "kind": "llm" },
  "llm": { "selected_id": "abc123", "confidence": 0.91, "reason": "...", "ranking": [], "influences": [], "conflicts": [] },
  "grabbed": false,
  "grab_error": null,
  "duration_ms": 2841
}
```

## Automatic mode

Pickarr polls each instance that has *automatic* enabled for wanted items,
runs the pipeline and grabs the winner. It never calls
`EpisodeSearch`/`MoviesSearch`, because those let Sonarr/Radarr pick the
release themselves.

Setup in short: enable automatic mode per instance, **disable RSS and automatic
search on your indexers** while leaving interactive search enabled, then run
with *Actually grab* off until the dry-run output looks right. If you use
Prowlarr, verify after each sync that it has not re-enabled those flags.

See **[docs/AUTOMATIC_MODE.md](docs/AUTOMATIC_MODE.md)** for the full rationale,
the safety properties, and webhook setup.

## Docker

`docker compose up -d` (see [Quick start](#quick-start)) is the supported path.
To run the image directly:

```bash
docker run -d --name pickarr \
  -p 8484:8484 \
  -v /srv/pickarr:/data \
  -e SONARR_URL=http://sonarr:8989 -e SONARR_API_KEY=... \
  -e RADARR_URL=http://radarr:7878 -e RADARR_API_KEY=... \
  -e LLM_ENABLED=true \
  -e LLM_BASE_URL=http://ollama:11434/v1 \
  -e LLM_MODEL=qwen2.5:14b-instruct \
  ghcr.io/lloyd-g-w/pickarr:latest
```

Or build it yourself:

```bash
docker build -t pickarr .
```

Files: [`docker-compose.yml`](docker-compose.yml) (Pickarr alone; pulls the
prebuilt image, or builds from the repository with `docker compose build`),
[`docker-compose.portainer.yml`](docker-compose.portainer.yml) (Portainer
stack, see below), [`docker-compose.full.example.yml`](docker-compose.full.example.yml)
(the whole stack) and [`.env.example`](.env.example) (every supported
variable). The container starts as root only to apply `PUID`/`PGID` and fix
the ownership of `/data`, then drops privileges; set `user:` in compose if you
prefer to skip that step (then `/data` must already be writable by that
user).

The image is published automatically by
[`.github/workflows/docker.yml`](.github/workflows/docker.yml) to
`ghcr.io/lloyd-g-w/pickarr` (`latest` for `main`, `vX.Y.Z` for tags,
`sha-…` for every commit).

### Portainer

Portainer's stack editor cannot `build:` from a pasted file, so use the
prebuilt image:

1. **Stacks → Add stack → Web editor**, name it `pickarr`.
2. Paste [`docker-compose.portainer.yml`](docker-compose.portainer.yml)
   (or choose **Repository** and point Portainer at this Git repo with
   *Compose path* `docker-compose.portainer.yml`; enable *GitOps updates* if
   you want it to follow `main`).
3. Optionally add environment variables in the stack's *Environment
   variables* section (`TZ`, `SONARR_URL`, `SONARR_API_KEY`, `LLM_*`, …) —
   everything can also be set later in the UI.
4. If Sonarr/Radarr live in another stack, uncomment the `networks` block and
   put the name of their Docker network so `http://sonarr:8989` resolves;
   otherwise use the host IP (`http://192.168.1.10:8989`).
5. **Deploy the stack**, open `http://<host>:8484`, create the admin account,
   add your instances.

Data (config, history, credentials, API key) lives in the named volume
`pickarr_data`; updating the image in Portainer (*Stacks → pickarr → Pull and
redeploy*) keeps it.

## Development

```bash
opam switch create . 5.2.0
eval $(opam env)
opam install . --deps-only --with-test
dune build
dune test
dune exec pickarr          # http://localhost:8484
```

System dependencies for the OCaml stack:

```bash
sudo apt install libev-dev libssl-dev libgmp-dev pkg-config m4
```

Layout:

```
bin/main.ml            entry point
lib/core/              pure domain: types, config, title parsing, filtering,
                       scoring, prompt building, LLM validation, explainability
lib/arr/               typed Sonarr/Radarr API clients
lib/llm/               OpenAI-compatible chat client
lib/server/            Dream routes, persistence, automatic mode, webhooks
static/                UI (vanilla JS, no build step)
test/                  Alcotest suites per library
docs/API_RESEARCH.md   verified endpoint/schema reference
vendor/                upstream OpenAPI specs used for verification
```

The Sonarr/Radarr integration was written against the upstream OpenAPI
specifications and source, not guessed; see
[`docs/API_RESEARCH.md`](docs/API_RESEARCH.md) and `vendor/`.

## Limitations

* Sonarr/Radarr must allow interactive search on the indexers you want
  Pickarr to use; `GET /api/v3/release` is the interactive-search path.
* A release-grab request must use a `guid` + `indexerId` that the instance
  still has in its interactive-search cache, whose TTL is 30 minutes. Pickarr
  always grabs within seconds of its own search (every *Grab* button in the UI
  re-runs the search server-side rather than reusing an earlier one), so this
  only matters if you drive the API yourself and delay the grab.
* Codec, audio, HDR and Dolby Vision are parsed from release titles, because
  the *arr APIs do not expose them. Titles lie sometimes; hard rules that
  depend on them are best-effort by nature (Sonarr/Radarr custom formats have
  the same limitation).
* Automatic mode reacts on a polling interval (minimum 60 s), so it is slower
  than RSS sync. Webhooks narrow the gap for newly added items.
* One LLM call per selection. With large candidate lists, keep
  `max_candidates` modest for small local models.
* The model is asked for at most five ranked candidates, so the candidate
  order below the top five stays the deterministic one.
* Optional numeric limits are cleared from the UI by emptying the field; in
  `config.json` they are `null`.
* Usenet is supported (Pickarr passes whatever Sonarr/Radarr returns), but
  the seeder rules only apply to torrents.
