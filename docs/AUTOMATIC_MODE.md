# Automatic mode

Automatic mode is how Pickarr replaces Sonarr/Radarr's own release
decision-making. This document explains what the current Sonarr v4 / Radarr v5
APIs actually allow, why Pickarr works the way it does, and how to set it up
safely.

## The constraint

Sonarr and Radarr have no supported hook that says "ask an external service
which release to grab". Their decision engine runs inside the application:

* **RSS sync** and **automatic search** both run `DownloadDecisionMaker` and
  then grab the best approved release themselves.
* The `EpisodeSearch` / `MoviesSearch` commands are *interactive-search
  triggers for the app itself* — they search and grab in one step. Calling them
  from Pickarr would hand the decision back to Sonarr/Radarr, which is
  exactly what we want to avoid.
* Webhooks are notifications, fired **after** the fact, and they cannot veto
  anything. `DownloadService.DownloadReport` hands the release to the download
  client **first** and only then publishes the grabbed event that notifications
  are built from, and `OnGrab` returns `void` — the HTTP status and body of a
  webhook receiver are never consulted. There is no `OnBeforeGrab` /
  `OnReleaseDecision` hook anywhere in the notification surface. See
  [`docs/API_RESEARCH.md`](API_RESEARCH.md) §6.3 (verified against
  `vendor/sonarr-DownloadService.cs` and `vendor/sonarr-webhook/Webhook.cs`).

So "let Pickarr approve each grab" cannot be built on webhooks. The only way
to control *which* release is taken is to be the process that calls
`POST /api/v3/release`.

What *is* supported, and is what Pickarr uses:

* `GET /api/v3/release?episodeId=` / `?movieId=` — run an interactive search
  and return every candidate release, including the ones Sonarr/Radarr would
  reject, with their rejection reasons.
* `POST /api/v3/release` with `{guid, indexerId, ...}` — grab one specific
  release. This is the interactive-search grab path: Sonarr/Radarr send the
  release to the download client and import it normally.

So Pickarr can own the decision completely, as long as Sonarr/Radarr are not
also deciding on their own.

## Design

```
every N seconds, per instance with "automatic" enabled:

  GET queue            -> media ids already downloading      (skip)
  GET history (24h)    -> media ids grabbed recently         (skip)
  GET wanted/missing   -> items that need a release
  GET wanted/cutoff    -> optional, upgrade candidates
      |
      +-- cooldown map: (instance, media id) attempted recently? (skip)
      |
      +-- for up to max_items_per_run items:
            GET  release?episodeId=/movieId=   (stage 1)
            hard filter                        (stage 2)
            deterministic score                (stage 3)
            AI ranking (optional)              (stage 4)
            POST release                       (stage 5, only if allowed)
```

Safety properties, all implemented in `lib/server/automatic.ml`:

| Property | Mechanism |
| --- | --- |
| Passes never overlap | `Lwt_mutex` around the whole pass |
| Never grabs twice for one item | queue check + 24h history check + cooldown map |
| A failing item cannot loop | cooldown of `max(interval, 10 min)` per (instance, media) |
| Bounded work per pass | `max_items_per_run`, single page of wanted items |
| Low-confidence AI picks are not grabbed | `min_confidence`, checked after the pipeline and before the grab |
| Observability before action | `grab = false` makes every pass a dry run that only logs and records history |
| An unreachable instance cannot cause a wrong grab | if the queue or history call fails, the whole instance is skipped for that pass |
| The grab always targets a release the app still knows | search and grab happen in the same pipeline run, seconds apart, well inside the 30 minute release cache (§3.4) |

The release cache matters: Sonarr/Radarr will only grab a `guid` +
`indexerId` pair that is still in the in-memory cache populated by
`GET /api/v3/release`, with a TTL of 30 minutes, and answer `404 "Couldn't find
requested release in cache, try searching again"` otherwise. Pickarr never
reuses an old search: pressing *Select &amp; grab* in the UI re-runs the whole
pipeline (search included) rather than grabbing a previously previewed
release.

Hard rules are applied before anything is grabbed, and the LLM can never
override them: it only ever sees candidates that already passed every hard
rule.

## Setting it up

1. **Configure the instances** (UI → Instances) and enable *automatic mode for
   this instance* on each one Pickarr should drive.
2. **Turn off Sonarr/Radarr's own decision-making** so the two do not race:
   * Settings → Indexers: uncheck **Enable RSS** and **Enable Automatic
     Search** on every indexer. Leave **Enable Interactive Search** on —
     `GET /api/v3/release` needs it.
     These three flags (`enableRss`, `enableAutomaticSearch`,
     `enableInteractiveSearch`) are independent booleans on `IndexerResource`,
     and `GET /api/v3/release` is hard-wired to the interactive path — this is
     the verified, supported way to separate "the app grabs" from "the sidecar
     searches" (§6.4).
   * **If you use Prowlarr, check that it does not push the flags back.**
     Depending on its sync level, Prowlarr may overwrite app-side indexer
     settings and silently re-enable automatic search. The exact sync-level
     semantics are not verified in `docs/API_RESEARCH.md`; confirm against the
     Prowlarr documentation for your version, and re-check the indexer flags in
     Sonarr/Radarr after Prowlarr syncs. Pickarr does not (yet) reconcile
     indexer flags for you — see Limitations.
   * Do **not** unmonitor items to stop the app from searching: `wanted/missing`
     and `wanted/cutoff` only list monitored items, so that would also hide the
     work from Pickarr.
   * Optionally set Sonarr/Radarr's RSS sync interval to its maximum; with RSS
     disabled per indexer it has nothing to do anyway.
3. **Start in dry-run mode**: automatic mode enabled, *Actually grab* off.
   Watch the Dashboard ("Last pass") and the History tab for a few passes and
   confirm the picks look right.
4. **Enable grabbing** once you are happy. Keep `min_confidence` at 0.5 or
   higher while you learn how your model behaves.

### Webhooks (optional, for faster reactions)

Add a webhook notification in Sonarr/Radarr:

* Settings → Connect → **+** → Webhook
* URL: `http://pickarr:8484/api/webhook/<instance_id>?apikey=<your-api-key>`
  (`<instance_id>` is the id shown on the Instances tab, e.g. `sonarr`; the API
  key is on the Security page. The query parameter is required because the *arr
  webhook UI cannot send headers.)
* Method: POST
* Triggers: **On Series Add** (Sonarr) / **On Movie Added** (Radarr), and
  optionally **On Episode File Delete** / **On Movie File Delete**
* While authentication is enabled, a webhook without a valid `apikey` is
  rejected with 401 and logged.

Pickarr acknowledges every payload, replies immediately and runs the
selection in the background. Verified against the upstream event enums
(`vendor/sonarr-WebhookEventType.cs`, `vendor/radarr-WebhookEventType.cs`):

| Event | Sonarr | Radarr | Pickarr action |
| --- | --- | --- | --- |
| `Test` | yes | yes | acknowledge |
| `Download` (import; `isUpgrade` marks upgrades — there is no `Upgrade` event) | yes | yes | acknowledged, no action |
| `SeriesAdd` | yes | – | trigger a scheduler pass |
| `MovieAdded` | – | yes | select for that movie |
| `EpisodeFileDelete` | yes | – | select for that episode |
| `MovieFileDelete` | – | yes | select for that movie |
| `Grab`, `Download`, `Rename`, `Health`, `HealthRestored`, `ApplicationUpdate`, `ManualInteractionRequired`, `*Delete` | – | – | acknowledged, no action |

There is no "download failed" webhook event in either application. Failed
downloads are picked up by the next polling pass, because the item returns to
`wanted/missing` once Sonarr/Radarr has blocklisted the release.

## What automatic mode deliberately does not do

* It does not send torrents/nzbs to qBittorrent directly. Sonarr/Radarr keep
  the download-client and import responsibility.
* It does not call `EpisodeSearch` / `MoviesSearch`, because those let
  Sonarr/Radarr pick the release.
* It does not modify indexer or profile settings in Sonarr/Radarr. Disabling
  RSS/automatic search is a deliberate, reversible user action.
* It does not retry forever: an item that yields no acceptable release is
  simply reconsidered after the cooldown.

## Limitations

* Polling granularity is the interval (minimum 60 s), so automatic mode reacts
  to new episodes more slowly than RSS sync would. Webhook triggers narrow the
  gap for newly added items.
* Pickarr does not reconcile the per-indexer `enableRss` /
  `enableAutomaticSearch` flags. If Prowlarr (or you) re-enables them,
  Sonarr/Radarr can grab a release before Pickarr looks at the item. The
  queue and history checks stop Pickarr from grabbing a *second* copy, but
  the first one will not have been chosen by Pickarr.
* Only the first page of each wanted list is read per pass (`pageSize` is
  `4 × max_items_per_run`), so a very large backlog is worked through over
  several passes rather than all at once.
* Sonarr's `wanted/missing` is episode-based; a full-season pack may be
  selected for one episode and cover several. The queue check prevents
  duplicate grabs for the remaining episodes on the next pass.
* `wanted/cutoff` (upgrades) is off by default: upgrades are where an
  over-eager selector costs the most bandwidth.
