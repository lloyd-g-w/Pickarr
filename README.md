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
`./data`, which the container writes as uid/gid 1000. If your host user has a
different uid, create it up front:

```bash
mkdir -p data && sudo chown 1000:1000 data
```

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
5. **Run a selection.** *Select*: choose an instance, enter a movie or episode
   id (or load the wanted list and press *Use*), optionally add a one-off
   instruction, then **Preview**. You get the winner, the "why" bullets, the
   full candidate ranking and every rejected release with its reason. Press
   **Select & grab** when you are happy.
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
* **A web UI** with no build step and no CDN dependencies (works offline).

## The selection pipeline

| Stage | What happens |
| --- | --- |
| 1. Retrieve | `GET /api/v3/release?episodeId=…` / `?movieId=…`, mapped into an internal `release` type (title, size, seeders, quality, source, codec, audio, HDR/DV, group, languages, custom formats, and Sonarr/Radarr's own rejections) |
| 2. Hard filtering | Deterministic OCaml rules. Every rejection carries a structured reason. The LLM never sees rejected releases and can never overturn a rejection |
| 3. Deterministic scoring | Pure, weighted, unit-tested scoring of the survivors |
| 4. AI ranking (optional) | The top N candidates plus your preferences go to an OpenAI-compatible `/chat/completions` endpoint, which must answer with strict JSON. The answer is validated (selected id exists, ranking ids exist, no duplicates, scores in range); anything invalid falls back to stage 3 |
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
| GET | `/api/wanted/:instance_id` | Wanted items (`?kind=missing\|cutoff`) |
| GET | `/api/history` | Recent selections (`?limit=`) |
| GET | `/api/logs` | Recent log lines |
| POST | `/api/rules/propose` | Propose structured rules from prose (saves nothing) |
| POST | `/api/rules/apply` | Apply an approved proposal |
| GET | `/api/automatic/status` | Scheduler status and last pass |
| POST | `/api/automatic/run` | Run a scheduler pass now |
| POST | `/api/webhook/:instance_id` | Sonarr/Radarr webhook receiver |

Requests below assume no authentication; add `-H 'X-Api-Key: <key>'` when an
API key is configured.

### Preview a selection

```bash
curl -s -X POST http://localhost:8484/api/select/radarr/movie/123 \
  -H 'Content-Type: application/json' \
  -d '{"grab": false}' | jq
```

### Select and grab, with a one-off instruction

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

Files: [`docker-compose.yml`](docker-compose.yml) (Pickarr alone, built from
the repository), [`docker-compose.full.example.yml`](docker-compose.full.example.yml)
(the whole stack) and [`.env.example`](.env.example) (every supported
variable). The image runs as uid 1000 and `/data` must be a writable volume;
the container refuses to start otherwise and says exactly that.

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
  always grabs within seconds of its own search (pressing *Select & grab* in the
  UI re-runs the pipeline rather than reusing the preview), so this only
  matters if you drive the API yourself and delay the grab.
* Codec, audio, HDR and Dolby Vision are parsed from release titles, because
  the *arr APIs do not expose them. Titles lie sometimes; hard rules that
  depend on them are best-effort by nature (Sonarr/Radarr custom formats have
  the same limitation).
* Automatic mode reacts on a polling interval (minimum 60 s), so it is slower
  than RSS sync. Webhooks narrow the gap for newly added items.
* One LLM call per selection. With large candidate lists, keep
  `max_candidates` modest for small local models.
* Optional numeric limits are cleared from the UI by emptying the field; in
  `config.json` they are `null`.
* Usenet is supported (Pickarr passes whatever Sonarr/Radarr returns), but
  the seeder rules only apply to torrents.
