# Selectarr API Research — Sonarr v4 (`/api/v3`), Radarr 5.x (`/api/v3`), OpenAI chat completions

**Purpose:** implementation-ready reference for writing typed OCaml clients. Every field name, type and
nullability below is transcribed from a primary source that was read during this research run.

## How to read the citations

All Sonarr/Radarr facts were verified against files vendored locally from the upstream `develop`
branches. Citations are of the form `verified: vendor/<file>`. Upstream locations (from
`vendor/README.md`):

| vendored file | upstream |
| --- | --- |
| `vendor/sonarr-openapi.json` | `https://raw.githubusercontent.com/Sonarr/Sonarr/develop/src/Sonarr.Api.V3/openapi.json` |
| `vendor/radarr-openapi.json` | `https://raw.githubusercontent.com/Radarr/Radarr/develop/src/Radarr.Api.V3/openapi.json` |
| `vendor/sonarr-ReleaseController.cs`, `vendor/sonarr-ReleaseResource.cs` | `src/Sonarr.Api.V3/Indexers/` |
| `vendor/radarr-ReleaseController.cs`, `vendor/radarr-ReleaseResource.cs` | `src/Radarr.Api.V3/Indexers/` |
| `vendor/sonarr-DownloadService.cs`, `vendor/sonarr-ReleaseSearchService.cs`, `vendor/sonarr-Quality.cs`, `vendor/sonarr-QualitySource.cs` | `src/NzbDrone.Core/` (`Download/`, `IndexerSearch/`, `Qualities/`) |
| `vendor/radarr-ReleaseSearchService.cs`, `vendor/radarr-Quality.cs`, `vendor/radarr-QualitySource.cs`, `vendor/radarr-Modifier.cs` | `src/NzbDrone.Core/` |
| `vendor/sonarr-webhook/*.cs`, `vendor/radarr-webhook/*.cs`, `vendor/sonarr-WebhookEventType.cs`, `vendor/radarr-WebhookEventType.cs` | `src/NzbDrone.Core/Notifications/Webhook/` |

Labels used throughout:

- **[VERIFIED]** — read directly from a vendored primary source.
- **[INFERRED]** — my reasoning from a verified source; the source does not say it literally.
- **[UNVERIFIED]** — not covered by any vendored file. A URL to check is always given.

**Nullability convention.** In both OpenAPI specs every schema is `"additionalProperties": false`, so the
field lists below are *exhaustive*. A field marked `nullable` is `"nullable": true` in the spec — model it
as an OCaml `option`. Fields *not* marked nullable are still safest decoded with a default, because
`System.Text.Json` will emit them but a partially-populated resource (e.g. the echo of a POST body) can
omit them.

**Global caveat on version skew.** The two vendored OpenAPI JSONs are generated artifacts committed to the
repo and can lag the `.cs` sources in the same branch. One concrete case was found (Radarr
`ReleaseResource.history`, see §2.4). Where spec and source disagree I document both.

---

## 1. Authentication, base path, connectivity check

### 1.1 API key

Both apps declare exactly two security schemes, and both are listed in the root `security` array, so
either works on every endpoint. [VERIFIED]

```json
"securitySchemes": {
  "X-Api-Key": { "type": "apiKey", "description": "Apikey passed as header",          "name": "X-Api-Key", "in": "header" },
  "apikey":    { "type": "apiKey", "description": "Apikey passed as query parameter", "name": "apikey",    "in": "query" }
},
"security": [ { "X-Api-Key": [] }, { "apikey": [] } ]
```

- `verified: vendor/sonarr-openapi.json` (`components.securitySchemes`, end of file)
- `verified: vendor/radarr-openapi.json` (`components.securitySchemes`, end of file)

Recommendation for the OCaml client: always send the **header** `X-Api-Key: <key>`. The `?apikey=` query
form is equally supported but leaks the key into access logs and into any `Referer`.

Base path is `/api/v3` for **both** apps. Sonarr's own spec says so explicitly:

> "Sonarr API docs - The v3 API docs apply to both v3 and v4 versions of Sonarr. Some functionality may
> only be available in v4 of the Sonarr application."

`verified: vendor/sonarr-openapi.json` (`info.description`). Sonarr spec is `openapi: 3.0.1`,
`info.version: 3.0.0`; Radarr spec is `openapi: 3.0.4`, `info.version: 3.0.0`. Default server host in
both specs is templated `{protocol}://{hostpath}`, Sonarr default `localhost:8989`. [VERIFIED]

If the user configures a reverse-proxy URL base, all paths are prefixed with it — `SystemResource.urlBase`
tells you what it is (§1.2).

### 1.2 Connectivity check — `GET /api/v3/system/status`

`verified: vendor/sonarr-openapi.json` (path `/api/v3/system/status`, tag `System`, 200 →
`#/components/schemas/SystemResource`) and `verified: vendor/radarr-openapi.json` (same path, tag
`System`).

`SystemResource` — note there is **no `id`** on this resource. [VERIFIED]

| field | type | nullable | Sonarr | Radarr |
| --- | --- | --- | --- | --- |
| `appName` | string | yes | yes | yes |
| `instanceName` | string | yes | yes | yes |
| `version` | string | yes | yes | yes |
| `buildTime` | string (date-time) | no | yes | yes |
| `isDebug` | bool | no | yes | yes |
| `isProduction` | bool | no | yes | yes |
| `isAdmin` | bool | no | yes | yes |
| `isUserInteractive` | bool | no | yes | yes |
| `startupPath` | string | yes | yes | yes |
| `appData` | string | yes | yes | yes |
| `osName` | string | yes | yes | yes |
| `osVersion` | string | yes | yes | yes |
| `isNetCore` | bool | no | yes | yes |
| `isLinux` | bool | no | yes | yes |
| `isOsx` | bool | no | yes | yes |
| `isWindows` | bool | no | yes | yes |
| `isDocker` | bool | no | yes | yes |
| `mode` | `RuntimeMode` enum | no | yes | yes |
| `branch` | string | yes | yes | yes |
| `authentication` | `AuthenticationType` enum | no | yes | yes |
| `sqliteVersion` | string | yes | yes | **absent in Radarr** |
| `migrationVersion` | int32 | no | yes | yes |
| `urlBase` | string | yes | yes | yes |
| `runtimeVersion` | string | yes | yes | yes |
| `runtimeName` | string | yes | yes | yes |
| `startTime` | string (date-time) | no | yes | yes |
| `packageVersion` | string | yes | yes | yes |
| `packageAuthor` | string | yes | yes | yes |
| `packageUpdateMechanism` | `UpdateMechanism` enum | no | yes | yes |
| `packageUpdateMechanismMessage` | string | yes | yes | yes |
| `databaseVersion` | string | yes | yes | yes |
| `databaseType` | `DatabaseType` enum | no | yes | yes |

Enums referenced here [VERIFIED, both specs]:

- `RuntimeMode`: `"console" | "service" | "tray"`
- `AuthenticationType`: `"none" | "basic" | "forms" | "external"`
- `UpdateMechanism`: `"builtIn" | "script" | "external" | "apt" | "docker"`
- `DatabaseType`: `"sqLite" | "postgreSQL"`
- `AuthenticationRequiredType`: `"enabled" | "disabledForLocalAddresses"`

**Practical connectivity test.** `GET {base}/api/v3/system/status` with `X-Api-Key`. Treat
`appName` (`"Sonarr"` / `"Radarr"`) as the app discriminator, `version` as the version string, and
`instanceName` as the user-facing label to show in Selectarr's UI/logs. A wrong key yields HTTP 401
[INFERRED — the spec documents only a `200` response for this path; the 401 behaviour is standard for the
declared `apiKey` security scheme and is not literally in the vendored files].

There is also `GET /ping` returning `PingResource { "status": string|null }` [VERIFIED, both specs], which
is **unauthenticated** and therefore useful for "is the host reachable at all" but useless for validating
the key.

---

## 2. Release search

### 2.1 Endpoints and exact query parameters

**Sonarr — `GET /api/v3/release`** (tag `Release`). Query parameters, all optional `integer/int32`:
`seriesId`, `episodeId`, `seasonNumber`. Response `200` → `ReleaseResource[]`.
`verified: vendor/sonarr-openapi.json` (path `/api/v3/release`).

Dispatch logic, `verified: vendor/sonarr-ReleaseController.cs`:

```csharp
public async Task<List<ReleaseResource>> GetReleases(int? seriesId, int? episodeId, int? seasonNumber)
{
    if (episodeId.HasValue)                       return await GetEpisodeReleases(episodeId.Value);
    if (seriesId.HasValue && seasonNumber.HasValue) return await GetSeasonReleases(seriesId.Value, seasonNumber.Value);
    return await GetRss();
}
```

- `?episodeId=N` → single-episode interactive search:
  `_releaseSearchService.EpisodeSearch(episodeId, true, true)`.
- `?seriesId=N&seasonNumber=M` → season-pack search:
  `_releaseSearchService.SeasonSearch(seriesId, seasonNumber, false, false, true, true)` — i.e.
  `missingOnly: false, monitoredOnly: false, userInvokedSearch: true, interactiveSearch: true`.
- **Gotcha:** `?seriesId=N` *alone* (without `seasonNumber`) does **not** search the series — it falls
  through to `GetRss()`, which fetches and decides the whole RSS feed. Selectarr must never send
  `seriesId` without `seasonNumber`. [VERIFIED from the code above]
- No arguments at all → `GetRss()` (full RSS fetch + decisions). Slow and not what you want.

**Radarr — `GET /api/v3/release`** (tag `Release`). Single optional query parameter `movieId`
(`integer/int32`). Response `200` → `ReleaseResource[]`.
`verified: vendor/radarr-openapi.json` (path `/api/v3/release`).

```csharp
public async Task<List<ReleaseResource>> GetReleases(int? movieId)
{
    if (movieId.HasValue) return await GetMovieReleases(movieId.Value);
    return await GetRss();
}
```
`verified: vendor/radarr-ReleaseController.cs`. `GetMovieReleases` calls
`_releaseSearchService.MovieSearch(movieId, true, true)`.

Both controllers map errors as: `SearchFailedException` → **400**, any other exception → **500**
(`"Episode search failed: …"` / `"Movie search failed: …"`). [VERIFIED, both `*-ReleaseController.cs`]

### 2.2 These are *interactive* searches — the single most important fact for Selectarr

`ISearchForReleases.EpisodeSearch(int episodeId, bool userInvokedSearch, bool interactiveSearch)`
`verified: vendor/sonarr-ReleaseSearchService.cs`; Radarr's is
`MovieSearch(int movieId, bool userInvokedSearch, bool interactiveSearch)`
`verified: vendor/radarr-ReleaseSearchService.cs`. The controllers pass `true, true`.

Indexer selection then depends on that flag, in **both** apps, identical code:

```csharp
var indexers = criteriaBase.InteractiveSearch ?
    _indexerFactory.InteractiveSearchEnabled() :
    _indexerFactory.AutomaticSearchEnabled();

// Filter indexers to untagged indexers and indexers with intersecting tags
indexers = indexers.Where(i => i.Definition.Tags.Empty()
                            || i.Definition.Tags.Intersect(criteriaBase.Series.Tags).Any()).ToList();
```
`verified: vendor/sonarr-ReleaseSearchService.cs` (`Dispatch`) and
`verified: vendor/radarr-ReleaseSearchService.cs` (`Dispatch`, identical but `criteriaBase.Movie.Tags`).

**Consequences (all [VERIFIED] from that snippet):**

1. `GET /api/v3/release` searches only indexers with `enableInteractiveSearch = true`.
2. `enableAutomaticSearch = false` does **not** affect `GET /api/v3/release`.
3. Indexer *tags* filter the search: an indexer with tags only participates if it shares a tag with the
   series/movie.
4. `Dispatch` also updates `LastSearchTime` on the episode(s)/movie if ≥1 indexer was searched — so
   Selectarr's searches are visible in `episode.lastSearchTime` / `movie.lastSearchTime`.

This is the mechanism that makes "sidecar-driven" mode possible (§6).

Results are prioritised before mapping: Sonarr `_prioritizeDownloadDecision.PrioritizeDecisions(decisions)`,
Radarr `PrioritizeDecisionsForMovies(decisions)`. There is also a de-dupe by `guid` keeping the decision
with fewest rejections then best indexer priority (`DeDupeDecisions`). [VERIFIED, both
`*-ReleaseSearchService.cs`]

### 2.3 Sonarr `ReleaseResource` — full schema

`verified: vendor/sonarr-openapi.json` (`components.schemas.ReleaseResource`) cross-checked field-by-field
against `verified: vendor/sonarr-ReleaseResource.cs`. Order below is the spec's (= C# declaration) order.

| field | JSON type | nullable | notes |
| --- | --- | --- | --- |
| `id` | int32 | no | from `RestResource` base; always `0` for releases (not a DB row) |
| `guid` | string | yes | **cache key part 1** for grabbing |
| `quality` | `QualityModel` | no | see §2.6 |
| `qualityWeight` | int32 | no | |
| `age` | int32 | no | days |
| `ageHours` | double | no | |
| `ageMinutes` | double | no | |
| `size` | **int64** | no | bytes; use `int64` in OCaml, not `int32` |
| `indexerId` | int32 | no | **cache key part 2**; required on grab |
| `indexer` | string | yes | display name |
| `releaseGroup` | string | yes | from parsed info |
| `subGroup` | string | yes | **present in Sonarr** (anime sub group) |
| `releaseHash` | string | yes | |
| `title` | string | yes | the raw release name — parse codec/audio from here (§2.7) |
| `fullSeason` | bool | no | |
| `sceneSource` | bool | no | |
| `seasonNumber` | int32 | no | parsed |
| `languages` | `Language[]` | yes | `Language = { id: int32, name: string|null }` |
| `languageWeight` | int32 | no | |
| `airDate` | string | yes | daily series, `"yyyy-MM-dd"` style string, not a date-time |
| `seriesTitle` | string | yes | parsed |
| `episodeNumbers` | int32[] | yes | parsed |
| `absoluteEpisodeNumbers` | int32[] | yes | parsed |
| `mappedSeasonNumber` | int32 | yes | resolved against library |
| `mappedEpisodeNumbers` | int32[] | yes | resolved |
| `mappedAbsoluteEpisodeNumbers` | int32[] | yes | resolved |
| `mappedSeriesId` | int32 | yes | resolved |
| `mappedEpisodeInfo` | `ReleaseEpisodeResource[]` | yes | resolved |
| `approved` | bool | no | |
| `temporarilyRejected` | bool | no | |
| `rejected` | bool | no | |
| `tvdbId` | int32 | no | from the indexer result |
| `tvRageId` | int32 | no | |
| `imdbId` | **string** | yes | **string in Sonarr** (contrast Radarr) |
| `rejections` | **string[]** | yes | plain strings, see below |
| `publishDate` | string (date-time) | no | |
| `commentUrl` | string | yes | |
| `downloadUrl` | string | yes | |
| `infoUrl` | string | yes | |
| `episodeRequested` | bool | no | |
| `downloadAllowed` | bool | no | |
| `releaseWeight` | int32 | no | |
| `customFormats` | `CustomFormatResource[]` | yes | |
| `customFormatScore` | int32 | no | |
| `sceneMapping` | `AlternateTitleResource` | object, may be null | |
| `magnetUrl` | string | yes | torrent only |
| `infoHash` | string | yes | torrent only |
| `seeders` | int32 | yes | torrent only |
| `leechers` | int32 | yes | torrent only; computed `peers - seeders` |
| `protocol` | `DownloadProtocol` | no | `"unknown" \| "usenet" \| "torrent"` |
| `indexerFlags` | **int32** | no | **bitmask integer in Sonarr** |
| `isDaily` | bool | no | |
| `isAbsoluteNumbering` | bool | no | |
| `isPossibleSpecialEpisode` | bool | no | |
| `special` | bool | no | |
| `seriesId` | int32 | yes | *write-mostly*, see note |
| `episodeId` | int32 | yes | *write-mostly* |
| `episodeIds` | int32[] | yes | *write-mostly* |
| `downloadClientId` | int32 | yes | *write-mostly* |
| `downloadClient` | string | yes | *write-mostly* |
| `shouldOverride` | bool | yes | *write-mostly* |

**`rejections` is a plain list of strings, not objects.** [VERIFIED]
Spec: `"rejections": { "type": "array", "items": { "type": "string" }, "nullable": true }`.
Source: `Rejections = model.Rejections.Select(r => r.Message).ToList()`
(`verified: vendor/sonarr-ReleaseResource.cs`). The internal rejection object has a `RejectionType`
(`"permanent" | "temporary"` — the enum exists in the spec as `RejectionType`) but **that type is not
exposed on `ReleaseResource`**; you only get the message text. Use the booleans
`rejected` / `temporarilyRejected` / `approved` for the permanent-vs-temporary distinction.

**The last six fields are omitted from GET responses.** In the C# they carry
`[JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]`
(`verified: vendor/sonarr-ReleaseResource.cs`), and the `ToResource` mapper never assigns them. So in a
`GET /api/v3/release` response `seriesId`, `episodeId`, `episodeIds`, `downloadClientId`,
`downloadClient`, `shouldOverride` are **absent** (not `null`). They exist purely as *inputs* to
`POST /api/v3/release`. Decode them as `option` and never rely on them being present. [VERIFIED]

`ReleaseEpisodeResource` [VERIFIED, both spec and `vendor/sonarr-ReleaseResource.cs`]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `seasonNumber` | int32 | no |
| `episodeNumber` | int32 | no |
| `absoluteEpisodeNumber` | int32 | yes |
| `title` | string | yes |

`AlternateTitleResource` (the `sceneMapping` payload) [VERIFIED, `vendor/sonarr-openapi.json`]:
`title: string|null`, `seasonNumber: int32|null`, `sceneSeasonNumber: int32|null`,
`sceneOrigin: string|null`, `comment: string|null`.

### 2.4 Radarr `ReleaseResource` — full schema

`verified: vendor/radarr-openapi.json` (`components.schemas.ReleaseResource`) cross-checked against
`verified: vendor/radarr-ReleaseResource.cs`.

| field | JSON type | nullable | notes |
| --- | --- | --- | --- |
| `id` | int32 | no | always `0` |
| `guid` | string | yes | cache key part 1 |
| `quality` | `QualityModel` | no | **includes `modifier`** (§2.6) |
| `customFormats` | `CustomFormatResource[]` | yes | earlier in the order than Sonarr |
| `customFormatScore` | int32 | no | |
| `qualityWeight` | int32 | no | |
| `age` | int32 | no | |
| `ageHours` | double | no | |
| `ageMinutes` | double | no | |
| `size` | int64 | no | |
| `indexerId` | int32 | no | cache key part 2 |
| `indexer` | string | yes | |
| `releaseGroup` | string | yes | |
| `subGroup` | string | yes | |
| `releaseHash` | string | yes | |
| `title` | string | yes | |
| `sceneSource` | bool | no | |
| `movieTitles` | string[] | yes | **Radarr only** |
| `languages` | `Language[]` | yes | |
| `mappedMovieId` | int32 | yes | **Radarr only** — resolved library movie |
| `approved` | bool | no | |
| `temporarilyRejected` | bool | no | |
| `rejected` | bool | no | |
| `tmdbId` | int32 | no | **Radarr only** |
| `imdbId` | **int32** | no | **integer in Radarr**, string in Sonarr |
| `rejections` | string[] | yes | plain strings |
| `publishDate` | string (date-time) | no | |
| `commentUrl` | string | yes | |
| `downloadUrl` | string | yes | |
| `infoUrl` | string | yes | |
| `movieRequested` | bool | no | Radarr's analogue of `episodeRequested` |
| `downloadAllowed` | bool | no | |
| `releaseWeight` | int32 | no | |
| `edition` | string | yes | **Radarr only** |
| `magnetUrl` | string | yes | |
| `infoHash` | string | yes | |
| `seeders` | int32 | yes | |
| `leechers` | int32 | yes | |
| `protocol` | `DownloadProtocol` | no | |
| `indexerFlags` | **untyped** | yes | see below |
| `movieId` | int32 | yes | *write-mostly* |
| `downloadClientId` | int32 | yes | *write-mostly* |
| `downloadClient` | string | yes | *write-mostly* |
| `shouldOverride` | bool | yes | *write-mostly* |

**`indexerFlags` is asymmetric and type-unstable in Radarr.** [VERIFIED]

- Spec declares it with **no `type`** at all: `"indexerFlags": { "nullable": true }`.
- C# declares `public dynamic IndexerFlags { get; set; }`.
- On **read** (`ToResource`) it is a **list of strings**:
  `torrentInfo.IndexerFlags.ToString().Split(new[] { ", " }, …).Where(x => x != "0")`.
- On **write** (`ToModel`) it accepts a **JSON number**:
  `if (resource.IndexerFlags is JsonElement { ValueKind: JsonValueKind.Number } indexerFlags)
   model.IndexerFlags = (IndexerFlags)indexerFlags.GetInt32();`

`verified: vendor/radarr-ReleaseResource.cs`. **OCaml guidance:** decode Radarr's `indexerFlags` as
`Yojson.Safe.t` (or `string list option` with a permissive fallback), and when echoing a body back for a
grab, either omit it or send an integer. Sonarr's is always a plain `int32` bitmask.

**Contradiction — `history` field.** `vendor/radarr-ReleaseResource.cs` declares
`public ReleaseHistoryResource History { get; set; }` (between `customFormatScore` and `qualityWeight`),
and `vendor/radarr-ReleaseController.cs` populates it in `MapDecisions(decisions, history)` via
`AddHistory(...)`, producing `{ grabbed: <DateTime>, failed?: <DateTime> }`. **But the vendored
`radarr-openapi.json` does not contain a `history` property on `ReleaseResource` nor a
`ReleaseHistoryResource` schema.** This is a spec/source skew. Treat `history` as an *optional, possibly
present* object:

```json
"history": { "grabbed": "2024-05-01T12:00:00Z", "failed": "2024-05-01T13:10:00Z" }
```

`verified: vendor/radarr-ReleaseResource.cs`, `verified: vendor/radarr-ReleaseController.cs`;
**field names/types of `ReleaseHistoryResource` are [INFERRED]** from
`new ReleaseHistoryResource { Grabbed = grabbed.Date }` and `resource.Failed = failedHistory.Date`
(`ReleaseHistoryResource.cs` itself was not vendored). Decode defensively.

`AddHistory` matches a prior grab by `guid`, or `nzbInfoUrl` vs `release.InfoUrl`, or (torrents) by
info-hash / same-title+protocol comparison. This is a **useful signal: Radarr already tells you whether it
previously grabbed this exact release, and whether that grab failed.** Sonarr has no equivalent field.
`verified: vendor/radarr-ReleaseController.cs`.

### 2.5 Sonarr vs Radarr `ReleaseResource` — differences summary

Present in **Sonarr only**: `fullSeason`, `seasonNumber`, `languageWeight`, `airDate`, `seriesTitle`,
`episodeNumbers`, `absoluteEpisodeNumbers`, `mappedSeasonNumber`, `mappedEpisodeNumbers`,
`mappedAbsoluteEpisodeNumbers`, `mappedSeriesId`, `mappedEpisodeInfo`, `tvdbId`, `tvRageId`,
`episodeRequested`, `sceneMapping`, `isDaily`, `isAbsoluteNumbering`, `isPossibleSpecialEpisode`,
`special`, `seriesId`, `episodeId`, `episodeIds`.

Present in **Radarr only**: `movieTitles`, `mappedMovieId`, `tmdbId`, `movieRequested`, `edition`,
`movieId`, (`history` per source only).

Same name, **different type**: `imdbId` (Sonarr `string` / Radarr `int32`);
`indexerFlags` (Sonarr `int32` / Radarr untyped, strings on read).

Identical in both: `id`, `guid`, `quality`, `qualityWeight`, `age`, `ageHours`, `ageMinutes`, `size`,
`indexerId`, `indexer`, `releaseGroup`, `subGroup`, `releaseHash`, `title`, `sceneSource`, `languages`,
`approved`, `temporarilyRejected`, `rejected`, `rejections`, `publishDate`, `commentUrl`, `downloadUrl`,
`infoUrl`, `downloadAllowed`, `releaseWeight`, `customFormats`, `customFormatScore`, `magnetUrl`,
`infoHash`, `seeders`, `leechers`, `protocol`, `downloadClientId`, `downloadClient`, `shouldOverride`.

**Two separate OCaml record types are required.** A shared record would be wrong on `imdbId` alone.

### 2.6 Quality, QualityModel, and the enums — they differ between the apps

`QualityModel` (both apps, identical) [VERIFIED, both specs]:

```json
{ "quality": { /* Quality */ }, "revision": { /* Revision */ } }
```

`Revision` (both apps, identical) [VERIFIED]: `version: int32`, `real: int32`, `isRepack: bool`.

`Quality` — **shape differs**: [VERIFIED]

| | Sonarr | Radarr |
| --- | --- | --- |
| `id` | int32 | int32 |
| `name` | string, nullable | string, nullable |
| `source` | `QualitySource` | `QualitySource` |
| `resolution` | int32 | int32 |
| `modifier` | **absent** | `Modifier` |

`verified: vendor/sonarr-openapi.json` / `vendor/radarr-openapi.json`
(`components.schemas.Quality`), corroborated by `vendor/sonarr-Quality.cs`
(constructor `Quality(int id, string name, QualitySource source, int resolution)` — four args, no
modifier) and `vendor/radarr-Quality.cs` (five-arg form with `Modifier`).

**`QualitySource` — completely different value sets.** The task brief's list applies to Sonarr only.

Sonarr `QualitySource` (JSON strings, from the spec):
`"unknown" | "television" | "televisionRaw" | "web" | "webRip" | "dvd" | "bluray" | "blurayRaw"`
`verified: vendor/sonarr-openapi.json`; C# enum `Unknown, Television, TelevisionRaw, Web, WebRip, DVD, Bluray, BlurayRaw`
`verified: vendor/sonarr-QualitySource.cs`.

Radarr `QualitySource` (JSON strings, from the spec):
`"unknown" | "cam" | "telesync" | "telecine" | "workprint" | "dvd" | "tv" | "webdl" | "webrip" | "bluray"`
`verified: vendor/radarr-openapi.json`; C# enum `UNKNOWN, CAM, TELESYNC, TELECINE, WORKPRINT, DVD, TV, WEBDL, WEBRIP, BLURAY`
`verified: vendor/radarr-QualitySource.cs`.

Only `"unknown"` and `"dvd"` overlap. **Two separate OCaml variant types.**

Radarr `Modifier` (JSON strings): `"none" | "regional" | "screener" | "rawhd" | "brdisk" | "remux"`
`verified: vendor/radarr-openapi.json`; C# `NONE = 0, REGIONAL, SCREENER, RAWHD, BRDISK, REMUX`
`verified: vendor/radarr-Modifier.cs`. Sonarr has no `Modifier` type at all.

`DownloadProtocol` (both, identical): `"unknown" | "usenet" | "torrent"` [VERIFIED, both specs].

**Resolution values actually used.** The brief's suggested set `{360, 480, 540, 576, 720, 1080, 2160}`
is **not** what the code contains. Enumerating every `Quality` definition:

- Sonarr resolutions in use: **`0, 480, 576, 720, 1080, 2160`** — `verified: vendor/sonarr-Quality.cs`.
- Radarr resolutions in use: **`0, 480, 576, 720, 1080, 2160`** — `verified: vendor/radarr-Quality.cs`.

**`360` and `540` do not appear in either app's quality table.** Model `resolution` as a plain `int` and do
not build a closed variant over it.

#### Sonarr quality table — id / name / source / resolution
`verified: vendor/sonarr-Quality.cs` (static definitions + the `All` list).

| id | name | source | resolution |
| --- | --- | --- | --- |
| 0 | `Unknown` | `unknown` | 0 |
| 1 | `SDTV` | `television` | 480 |
| 2 | `DVD` | `dvd` | 480 |
| 3 | `WEBDL-1080p` | `web` | 1080 |
| 4 | `HDTV-720p` | `television` | 720 |
| 5 | `WEBDL-720p` | `web` | 720 |
| 6 | `Bluray-720p` | `bluray` | 720 |
| 7 | `Bluray-1080p` | `bluray` | 1080 |
| 8 | `WEBDL-480p` | `web` | 480 |
| 9 | `HDTV-1080p` | `television` | 1080 |
| 10 | `Raw-HD` | `televisionRaw` | 1080 |
| 12 | `WEBRip-480p` | `webRip` | 480 |
| 13 | `Bluray-480p` | `bluray` | 480 |
| 14 | `WEBRip-720p` | `webRip` | 720 |
| 15 | `WEBRip-1080p` | `webRip` | 1080 |
| 16 | `HDTV-2160p` | `television` | 2160 |
| 17 | `WEBRip-2160p` | `webRip` | 2160 |
| 18 | `WEBDL-2160p` | `web` | 2160 |
| 19 | `Bluray-2160p` | `bluray` | 2160 |
| 20 | `Bluray-1080p Remux` | `blurayRaw` | 1080 |
| 21 | `Bluray-2160p Remux` | `blurayRaw` | 2160 |
| 22 | `Bluray-576p` | `bluray` | 576 |

Id `11` is commented out in the source (`HDTV-480p`) and does not exist.

#### Radarr quality table — id / name / source / resolution / modifier
`verified: vendor/radarr-Quality.cs`.

| id | name | source | resolution | modifier |
| --- | --- | --- | --- | --- |
| 0 | `Unknown` | `unknown` | 0 | `none` |
| 1 | `SDTV` | `tv` | 480 | `none` |
| 2 | `DVD` | `dvd` | 0 | `none` |
| 3 | `WEBDL-1080p` | `webdl` | 1080 | `none` |
| 4 | `HDTV-720p` | `tv` | 720 | `none` |
| 5 | `WEBDL-720p` | `webdl` | 720 | `none` |
| 6 | `Bluray-720p` | `bluray` | 720 | `none` |
| 7 | `Bluray-1080p` | `bluray` | 1080 | `none` |
| 8 | `WEBDL-480p` | `webdl` | 480 | `none` |
| 9 | `HDTV-1080p` | `tv` | 1080 | `none` |
| 10 | `Raw-HD` | `tv` | 1080 | `rawhd` |
| 12 | `WEBRip-480p` | `webrip` | 480 | `none` |
| 14 | `WEBRip-720p` | `webrip` | 720 | `none` |
| 15 | `WEBRip-1080p` | `webrip` | 1080 | `none` |
| 16 | `HDTV-2160p` | `tv` | 2160 | `none` |
| 17 | `WEBRip-2160p` | `webrip` | 2160 | `none` |
| 18 | `WEBDL-2160p` | `webdl` | 2160 | `none` |
| 19 | `Bluray-2160p` | `bluray` | 2160 | `none` |
| 20 | `Bluray-480p` | `bluray` | 480 | `none` |
| 21 | `Bluray-576p` | `bluray` | 576 | `none` |
| 22 | `BR-DISK` | `bluray` | 1080 | `brdisk` |
| 23 | `DVD-R` | `dvd` | 480 | `remux` |
| 24 | `WORKPRINT` | `workprint` | 0 | `none` |
| 25 | `CAM` | `cam` | 0 | `none` |
| 26 | `TELESYNC` | `telesync` | 0 | `none` |
| 27 | `TELECINE` | `telecine` | 0 | `none` |
| 28 | `DVDSCR` | `dvd` | 480 | `screener` |
| 29 | `REGIONAL` | `dvd` | 480 | `regional` |
| 30 | `Remux-1080p` | `bluray` | 1080 | `remux` |
| 31 | `Remux-2160p` | `bluray` | 2160 | `remux` |

Ids `11` and `13` do not exist in Radarr.

**Quality IDs are NOT portable across apps.** E.g. id `20` is `Bluray-1080p Remux` in Sonarr but
`Bluray-480p` in Radarr; id `2` (`DVD`) has resolution `480` in Sonarr and `0` in Radarr. Selectarr must
key quality tables per-app. [VERIFIED by comparing the two tables above]

### 2.7 Codec and audio are **not** provided — confirmed

**Confirmed.** Neither `ReleaseResource` contains any codec, audio-codec, audio-channel, HDR, bit-depth or
resolution-of-file field. Evidence is strong because both spec schemas are
`"additionalProperties": false` and the field lists in §2.3/§2.4 are complete transcriptions.
`verified: vendor/sonarr-openapi.json`, `vendor/radarr-openapi.json`,
`vendor/sonarr-ReleaseResource.cs`, `vendor/radarr-ReleaseResource.cs`.

What you *do* get that is semi-structured:

- `quality.quality.name` — e.g. `"WEBDL-1080p"`, `"Bluray-2160p Remux"` (source + resolution only).
- `quality.quality.source` / `.resolution` / (Radarr) `.modifier`.
- `quality.revision.{version,real,isRepack}` — proper/repack detection.
- `customFormats[] : CustomFormatResource[]` and `customFormatScore : int32` — **this is the intended
  mechanism** for codec/audio/HDR awareness. If the user has TRaSH-style custom formats configured, Sonarr
  and Radarr have already matched them against the release and you get names + a score without parsing.
- `languages[]`, `releaseGroup`, `subGroup`, (Radarr) `edition`.
- `indexerFlags` (freeleech, internal, scene, …).

Everything else — video codec (x264/x265/AV1), audio codec (DTS-HD MA, TrueHD, Atmos, EAC3), channel
count, HDR10/DV, bit depth — **must be parsed from `title`** by Selectarr. [VERIFIED by absence]

For contrast, media-info *is* available for already-imported files, not for releases: Sonarr's
`EpisodeFileResource.mediaInfo : MediaInfoResource` and Radarr's `MovieFileResource.mediaInfo` expose
`audioBitrate (int64)`, `audioChannels (double)`, `audioCodec (string)` etc.
`verified: vendor/sonarr-openapi.json` (`EpisodeFileResource`, `MediaInfoResource`). Useful for
upgrade decisions about the *existing* file, not for candidate ranking.

### 2.8 Realistic full example — Sonarr `GET /api/v3/release?episodeId=12345`

Field set and types exactly as §2.3 (write-only fields correctly absent).

```json
[
  {
    "id": 0,
    "guid": "https://example-indexer.net/api/v1/torrent/998877",
    "quality": {
      "quality": { "id": 3, "name": "WEBDL-1080p", "source": "web", "resolution": 1080 },
      "revision": { "version": 1, "real": 0, "isRepack": false }
    },
    "qualityWeight": 1201,
    "age": 2,
    "ageHours": 53.4,
    "ageMinutes": 3204.7,
    "size": 3221225472,
    "indexerId": 4,
    "indexer": "Example Indexer (Prowlarr)",
    "releaseGroup": "NTb",
    "subGroup": null,
    "releaseHash": null,
    "title": "The.Example.Show.S02E05.The.Episode.Title.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb",
    "fullSeason": false,
    "sceneSource": false,
    "seasonNumber": 2,
    "languages": [ { "id": 1, "name": "English" } ],
    "languageWeight": 0,
    "airDate": null,
    "seriesTitle": "The Example Show",
    "episodeNumbers": [ 5 ],
    "absoluteEpisodeNumbers": [],
    "mappedSeasonNumber": 2,
    "mappedEpisodeNumbers": [ 5 ],
    "mappedAbsoluteEpisodeNumbers": [],
    "mappedSeriesId": 42,
    "mappedEpisodeInfo": [
      { "id": 12345, "seasonNumber": 2, "episodeNumber": 5, "absoluteEpisodeNumber": null, "title": "The Episode Title" }
    ],
    "approved": true,
    "temporarilyRejected": false,
    "rejected": false,
    "tvdbId": 0,
    "tvRageId": 0,
    "imdbId": "",
    "rejections": [],
    "publishDate": "2024-05-08T18:22:00Z",
    "commentUrl": "https://example-indexer.net/details/998877",
    "downloadUrl": "https://example-indexer.net/api/v1/torrent/998877/download?apikey=REDACTED",
    "infoUrl": "https://example-indexer.net/details/998877",
    "episodeRequested": true,
    "downloadAllowed": true,
    "releaseWeight": 0,
    "customFormats": [
      { "id": 7, "name": "WEB Tier 01", "includeCustomFormatWhenRenaming": false, "specifications": [] },
      { "id": 9, "name": "DD+",         "includeCustomFormatWhenRenaming": false, "specifications": [] }
    ],
    "customFormatScore": 1600,
    "sceneMapping": null,
    "magnetUrl": null,
    "infoHash": "f1e2d3c4b5a6978869504132231425364758697a",
    "seeders": 87,
    "leechers": 3,
    "protocol": "torrent",
    "indexerFlags": 1,
    "isDaily": false,
    "isAbsoluteNumbering": false,
    "isPossibleSpecialEpisode": false,
    "special": false
  },
  {
    "id": 0,
    "guid": "Example-Usenet-1122334455",
    "quality": {
      "quality": { "id": 9, "name": "HDTV-1080p", "source": "television", "resolution": 1080 },
      "revision": { "version": 2, "real": 0, "isRepack": true }
    },
    "qualityWeight": 801,
    "age": 9,
    "ageHours": 219.8,
    "ageMinutes": 13188.0,
    "size": 2147483648,
    "indexerId": 2,
    "indexer": "Example Usenet",
    "releaseGroup": "GRP",
    "subGroup": null,
    "releaseHash": null,
    "title": "The.Example.Show.S02E05.REPACK.1080p.HDTV.x264-GRP",
    "fullSeason": false,
    "sceneSource": true,
    "seasonNumber": 2,
    "languages": [ { "id": 1, "name": "English" } ],
    "languageWeight": 0,
    "airDate": null,
    "seriesTitle": "The Example Show",
    "episodeNumbers": [ 5 ],
    "absoluteEpisodeNumbers": [],
    "mappedSeasonNumber": 2,
    "mappedEpisodeNumbers": [ 5 ],
    "mappedAbsoluteEpisodeNumbers": [],
    "mappedSeriesId": 42,
    "mappedEpisodeInfo": [
      { "id": 12345, "seasonNumber": 2, "episodeNumber": 5, "absoluteEpisodeNumber": null, "title": "The Episode Title" }
    ],
    "approved": false,
    "temporarilyRejected": false,
    "rejected": true,
    "tvdbId": 123456,
    "tvRageId": 0,
    "imdbId": "tt1234567",
    "rejections": [
      "Quality HDTV-1080p is not wanted in profile",
      "Existing file on disk is of equal or higher preference"
    ],
    "publishDate": "2024-05-01T04:10:00Z",
    "commentUrl": null,
    "downloadUrl": "https://usenet.example.com/getnzb/1122334455.nzb?apikey=REDACTED",
    "infoUrl": "https://usenet.example.com/details/1122334455",
    "episodeRequested": true,
    "downloadAllowed": false,
    "releaseWeight": 1,
    "customFormats": [],
    "customFormatScore": 0,
    "sceneMapping": null,
    "magnetUrl": null,
    "infoHash": null,
    "seeders": null,
    "leechers": null,
    "protocol": "usenet",
    "indexerFlags": 0,
    "isDaily": false,
    "isAbsoluteNumbering": false,
    "isPossibleSpecialEpisode": false,
    "special": false
  }
]
```

### 2.9 Realistic full example — Radarr `GET /api/v3/release?movieId=77`

Note `imdbId` as an **integer**, `indexerFlags` as a **string array**, and the source-only `history`.

```json
[
  {
    "id": 0,
    "guid": "https://example-indexer.net/api/v1/torrent/554433",
    "quality": {
      "quality": { "id": 30, "name": "Remux-1080p", "source": "bluray", "resolution": 1080, "modifier": "remux" },
      "revision": { "version": 1, "real": 0, "isRepack": false }
    },
    "customFormats": [
      { "id": 12, "name": "TrueHD ATMOS", "includeCustomFormatWhenRenaming": false, "specifications": [] },
      { "id": 18, "name": "Remux Tier 01", "includeCustomFormatWhenRenaming": false, "specifications": [] }
    ],
    "customFormatScore": 2100,
    "history": { "grabbed": "2024-04-02T09:15:00Z" },
    "qualityWeight": 1901,
    "age": 41,
    "ageHours": 991.2,
    "ageMinutes": 59472.0,
    "size": 32212254720,
    "indexerId": 4,
    "indexer": "Example Indexer (Prowlarr)",
    "releaseGroup": "FraMeSToR",
    "subGroup": null,
    "releaseHash": null,
    "title": "Example.Movie.2023.1080p.BluRay.REMUX.AVC.TrueHD.7.1.Atmos-FraMeSToR",
    "sceneSource": false,
    "movieTitles": [ "Example Movie" ],
    "languages": [ { "id": 1, "name": "English" } ],
    "mappedMovieId": 77,
    "approved": true,
    "temporarilyRejected": false,
    "rejected": false,
    "tmdbId": 654321,
    "imdbId": 1234567,
    "rejections": [],
    "publishDate": "2024-03-29T21:00:00Z",
    "commentUrl": "https://example-indexer.net/details/554433",
    "downloadUrl": "https://example-indexer.net/api/v1/torrent/554433/download?apikey=REDACTED",
    "infoUrl": "https://example-indexer.net/details/554433",
    "movieRequested": true,
    "downloadAllowed": true,
    "releaseWeight": 0,
    "edition": "",
    "magnetUrl": null,
    "infoHash": "aabbccddeeff00112233445566778899aabbccdd",
    "seeders": 14,
    "leechers": 1,
    "protocol": "torrent",
    "indexerFlags": [ "Internal", "Freeleech" ]
  },
  {
    "id": 0,
    "guid": "Example-Usenet-9988776655",
    "quality": {
      "quality": { "id": 3, "name": "WEBDL-1080p", "source": "webdl", "resolution": 1080, "modifier": "none" },
      "revision": { "version": 1, "real": 0, "isRepack": false }
    },
    "customFormats": [],
    "customFormatScore": 0,
    "qualityWeight": 1201,
    "age": 5,
    "ageHours": 121.6,
    "ageMinutes": 7296.0,
    "size": 8589934592,
    "indexerId": 2,
    "indexer": "Example Usenet",
    "releaseGroup": "CMRG",
    "subGroup": null,
    "releaseHash": null,
    "title": "Example.Movie.2023.1080p.AMZN.WEB-DL.DDP5.1.H.264-CMRG",
    "sceneSource": false,
    "movieTitles": [ "Example Movie" ],
    "languages": [ { "id": 1, "name": "English" } ],
    "mappedMovieId": 77,
    "approved": false,
    "temporarilyRejected": true,
    "rejected": true,
    "tmdbId": 654321,
    "imdbId": 1234567,
    "rejections": [ "Waiting for 30 minutes to see if a better release is available" ],
    "publishDate": "2024-05-04T11:45:00Z",
    "commentUrl": null,
    "downloadUrl": "https://usenet.example.com/getnzb/9988776655.nzb?apikey=REDACTED",
    "infoUrl": "https://usenet.example.com/details/9988776655",
    "movieRequested": true,
    "downloadAllowed": false,
    "releaseWeight": 1,
    "edition": "",
    "magnetUrl": null,
    "infoHash": null,
    "seeders": null,
    "leechers": null,
    "protocol": "usenet",
    "indexerFlags": []
  }
]
```

---

## 3. Grabbing a release — `POST /api/v3/release`

### 3.1 Request/response contract

`POST /api/v3/release`, `Consumes("application/json")`, request body schema = the **full
`ReleaseResource`**, response `200`. `verified: vendor/sonarr-openapi.json` and
`vendor/radarr-openapi.json` (path `/api/v3/release`, `post`), `verified: vendor/sonarr-ReleaseController.cs`
and `vendor/radarr-ReleaseController.cs` (`[HttpPost] [Consumes("application/json")] DownloadRelease([FromBody] ReleaseResource release)`).

**Required fields — exactly two.** Declared as FluentValidation rules in both controllers' constructors:

```csharp
PostValidator.RuleFor(s => s.IndexerId).ValidId();
PostValidator.RuleFor(s => s.Guid).NotEmpty();
```
`verified: vendor/sonarr-ReleaseController.cs`, `verified: vendor/radarr-ReleaseController.cs`.

So the minimal successful grab body is:

```json
{ "guid": "https://example-indexer.net/api/v1/torrent/998877", "indexerId": 4 }
```

`ValidId()` means `indexerId` must be `> 0` [INFERRED from the validator name; the `ValidId` extension
itself was not vendored]. `Guid.NotEmpty()` means non-null and non-empty-string.

**Response.** The controller returns the *deserialized request body object*, not a re-read resource:

```csharp
await _downloadService.DownloadReport(remoteEpisode, release.DownloadClientId);
// …
return release;
```
`verified: vendor/sonarr-ReleaseController.cs` (Radarr identical with `remoteMovie`). Declared return type
is `Task<object>`; the OpenAPI `200` response has **no content schema** for this operation
(`"200": { "description": "OK" }`) [VERIFIED, both specs].

**Practical consequence:** if you POST only `{guid, indexerId}`, the 200 body is a `ReleaseResource`
where every other field is the .NET default (`"title": null`, `"size": 0`, `"quality": null`, …). Do **not**
parse the response as an authoritative release record. Treat HTTP 200 as "accepted" and ignore the body,
or at most log it. [VERIFIED from `return release;`]

### 3.2 Optional override fields

Sonarr (`ReleaseResource`, all `[JsonIgnore(WhenWritingDefault)]`):
`seriesId : int32?`, `episodeId : int32?`, `episodeIds : int32[]?`, `downloadClientId : int32?`,
`downloadClient : string?`, `shouldOverride : bool?`.
Radarr: `movieId : int32?`, `downloadClientId : int32?`, `downloadClient : string?`,
`shouldOverride : bool?`. [VERIFIED, `*-ReleaseResource.cs` + both specs]

`downloadClientId` selects a specific download client; otherwise one is chosen by protocol, indexer and
series/movie tags:

```csharp
var downloadClient = downloadClientId.HasValue
    ? _downloadClientProvider.Get(downloadClientId.Value)
    : _downloadClientProvider.GetDownloadClient(remoteEpisode.Release.DownloadProtocol,
        remoteEpisode.Release.IndexerId, filterBlockedClients, tags);
```
`verified: vendor/sonarr-DownloadService.cs`.

### 3.3 `shouldOverride` semantics — exactly what it requires

When `shouldOverride == true`, the controller hard-asserts the override inputs before cloning the cached
remote item:

**Sonarr** — requires `seriesId` non-null, `episodeIds` non-null **and non-empty**, `quality` non-null,
`languages` non-null:

```csharp
if (release.ShouldOverride == true)
{
    Ensure.That(release.SeriesId,   () => release.SeriesId).IsNotNull();
    Ensure.That(release.EpisodeIds, () => release.EpisodeIds).IsNotNull();
    Ensure.That(release.EpisodeIds, () => release.EpisodeIds).HasItems();
    Ensure.That(release.Quality,    () => release.Quality).IsNotNull();
    Ensure.That(release.Languages,  () => release.Languages).IsNotNull();
    // clones the cached RemoteEpisode, then:
    remoteEpisode.Series = _seriesService.GetSeries(release.SeriesId!.Value);
    remoteEpisode.Episodes = _episodeService.GetEpisodes(release.EpisodeIds);
    remoteEpisode.ParsedEpisodeInfo.Quality = release.Quality;
    remoteEpisode.Languages = release.Languages;
}
```
`verified: vendor/sonarr-ReleaseController.cs`.

**Radarr** — requires `movieId` non-null, `quality` non-null, `languages` non-null (no episode list):

```csharp
Ensure.That(release.MovieId,   () => release.MovieId).IsNotNull();
Ensure.That(release.Quality,   () => release.Quality).IsNotNull();
Ensure.That(release.Languages, () => release.Languages).IsNotNull();
```
`verified: vendor/radarr-ReleaseController.cs`.

So `shouldOverride` is how you force a release onto a specific series/episodes (or movie) **and** override
its parsed quality and languages — it is the API form of the UI's "override and grab". Note the override
does **not** let you bypass the cache (§3.4); it still requires the release to have been returned by a
prior search.

**When is `shouldOverride` needed?** Only when automatic mapping fails. The non-override path is:

- Sonarr: if the cached `remoteEpisode.Series == null`, it resolves via `release.EpisodeId` (→ its series),
  else via `release.SeriesId` (re-parsing episodes), else **404** `"Unable to find matching series and
  episodes, will need to be manually provided"`. If episodes are still empty → **404** `"Unable to parse
  episodes in the release, will need to be manually provided"`.
- Radarr: if `remoteMovie.Movie == null`, it resolves via `release.MovieId`, else **404** `"Unable to find
  matching movie, will need to be manually provided"`.

`verified: vendor/sonarr-ReleaseController.cs`, `verified: vendor/radarr-ReleaseController.cs`.

**Selectarr guidance:** because Selectarr searched by `episodeId` / `movieId`, the mapping is already
resolved server-side, so the plain `{guid, indexerId}` body normally suffices. Include
`episodeId`/`movieId` as a cheap safety net for unmapped releases, and reserve `shouldOverride` for an
explicit user "force grab" action.

### 3.4 The release cache — why a grab can fail with 404

Both controllers keep an in-memory cache of the search results and **require a hit** before grabbing:

```csharp
_remoteEpisodeCache = cacheManager.GetCache<RemoteEpisode>(GetType(), "remoteEpisodes");
// …
protected override ReleaseResource MapDecision(DownloadDecision decision, int initialWeight)
{
    var resource = base.MapDecision(decision, initialWeight);
    _remoteEpisodeCache.Set(GetCacheKey(resource), decision.RemoteEpisode, TimeSpan.FromMinutes(30));
    return resource;
}
private string GetCacheKey(ReleaseResource resource)
{
    return string.Concat(resource.IndexerId, "_", resource.Guid);
}
```
`verified: vendor/sonarr-ReleaseController.cs`; `verified: vendor/radarr-ReleaseController.cs` is identical
with `_remoteMovieCache` / `RemoteMovie`.

**Verified facts:**

- **Cache key = `indexerId + "_" + guid`.** Both values must match the search result byte-for-byte.
- **Cache TTL = 30 minutes** (`TimeSpan.FromMinutes(30)`), refreshed on each search that returns the
  release.
- The cache is populated **only** by `MapDecision`, i.e. only by `GET /api/v3/release` (episode/season/
  movie search *or* the RSS variant). **You cannot grab a `guid` you did not just search for.**
- Cache miss →

```csharp
if (remoteEpisode == null)
{
    _logger.Debug("Couldn't find requested release in cache, cache timeout probably expired.");
    throw new NzbDroneClientException(HttpStatusCode.NotFound,
        "Couldn't find requested release in cache, try searching again");
}
```

  i.e. **HTTP 404** with message `"Couldn't find requested release in cache, try searching again"`.
- The cache is in-process memory, so it is empty after a Sonarr/Radarr restart [INFERRED from
  `ICacheManager`/`ICached<T>` being an in-memory cache; no persistence code is present in the vendored
  controller].

**Selectarr design rule (important):** the search→select→grab round trip must complete **well inside 30
minutes**, and must reuse the exact `guid` and `indexerId` from the search response. If an LLM call is
slow, or a user approves a suggestion later, Selectarr must **re-run `GET /api/v3/release` immediately
before `POST`** and re-match its chosen release by `guid`; if the guid is gone, surface "release no longer
available, re-select".

### 3.5 Error catalogue for `POST /api/v3/release`

| status | condition | message |
| --- | --- | --- |
| 400 | `guid` empty or `indexerId` invalid | FluentValidation error body |
| 404 | cache miss / expired | `Couldn't find requested release in cache, try searching again` |
| 404 | Sonarr: cannot resolve series+episodes | `Unable to find matching series and episodes, will need to be manually provided` |
| 404 | Sonarr: episodes unparseable | `Unable to parse episodes in the release, will need to be manually provided` |
| 404 | Radarr: cannot resolve movie | `Unable to find matching movie, will need to be manually provided` |
| 409 | `ReleaseDownloadException` from the indexer/client | `Getting release from indexer failed` |
| 200 | success | echo of the posted body |

`verified: vendor/sonarr-ReleaseController.cs`, `verified: vendor/radarr-ReleaseController.cs`. The 400
row is [INFERRED] — the `PostValidator` rules are verified, the exact HTTP status/body shape of a
FluentValidation failure is Sonarr/Radarr framework behaviour not present in the vendored files.

Additional exceptions that propagate out of `DownloadService.DownloadReport` and are **not** caught as
`ReleaseDownloadException` by the controller: `DownloadClientUnavailableException` (no client configured
for the protocol), `ReleaseUnavailableException`, `ReleaseBlockedException` (previously blocklisted),
`DownloadClientRejectedReleaseException` (duplicate). `verified: vendor/sonarr-DownloadService.cs`. Their
HTTP mapping is [UNVERIFIED] (the global exception handler was not vendored) — Selectarr should treat any
non-200 as a failed grab and log the body.

### 3.6 Grabbing ignores rejections, quality profile and custom-format score — confirmed

**Confirmed, with direct evidence.** `DownloadRelease` never inspects `release.Rejected`,
`release.Approved`, `release.TemporarilyRejected`, `downloadAllowed`, or any profile. After resolving the
series/movie it goes straight to:

```csharp
await _downloadService.DownloadReport(remoteEpisode, release.DownloadClientId);
```
`verified: vendor/sonarr-ReleaseController.cs` / `vendor/radarr-ReleaseController.cs`.

And `DownloadService.DownloadReport` contains **no** quality-profile, cutoff, `minFormatScore`, or
decision-engine logic. Its full behaviour is: pick a download client → assert series+episodes non-empty →
compute seed configuration → rate-limit grabs to one per 2 s per host → resolve the indexer → call
`downloadClient.Download(...)` → record indexer/client success → publish `EpisodeGrabbedEvent`.
`verified: vendor/sonarr-DownloadService.cs`.

**Therefore:** a release with `"rejected": true` and a list of `rejections` **can still be grabbed** via
`POST /api/v3/release`, exactly as the interactive-search UI allows. `minFormatScore`,
`cutoffFormatScore`, the quality-profile `items[].allowed` flags and the cutoff are applied by the
*decision engine* when producing `approved`/`rejections` on **search**, not when grabbing. This is the
foundation of §6.5.

---

## 4. Media lookups

### 4.1 Sonarr — episodes

**`GET /api/v3/episode`** (tag `Episode`) → `EpisodeResource[]`. Query parameters
`verified: vendor/sonarr-openapi.json`:

| param | type | default |
| --- | --- | --- |
| `seriesId` | int32 | — |
| `seasonNumber` | int32 | — |
| `episodeIds` | int32[] | — |
| `episodeFileId` | int32 | — |
| `includeSeries` | bool | `false` |
| `includeEpisodeFile` | bool | `false` |
| `includeImages` | bool | `false` |

So `GET /api/v3/episode?seriesId=42&seasonNumber=2` is the documented way to list a season.

**`GET /api/v3/episode/{id}`** (path `id`, int32, required) → `EpisodeResource`.
**`PUT /api/v3/episode/{id}`** body `EpisodeResource` → `EpisodeResource`.
**`PUT /api/v3/episode/monitor?includeImages=false`** body `EpisodesMonitoredResource`
(`{ episodeIds: int32[]|null, monitored: bool }`) → `200`, no body.
[VERIFIED, `vendor/sonarr-openapi.json`]

Note: `GET /api/v3/episode/{id}` has **only** the `id` path parameter — `includeSeries` /
`includeEpisodeFile` are **not** accepted on the single-episode route. Use the list route with
`episodeIds` if you need the joined data. [VERIFIED from the spec's parameter lists]

**`EpisodeResource`** [VERIFIED, `vendor/sonarr-openapi.json`]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `seriesId` | int32 | no |
| `tvdbId` | int32 | no |
| `episodeFileId` | int32 | no |
| `seasonNumber` | int32 | no |
| `episodeNumber` | int32 | no |
| `title` | string | yes |
| `airDate` | string | yes |
| `airDateUtc` | string (date-time) | yes |
| `lastSearchTime` | string (date-time) | yes |
| `runtime` | int32 | no |
| `finaleType` | string | yes |
| `overview` | string | yes |
| `episodeFile` | `EpisodeFileResource` | object, present only with `includeEpisodeFile` |
| `hasFile` | bool | no |
| `monitored` | bool | no |
| `absoluteEpisodeNumber` | int32 | yes |
| `sceneAbsoluteEpisodeNumber` | int32 | yes |
| `sceneEpisodeNumber` | int32 | yes |
| `sceneSeasonNumber` | int32 | yes |
| `unverifiedSceneNumbering` | bool | no |
| `endTime` | string (date-time) | yes |
| `grabDate` | string (date-time) | yes |
| `series` | `SeriesResource` | object, present only with `includeSeries` |
| `images` | `MediaCover[]` | yes |

`lastSearchTime`, `grabDate`, `endTime`, `finaleType` are worth noting — they are not in the brief but are
directly useful: `lastSearchTime` lets Selectarr rate-limit its own re-searching, `grabDate` indicates a
pending grab.

**`EpisodeFileResource`** [VERIFIED, `vendor/sonarr-openapi.json`]:
`id: int32`, `seriesId: int32`, `seasonNumber: int32`, `relativePath: string?`, `path: string?`,
`size: int64`, `dateAdded: date-time`, `sceneName: string?`, `releaseGroup: string?`,
`languages: Language[]?`, `quality: QualityModel`, `customFormats: CustomFormatResource[]?`,
`customFormatScore: int32`, `indexerFlags: int32?`, `releaseType: ReleaseType`,
`mediaInfo: MediaInfoResource`, `qualityCutoffNotMet: bool`.

`ReleaseType` enum (Sonarr only): `"unknown" | "singleEpisode" | "multiEpisode" | "seasonPack"`
[VERIFIED].

### 4.2 Sonarr — series

**`GET /api/v3/series/{id}`** → `SeriesResource`; also `GET /api/v3/series/lookup?term=…` →
`SeriesResource[]`, `POST /api/v3/series/import` (array of `SeriesResource`),
`PUT /api/v3/series/editor` (`SeriesEditorResource`). [VERIFIED, `vendor/sonarr-openapi.json`]

**`SeriesResource`** [VERIFIED]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `title` | string | yes |
| `alternateTitles` | `AlternateTitleResource[]` | yes |
| `sortTitle` | string | yes |
| `status` | `SeriesStatusType` | no |
| `ended` | bool | no, `readOnly` |
| `profileName` | string | yes |
| `overview` | string | yes |
| `nextAiring` | date-time | yes |
| `previousAiring` | date-time | yes |
| `network` | string | yes |
| `airTime` | string | yes |
| `images` | `MediaCover[]` | yes |
| `originalLanguage` | `Language` | object |
| `remotePoster` | string | yes |
| `seasons` | `SeasonResource[]` | yes |
| `year` | int32 | no |
| `path` | string | yes |
| `qualityProfileId` | int32 | no |
| `seasonFolder` | bool | no |
| `monitored` | bool | no |
| `monitorNewItems` | `NewItemMonitorTypes` | no |
| `useSceneNumbering` | bool | no |
| `runtime` | int32 | no |
| `tvdbId` | int32 | no |
| `tvRageId` | int32 | no |
| `tvMazeId` | int32 | no |
| `tmdbId` | int32 | no |
| `firstAired` | date-time | yes |
| `lastAired` | date-time | yes |
| `seriesType` | `SeriesTypes` | no |
| `cleanTitle` | string | yes |
| `imdbId` | string | yes |
| `titleSlug` | string | yes |
| `rootFolderPath` | string | yes |
| `folder` | string | yes |
| `certification` | string | yes |
| `genres` | string[] | yes |
| `tags` | int32[] (`uniqueItems`) | yes |
| `added` | date-time | no |
| `addOptions` | `AddSeriesOptions` | object |
| `ratings` | `Ratings` | object |
| `statistics` | `SeriesStatisticsResource` | object |
| `episodesChanged` | bool | yes |
| `languageProfileId` | int32 | no, **`readOnly` + `deprecated`** |

Answer to the brief's question about `languageProfileId`: it **still exists** on Sonarr's
`SeriesResource` but is marked `"readOnly": true, "deprecated": true`. Do not send it; treat it as
vestigial. [VERIFIED]

Supporting types [VERIFIED, `vendor/sonarr-openapi.json`]:

- `SeriesStatusType`: `"continuing" | "ended" | "upcoming" | "deleted"`
- `SeriesTypes`: `"standard" | "daily" | "anime"`
- `NewItemMonitorTypes`: `"all" | "none"`
- `AddSeriesOptions`: `ignoreEpisodesWithFiles: bool`, `ignoreEpisodesWithoutFiles: bool`,
  `monitor: MonitorTypes`, `searchForMissingEpisodes: bool`, `searchForCutoffUnmetEpisodes: bool`
- `SeasonResource`: `seasonNumber: int32`, `monitored: bool`,
  `statistics: SeasonStatisticsResource`, `images: MediaCover[]?`
- `SeasonStatisticsResource`: `nextAiring: date-time?`, `previousAiring: date-time?`,
  `episodeFileCount: int32`, `episodeCount: int32`, `totalEpisodeCount: int32`, `sizeOnDisk: int64`,
  `releaseGroups: string[]?`, `percentOfEpisodes: double` (`readOnly`)
- `SeriesStatisticsResource`: `seasonCount: int32`, `episodeFileCount: int32`, `episodeCount: int32`,
  `totalEpisodeCount: int32`, `sizeOnDisk: int64`, `releaseGroups: string[]?`,
  `percentOfEpisodes: double` (`readOnly`)
- **Sonarr `Ratings`**: `votes: int32`, `value: double` — a flat object

`MediaCover` field names are **[UNVERIFIED]** — the schema body was not in any window I read. Check
`components.schemas.MediaCover` in
`https://raw.githubusercontent.com/Sonarr/Sonarr/develop/src/Sonarr.Api.V3/openapi.json`.
(Conventionally `coverType`, `url`, `remoteUrl`, but I did not confirm it.)

### 4.3 Sonarr — wanted / missing and cutoff-unmet

**`GET /api/v3/wanted/missing`** (tag `Missing`) → `EpisodeResourcePagingResource`:

| param | type | default |
| --- | --- | --- |
| `page` | int32 | `1` |
| `pageSize` | int32 | `10` |
| `sortKey` | string | — |
| `sortDirection` | `SortDirection` | — |
| `includeSeries` | bool | `false` |
| `includeImages` | bool | `false` |
| `monitored` | bool | **`true`** |

**`GET /api/v3/wanted/cutoff`** (tag `Cutoff`) → `EpisodeResourcePagingResource`:

| param | type | default |
| --- | --- | --- |
| `page` | int32 | `1` |
| `pageSize` | int32 | `10` |
| `sortKey` | string | — |
| `sortDirection` | `SortDirection` | — |
| `includeSeries` | bool | `false` |
| **`includeEpisodeFile`** | bool | `false` |
| `includeImages` | bool | `false` |
| `monitored` | bool | **`true`** |

**Correction to the brief:** `wanted/missing` does **not** accept `includeEpisodeFile`; only
`wanted/cutoff` does. That is logical (a missing episode has no file). Sending an unknown query param is
harmless but the field will never populate. [VERIFIED, `vendor/sonarr-openapi.json`]

Also available: `GET /api/v3/wanted/missing/{id}` and `GET /api/v3/wanted/cutoff/{id}`, each taking only
`id: int32` and returning a single `EpisodeResource`. [VERIFIED]

`EpisodeResourcePagingResource` [VERIFIED]:
`page: int32`, `pageSize: int32`, `sortKey: string?`, `sortDirection: SortDirection`,
`totalRecords: int32`, `records: EpisodeResource[]?`.

`SortDirection`: `"default" | "ascending" | "descending"` [VERIFIED, both apps].

`monitored` defaults to `true`, i.e. by default these endpoints only return monitored items — which is
exactly what Selectarr wants. `sortKey` is a free-form string (the spec does not enumerate valid keys);
valid values are [UNVERIFIED] — safest is to omit `sortKey` and rely on the default ordering, or use
`airDateUtc` for Sonarr / `title` for Radarr and verify against a live instance.

### 4.4 Radarr — movies

**`GET /api/v3/movie`** (tag `Movie`) → `MovieResource[]`. Query parameters [VERIFIED,
`vendor/radarr-openapi.json`]: `tmdbId: int32`, `excludeLocalCovers: bool = false`,
`languageId: int32`. With no parameters it returns the **entire library**.

**`POST /api/v3/movie`** body `MovieResource` → `MovieResource`.
**`GET /api/v3/movie/{id}`** → `MovieResource`; `PUT /api/v3/movie/{id}`; the `{id}` route exists and is
`verified: vendor/radarr-openapi.json` (path `/api/v3/movie/{id}`). Its precise parameter list beyond the
`id` path parameter is [INFERRED] as `id` only — the `get` operation body fell outside my read window.

**`MovieResource`** [VERIFIED, `vendor/radarr-openapi.json`]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `title` | string | yes |
| `originalTitle` | string | yes |
| `originalLanguage` | `Language` | object |
| `alternateTitles` | `AlternativeTitleResource[]` | yes |
| `secondaryYear` | int32 | yes |
| `secondaryYearSourceId` | int32 | no |
| `sortTitle` | string | yes |
| `sizeOnDisk` | **int64** | yes |
| `status` | `MovieStatusType` | no |
| `overview` | string | yes |
| `inCinemas` | date-time | yes |
| `physicalRelease` | date-time | yes |
| `digitalRelease` | date-time | yes |
| `releaseDate` | date-time | yes |
| `physicalReleaseNote` | string | yes |
| `images` | `MediaCover[]` | yes |
| `website` | string | yes |
| `remotePoster` | string | yes |
| `year` | int32 | no |
| `youTubeTrailerId` | string | yes |
| `studio` | string | yes |
| `path` | string | yes |
| `qualityProfileId` | int32 | no |
| `hasFile` | bool | **yes** (nullable!) |
| `movieFileId` | int32 | no |
| `monitored` | bool | no |
| `minimumAvailability` | `MovieStatusType` | no |
| `isAvailable` | bool | no |
| `folderName` | string | yes |
| `runtime` | int32 | no |
| `cleanTitle` | string | yes |
| `imdbId` | **string** | yes |
| `tmdbId` | int32 | no |
| `titleSlug` | string | yes |
| `rootFolderPath` | string | yes |
| `folder` | string | yes |
| `certification` | string | yes |
| `genres` | string[] | yes |
| `keywords` | string[] | yes |
| `tags` | int32[] (`uniqueItems`) | yes |
| `added` | date-time | no |
| `addOptions` | `AddMovieOptions` | object |
| `ratings` | `Ratings` | object — **Radarr shape, see below** |
| `movieFile` | `MovieFileResource` | object |
| `collection` | `MovieCollectionResource` | object |
| `popularity` | **number (float)** | no |
| `lastSearchTime` | date-time | yes |
| `statistics` | `MovieStatisticsResource` | object |

Note `MovieResource.imdbId` is a **string** (unlike `ReleaseResource.imdbId` in the same app, which is an
`int32`). This inconsistency is real and verified in the spec. Also note `hasFile` is nullable.

Supporting types [VERIFIED, `vendor/radarr-openapi.json`]:

- `MovieStatusType`: `"tba" | "announced" | "inCinemas" | "released" | "deleted"` — used for both
  `status` and `minimumAvailability`
- `MovieCollectionResource`: `title: string?`, `tmdbId: int32` (that is all — no `id`, no images)
- `MovieStatisticsResource`: `movieFileCount: int32`, `sizeOnDisk: int64`, `releaseGroups: string[]?`
- `MovieRuntimeFormatType`: `"hoursMinutes" | "minutes"`
- `MonitorTypes` (Radarr): `"movieOnly" | "movieAndCollection" | "none"`
- **Radarr `Ratings` is NOT the Sonarr shape.** It is:
  `{ imdb: RatingChild, tmdb: RatingChild, metacritic: RatingChild, rottenTomatoes: RatingChild, trakt: RatingChild }`
  with `RatingChild = { votes: int32, value: double, type: RatingType }` and
  `RatingType = "user" | "critic"`. Sonarr's is `{ votes: int32, value: double }`. **Separate OCaml
  types required.**
- `MovieFileResource`: `id: int32`, `movieId: int32`, `relativePath: string?`, `path: string?`,
  `size: int64`, `dateAdded: date-time`, `sceneName: string?`, `releaseGroup: string?`,
  `edition: string?`, `languages: Language[]?`, `quality: QualityModel`,
  `customFormats: CustomFormatResource[]?`, `customFormatScore: int32?` (nullable here, non-null in
  Sonarr's `EpisodeFileResource`), `indexerFlags: int32?`, `mediaInfo: MediaInfoResource`,
  `originalFilePath: string?`, `qualityCutoffNotMet: bool`

`AlternativeTitleResource` (Radarr) — partially verified: it contains at least
`tmdbId: int32`, `hardcodedSubs: string?`, `movieTitle: string?` (`readOnly`),
`primaryMovieTitle: string?` (`readOnly`), plus earlier fields that fell outside my read window
(conventionally `id`, `sourceType`, `movieMetadataId`, `title`). The leading fields are
**[UNVERIFIED]** — check `components.schemas.AlternativeTitleResource` in the Radarr spec.
Note the Radarr type is spelled `Alternative…` whereas Sonarr's is `Alternate…`.

`AddMovieOptions` and `MediaCover` field names are **[UNVERIFIED]** for Radarr (not in my read windows).

### 4.5 Radarr — wanted / missing and cutoff

Both are far simpler than Sonarr's. [VERIFIED, `vendor/radarr-openapi.json`]

**`GET /api/v3/wanted/missing`** (tag `Missing`) and **`GET /api/v3/wanted/cutoff`** (tag `Cutoff`), each
→ `MovieResourcePagingResource`, with **exactly these parameters**:

| param | type | default |
| --- | --- | --- |
| `page` | int32 | `1` |
| `pageSize` | int32 | `10` |
| `sortKey` | string | — |
| `sortDirection` | `SortDirection` | — |
| `monitored` | bool | **`true`** |

There is **no** `includeMovie` / `includeImages` on either Radarr wanted endpoint — the records are full
`MovieResource` objects already. [VERIFIED]

`MovieResourcePagingResource`: `page: int32`, `pageSize: int32`, `sortKey: string?`,
`sortDirection: SortDirection`, `totalRecords: int32`, `records: MovieResource[]?` [VERIFIED].

---

## 5. Quality profiles and custom formats

### 5.1 Endpoints (identical paths in both apps)

[VERIFIED, both specs]

| method + path | body | returns | tag |
| --- | --- | --- | --- |
| `GET /api/v3/qualityprofile` | — | `QualityProfileResource[]` | `QualityProfile` |
| `POST /api/v3/qualityprofile` | `QualityProfileResource` | `QualityProfileResource` | `QualityProfile` |
| `GET /api/v3/qualityprofile/{id}` | — (`id` int32) | `QualityProfileResource` | `QualityProfile` |
| `PUT /api/v3/qualityprofile/{id}` | `QualityProfileResource` | `QualityProfileResource` | `QualityProfile` |
| `DELETE /api/v3/qualityprofile/{id}` | — | `200` | `QualityProfile` |
| `GET /api/v3/qualityprofile/schema` | — | `QualityProfileResource` | `QualityProfileSchema` |
| `GET /api/v3/customformat` | — | `CustomFormatResource[]` | `CustomFormat` |
| `POST /api/v3/customformat` | `CustomFormatResource` | `CustomFormatResource` | `CustomFormat` |
| `GET /api/v3/customformat/{id}` | — | `CustomFormatResource` | `CustomFormat` |
| `PUT /api/v3/customformat/{id}` | `CustomFormatResource` | `CustomFormatResource` | `CustomFormat` |
| `DELETE /api/v3/customformat/{id}` | — | `200` | `CustomFormat` |
| `PUT /api/v3/customformat/bulk` | `CustomFormatBulkResource` | `CustomFormatResource` | `CustomFormat` |
| `DELETE /api/v3/customformat/bulk` | `CustomFormatBulkResource` | `200` | `CustomFormat` |
| `GET /api/v3/customformat/schema` | — | `200` (no schema declared) | `CustomFormat` |
| `GET /api/v3/qualitydefinition` | — | `QualityDefinitionResource[]` | `QualityDefinition` |
| `GET /api/v3/qualitydefinition/{id}` | — | `QualityDefinitionResource` | `QualityDefinition` |
| `PUT /api/v3/qualitydefinition/update` | `QualityDefinitionResource[]` | `200` | `QualityDefinition` |
| `GET /api/v3/qualitydefinition/limits` | — | `QualityDefinitionLimitsResource` | `QualityDefinition` |

Note `PUT /api/v3/qualityprofile/{id}` declares its `id` path parameter as **`type: string`** in both
specs (a quirk of the generator), while `GET`/`DELETE` declare `int32`. Send the integer either way.
[VERIFIED]

### 5.2 `QualityProfileResource`

| field | type | nullable | Sonarr | Radarr |
| --- | --- | --- | --- | --- |
| `id` | int32 | no | yes | yes |
| `name` | string | yes | yes | yes |
| `upgradeAllowed` | bool | no | yes | yes |
| `cutoff` | int32 | no | yes | yes |
| `items` | `QualityProfileQualityItemResource[]` | yes | yes | yes |
| `minFormatScore` | int32 | no | yes | yes |
| `cutoffFormatScore` | int32 | no | yes | yes |
| `minUpgradeFormatScore` | int32 | no | yes | yes |
| `formatItems` | `ProfileFormatItemResource[]` | yes | yes | yes |
| `language` | `Language` | object | **absent** | **present** |

`verified: vendor/sonarr-openapi.json`, `verified: vendor/radarr-openapi.json`.

Two corrections to the brief: `minUpgradeFormatScore` exists in **both** apps (it was not in the brief's
list), and `language` exists **only in Radarr** — Sonarr has no `language` on the quality profile
(language is handled by custom formats since v4).

`cutoff` is a **quality id** (an `int32` referring to the tables in §2.6), not a nested object.
[VERIFIED — `"cutoff": { "type": "integer", "format": "int32" }`]

**`QualityProfileQualityItemResource`** (recursive, for quality groups) [VERIFIED, both]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `name` | string | yes |
| `quality` | `Quality` | object |
| `items` | `QualityProfileQualityItemResource[]` | yes |
| `allowed` | bool | no |

Semantics: a leaf item has `quality` set and `items: []`; a *group* has `name` set, `quality` null-ish, and
nested `items`. `allowed` is the "is this quality wanted" checkbox. [INFERRED from the recursive shape and
the presence of both `name` and `quality`; the grouping logic itself is in `QualityProfile.cs`, which was
not vendored.]

**`ProfileFormatItemResource`** [VERIFIED, both]:
`id: int32`, `format: int32` (the custom-format id), `name: string?`, `score: int32`.

### 5.3 `CustomFormatResource`

[VERIFIED, both specs — identical in Sonarr and Radarr]

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `name` | string | yes |
| `includeCustomFormatWhenRenaming` | bool | **yes** |
| `specifications` | `CustomFormatSpecificationSchema[]` | yes |

**Important for Selectarr:** the `customFormats` array embedded in a `ReleaseResource` is produced by
`remoteEpisode.CustomFormats?.ToResource(false)` / `remoteMovie.CustomFormats.ToResource(false)`
(`verified: vendor/sonarr-ReleaseResource.cs`, `vendor/radarr-ReleaseResource.cs`). The `false` argument
suppresses the heavy part, so in a release payload you should expect `id` + `name` populated and
`specifications` empty or omitted. [INFERRED from the `ToResource(false)` call — the mapper body was not
vendored, but the boolean is clearly an "include specifications" switch.] Rely on `id`/`name` only.

**`CustomFormatSpecificationSchema`** [VERIFIED, Sonarr spec]:
`id: int32`, `name: string?`, `implementation: string?`, `implementationName: string?`,
`infoLink: string?`, `negate: bool`, `required: bool`, `fields: Field[]?`,
`presets: CustomFormatSpecificationSchema[]?`.

**`CustomFormatBulkResource`** [VERIFIED, both]:
`ids: int32[]? (uniqueItems)`, `includeCustomFormatWhenRenaming: bool?`.

**`Field`** (used by custom-format specifications, indexers, download clients, notifications)
[VERIFIED, Sonarr spec]:
`order: int32`, `name: string?`, `label: string?`, `unit: string?`, `helpText: string?`,
`helpTextWarning: string?`, `helpLink: string?`, `value: <untyped, nullable>`, `type: string?`,
`advanced: bool`, `selectOptions: SelectOption[]?`, `selectOptionsProviderAction: string?`,
`section: string?`, `hidden: string?`, `privacy: PrivacyLevel`, `placeholder: string?`, `isFloat: bool`.

`value` has **no declared type** — decode as `Yojson.Safe.t`. `hidden` is a **string**, not a bool.
`PrivacyLevel`: `"normal" | "password" | "apiKey" | "userName"` [VERIFIED].

`SelectOption`: Sonarr `{ value: int32, name: string?, order: int32, hint: string? }`; Radarr adds
`dividerAfter: bool` [VERIFIED, both specs].

### 5.4 `QualityDefinitionResource`

[VERIFIED, both specs]
`id: int32`, `quality: Quality`, `title: string?`, `weight: int32`, `minSize: double?`,
`maxSize: double?`, `preferredSize: double?`.
`QualityDefinitionLimitsResource`: `min: int32`, `max: int32`.

Sizes are in **MB per hour** for Sonarr and **MB** for Radarr [UNVERIFIED units — the vendored
`sonarr-Quality.cs` shows default values like `MinSize = 4, MaxSize = 130, PreferredSize = 95` for
`WEBDL-1080p` which is consistent with MB/hour, but the unit is not stated in any vendored file. Check
`https://wiki.servarr.com/sonarr/settings#quality`.] Useful for a size-sanity hard rule; treat the unit as
configuration, not a constant.

---

## 6. Automatic mode — how a sidecar can take over release selection

This section is the heart of the Selectarr design question. I have split it strictly into
**[VERIFIED]** mechanics and **design recommendation**.

### 6.1 Webhooks — configuration and event set

A Webhook is a *Notification* provider. Configure via
`GET/POST /api/v3/notification`, `PUT /api/v3/notification/{id}`,
`POST /api/v3/notification/test` (with `?forceTest=`), `GET /api/v3/notification/schema`.
[Paths follow the same `Notification`-tag pattern as the other providers; the `NotificationResource`
schema itself is VERIFIED below. The exact notification path list is **[INFERRED]** — I verified the
schema but not every `/api/v3/notification*` path.]

**`NotificationResource` event toggles** [VERIFIED, both specs]:

| Sonarr | Radarr |
| --- | --- |
| `onGrab` | `onGrab` |
| `onDownload` | `onDownload` |
| `onUpgrade` | `onUpgrade` |
| `onImportComplete` | — |
| `onRename` | `onRename` |
| `onSeriesAdd` | `onMovieAdded` |
| `onSeriesDelete` | `onMovieDelete` |
| `onEpisodeFileDelete` | `onMovieFileDelete` |
| `onEpisodeFileDeleteForUpgrade` | `onMovieFileDeleteForUpgrade` |
| `onHealthIssue` | `onHealthIssue` |
| `includeHealthWarnings` | `includeHealthWarnings` |
| `onHealthRestored` | `onHealthRestored` |
| `onApplicationUpdate` | `onApplicationUpdate` |
| `onManualInteractionRequired` | `onManualInteractionRequired` |

Each has a matching read-only `supportsOnX` boolean. Sonarr additionally exposes `testCommand: string?`.
Common provider fields on `NotificationResource`: `id`, `name`, `fields: Field[]`, `implementationName`,
`implementation`, `configContract`, `infoLink`, `message: ProviderMessage`, `tags: int32[]`,
`presets: NotificationResource[]`, `link: string?`. [VERIFIED, both specs]

`ProviderMessage`: `{ message: string?, type: ProviderMessageType }`,
`ProviderMessageType`: `"info" | "warning" | "error"` [VERIFIED].

**The `WebhookEventType` enum — and its serialization.** This is subtle and matters:

```csharp
// TODO: In v4 this will likely be changed to the default camel case.
[JsonConverter(typeof(StringEnumConverter), converterParameters: typeof(DefaultNamingStrategy))]
public enum WebhookEventType
{
    Test, Grab, Download, Rename, SeriesAdd, SeriesDelete,
    EpisodeFileDelete, Health, ApplicationUpdate, HealthRestored, ManualInteractionRequired
}
```
`verified: vendor/sonarr-WebhookEventType.cs`

```csharp
[JsonConverter(typeof(StringEnumConverter), converterParameters: typeof(DefaultNamingStrategy))]
public enum WebhookEventType
{
    Test, Grab, Download, Rename, MovieDelete, MovieFileDelete,
    Health, ApplicationUpdate, MovieAdded, HealthRestored, ManualInteractionRequired
}
```
`verified: vendor/radarr-WebhookEventType.cs`

**Consequences (all [VERIFIED] from those two files):**

1. `eventType` is serialized **PascalCase** — `"Grab"`, `"Download"`, `"SeriesAdd"`,
   `"ManualInteractionRequired"`, `"Test"` — because `DefaultNamingStrategy` is explicitly passed to the
   `StringEnumConverter`. The rest of the payload uses camelCase property names [INFERRED — strongly
   supported by the source comment "In v4 this will likely be changed to the default camel case", which
   only makes sense if camelCase is the serializer default applied elsewhere; the webhook serializer
   settings file was not vendored].
2. **There is no `Upgrade` event type.** Upgrades arrive as `eventType: "Download"` with
   `isUpgrade: true`. `verified: vendor/sonarr-webhook/WebhookBase.cs`
   (`IsUpgrade = message.OldFiles.Any()` on a payload whose `EventType = WebhookEventType.Download`).
3. **Sonarr's "import complete" also uses `eventType: "Download"`**, not a distinct value:
   `BuildOnImportCompletePayload` sets `EventType = WebhookEventType.Download` and emits
   `WebhookImportCompletePayload`. So a consumer seeing `"Download"` must disambiguate by shape:
   `episodeFile` (+ optional `deletedFiles`, `isUpgrade`) = per-file import; `episodeFiles` (plural,
   + `sourcePath`, `destinationPath`) = import complete. `verified: vendor/sonarr-webhook/WebhookBase.cs`
4. Sonarr has `SeriesAdd`/`SeriesDelete`/`EpisodeFileDelete`; Radarr has
   `MovieAdded`/`MovieDelete`/`MovieFileDelete`. Note the asymmetric naming (`SeriesAdd` vs `MovieAdded`).
5. The brief's expected `"Upgrade"` and `"MovieAdded"`-for-Sonarr do not exist; `"Rename"`, `"Health"`,
   `"HealthRestored"`, `"ApplicationUpdate"`, `"ManualInteractionRequired"`, `"Test"` all do.

### 6.2 Exact webhook payload shapes

Base class, inherited by every payload [VERIFIED, `vendor/sonarr-webhook/WebhookPayload.cs`]:

```csharp
public class WebhookPayload
{
    public WebhookEventType EventType { get; set; }
    public string InstanceName { get; set; }
    public string ApplicationUrl { get; set; }
}
```
→ JSON `eventType`, `instanceName`, `applicationUrl`.

**Caveat on `applicationUrl`** [VERIFIED, `vendor/sonarr-webhook/WebhookBase.cs`,
`vendor/radarr-webhook/WebhookBase.cs`]: it is **not set** on some payloads.
Sonarr's `BuildHealthPayload`, `BuildHealthRestoredPayload` and `BuildApplicationUpdatePayload` set only
`InstanceName`. Radarr sets `ApplicationUrl` on Health and ApplicationUpdate but **not** on
HealthRestored. So decode `applicationUrl` as an `option`.

**Sonarr `WebhookGrabPayload`** [VERIFIED, `vendor/sonarr-webhook/WebhookGrabPayload.cs`]:

```csharp
public WebhookSeries Series { get; set; }
public List<WebhookEpisode> Episodes { get; set; }
public WebhookRelease Release { get; set; }
public string DownloadClient { get; set; }
public string DownloadClientType { get; set; }
public string DownloadId { get; set; }
public WebhookCustomFormatInfo CustomFormatInfo { get; set; }
```

**Radarr `WebhookGrabPayload`** [VERIFIED, `vendor/radarr-webhook/WebhookGrabPayload.cs`]:

```csharp
public WebhookMovie Movie { get; set; }
public WebhookRemoteMovie RemoteMovie { get; set; }
public WebhookRelease Release { get; set; }
public string DownloadClient { get; set; }
public string DownloadClientType { get; set; }
public string DownloadId { get; set; }
public WebhookCustomFormatInfo CustomFormatInfo { get; set; }
```

**`WebhookSeries`** [VERIFIED, `vendor/sonarr-webhook/WebhookSeries.cs`] — JSON order = declaration order:
`id: int`, `title: string`, `titleSlug: string`, `path: string`, `tvdbId: int`, `tvMazeId: int`,
`tmdbId: int`, `imdbId: string`, `type: SeriesTypes`, `year: int`, `genres: string[]`,
`images: WebhookImage[]`, `tags: string[]`, `originalLanguage: Language`.

**`tags` are tag *labels*, not ids.** `verified: vendor/sonarr-webhook/WebhookBase.cs`:

```csharp
return _tagRepository.GetTags(series.Tags).Select(s => s.Label)
    .Where(l => l.IsNotNullOrWhiteSpace()).OrderBy(l => l).ToList();
```

Sorted alphabetically. Same for Radarr's `WebhookMovie.tags`
(`verified: vendor/radarr-webhook/WebhookBase.cs`). This differs from the REST API, where `tags` are
`int32[]`. Do **not** share a decoder.

**`WebhookEpisode`** [VERIFIED, `vendor/sonarr-webhook/WebhookEpisode.cs`]:
`id: int`, `episodeNumber: int`, `seasonNumber: int`, `title: string`, `overview: string`,
`airDate: string`, `airDateUtc: DateTime?`, `seriesId: int`, `tvdbId: int`.
(Note declaration order puts `episodeNumber` before `seasonNumber`.)

**`WebhookRelease` — differs between apps.**

Sonarr [VERIFIED, `vendor/sonarr-webhook/WebhookRelease.cs`]:
`quality: string` (= `quality.Quality.Name`), `qualityVersion: int` (= `quality.Revision.Version`),
`releaseGroup: string`, `releaseTitle: string`, `indexer: string`, `size: long`,
`customFormatScore: int`, `customFormats: string[]`, `languages: Language[]`.
**No `indexerFlags`.**

Radarr [VERIFIED, `vendor/radarr-webhook/WebhookRelease.cs`]: all of the above **plus**
`indexerFlags: string[]`, built as
`Enum.GetValues(typeof(IndexerFlags)).Cast<IndexerFlags>().Where(f => (remoteMovie.Release.IndexerFlags & f) == f).Select(f => f.ToString()).ToList()`.

So the brief's expected `release.indexerFlags` exists in **Radarr only**, and it is a list of flag-name
strings. Also note `quality` here is a **string name**, not a `QualityModel` — quite different from the
REST `ReleaseResource`.

**`WebhookCustomFormatInfo`** [VERIFIED, `vendor/sonarr-webhook/WebhookCustomFormatInfo.cs`]:
`customFormats: WebhookCustomFormat[]`, `customFormatScore: int`.
`WebhookCustomFormat`'s own fields are **[UNVERIFIED]** (`WebhookCustomFormat.cs` not vendored);
conventionally `{ id, name }`. Check
`https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/Notifications/Webhook/WebhookCustomFormat.cs`.

**`WebhookMovie`** [VERIFIED, `vendor/radarr-webhook/WebhookMovie.cs`]:
`id: int`, `title: string`, `year: int`, `filePath: string`, `releaseDate: string`,
`folderPath: string`, `tmdbId: int`, `imdbId: string`, `overview: string`, `genres: string[]`,
`images: WebhookImage[]`, `tags: string[]`, `originalLanguage: Language`.

- `releaseDate` is a **`"yyyy-MM-dd"` string**, produced by
  `movie.MovieMetadata.Value.PhysicalReleaseDate().ToString("yyyy-MM-dd")` — not an ISO date-time.
- `folderPath` = `movie.Path`. `filePath` is only set by the `(movie, movieFile, tags)` constructor, i.e.
  on file-related events, not on Grab.
- The brief's expected `movie.imdbId`/`tmdbId`/`overview`/`genres`/`tags` all exist; there is **no**
  `movie.releaseDate` as a date-time and **no** `movie.titleSlug`.

**`WebhookRemoteMovie`** [VERIFIED, `vendor/radarr-webhook/WebhookRemoteMovie.cs`]:
`tmdbId: int`, `imdbId: string`, `title: string`, `year: int`.

**`WebhookImage`** fields are **[UNVERIFIED]** (`WebhookImage.cs` not vendored). Check
`https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/Notifications/Webhook/WebhookImage.cs`.

Other Sonarr payloads [VERIFIED, `vendor/sonarr-webhook/WebhookBase.cs`], by builder:

- `Download` (per-file import) → `series`, `episodes[]`, `episodeFile` (+ `sourcePath`),
  `release: WebhookGrabbedRelease`, `isUpgrade: bool`, `downloadClient`, `downloadClientType`,
  `downloadId`, `customFormatInfo`, and if it was an upgrade, `deletedFiles[]` (each with `path` and
  `recycleBinPath`).
- `Download` (import complete) → `series`, `episodes[]`, `episodeFiles[]`,
  `release: WebhookGrabbedRelease`, `downloadClient`, `downloadClientType`, `downloadId`,
  `sourcePath`, `destinationPath`.
- `EpisodeFileDelete` → `series`, `episodes[]`, `episodeFile`, `deleteReason`.
- `SeriesAdd` → `series` only.
- `SeriesDelete` → `series`, `deletedFiles: bool`.
- `Rename` → `series`, `renamedEpisodeFiles[]`.
- `Health` / `HealthRestored` → `level` (`HealthCheckResult`), `message`, `type` (health check source
  name), `wikiUrl` (string). **No `series`, no `applicationUrl`.**
- `ApplicationUpdate` → `message`, `previousVersion`, `newVersion`.
- `ManualInteractionRequired` → `series`, `episodes[]`, `downloadInfo`, `downloadClient`,
  `downloadClientType`, `downloadId`, `downloadStatus`, `downloadStatusMessages[]`,
  `customFormatInfo`, `release: WebhookGrabbedRelease`.

Radarr equivalents [VERIFIED, `vendor/radarr-webhook/WebhookBase.cs`]: `Download` →
`movie`, `remoteMovie`, `movieFile` (+`sourcePath`), `release`, `isUpgrade`, `downloadClient`,
`downloadClientType`, `downloadId`, `customFormatInfo`, optional `deletedFiles[]`;
`MovieAdded` → `movie`, `addMethod`; `MovieFileDelete` → `movie`, `movieFile`, `deleteReason`;
`MovieDelete` → `movie`, `deletedFiles: bool`, and `movieFolderSize: long` when files were deleted;
`Rename` → `movie`, `renamedMovieFiles[]`.

`HealthCheckResult`: `"ok" | "notice" | "warning" | "error"` [VERIFIED, Sonarr spec].

#### Webhook **Grab** payload — Sonarr (realistic, exact field names)

```json
{
  "eventType": "Grab",
  "instanceName": "Sonarr",
  "applicationUrl": "https://sonarr.example.com",
  "series": {
    "id": 42,
    "title": "The Example Show",
    "titleSlug": "the-example-show",
    "path": "/tv/The Example Show",
    "tvdbId": 123456,
    "tvMazeId": 7890,
    "tmdbId": 54321,
    "imdbId": "tt1234567",
    "type": "standard",
    "year": 2021,
    "genres": [ "Drama", "Thriller" ],
    "images": [
      { "coverType": "poster", "url": "/MediaCover/42/poster.jpg", "remoteUrl": "https://artworks.thetvdb.com/banners/posters/123456-1.jpg" }
    ],
    "tags": [ "4k", "selectarr" ],
    "originalLanguage": { "id": 1, "name": "English" }
  },
  "episodes": [
    {
      "id": 12345,
      "episodeNumber": 5,
      "seasonNumber": 2,
      "title": "The Episode Title",
      "overview": "Something happens to someone.",
      "airDate": "2024-05-07",
      "airDateUtc": "2024-05-08T01:00:00Z",
      "seriesId": 42,
      "tvdbId": 9876543
    }
  ],
  "release": {
    "quality": "WEBDL-1080p",
    "qualityVersion": 1,
    "releaseGroup": "NTb",
    "releaseTitle": "The.Example.Show.S02E05.The.Episode.Title.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb",
    "indexer": "Example Indexer (Prowlarr)",
    "size": 3221225472,
    "customFormatScore": 1600,
    "customFormats": [ "WEB Tier 01", "DD+" ],
    "languages": [ { "id": 1, "name": "English" } ]
  },
  "downloadClient": "qBittorrent",
  "downloadClientType": "qBittorrent",
  "downloadId": "F1E2D3C4B5A6978869504132231425364758697A",
  "customFormatInfo": {
    "customFormats": [ { "id": 7, "name": "WEB Tier 01" }, { "id": 9, "name": "DD+" } ],
    "customFormatScore": 1600
  }
}
```

The `images[]` entries and `customFormatInfo.customFormats[]` entries use the **[UNVERIFIED]**
`WebhookImage` / `WebhookCustomFormat` field names noted above; everything else in this example is
[VERIFIED].

#### Webhook **Test** payload — Sonarr (exact; these are literal constants in the source)

`verified: vendor/sonarr-webhook/WebhookBase.cs` (`BuildTestPayload`). Note it builds a
`WebhookGrabPayload`, so `release`, `downloadClient`, `downloadId` and `customFormatInfo` are **not set**
(they serialize as `null` or are omitted), and the series/episode objects are only partially populated.

```json
{
  "eventType": "Test",
  "instanceName": "Sonarr",
  "applicationUrl": "https://sonarr.example.com",
  "series": {
    "id": 1,
    "title": "Test Title",
    "titleSlug": null,
    "path": "C:\\testpath",
    "tvdbId": 1234,
    "tvMazeId": 0,
    "tmdbId": 0,
    "imdbId": null,
    "type": "standard",
    "year": 0,
    "genres": null,
    "images": null,
    "tags": [ "test-tag" ],
    "originalLanguage": null
  },
  "episodes": [
    {
      "id": 123,
      "episodeNumber": 1,
      "seasonNumber": 1,
      "title": "Test title",
      "overview": null,
      "airDate": null,
      "airDateUtc": null,
      "seriesId": 0,
      "tvdbId": 0
    }
  ],
  "release": null,
  "downloadClient": null,
  "downloadClientType": null,
  "downloadId": null,
  "customFormatInfo": null
}
```

Verified literals: `Id = 1`, `Title = "Test Title"`, `Path = "C:\\testpath"`, `TvdbId = 1234`,
`Tags = ["test-tag"]`; episode `Id = 123`, `EpisodeNumber = 1`, `SeasonNumber = 1`,
`Title = "Test title"` (lower-case "title" — deliberate in the source).

#### Webhook **Test** payload — Radarr (exact)

`verified: vendor/radarr-webhook/WebhookBase.cs` (`BuildTestPayload`). Radarr's test payload **does**
populate `release`.

```json
{
  "eventType": "Test",
  "instanceName": "Radarr",
  "applicationUrl": "https://radarr.example.com",
  "movie": {
    "id": 1,
    "title": "Test Title",
    "year": 1970,
    "filePath": null,
    "releaseDate": "1970-01-01",
    "folderPath": "C:\\testpath",
    "tmdbId": 0,
    "imdbId": null,
    "overview": null,
    "genres": null,
    "images": null,
    "tags": [ "test-tag" ],
    "originalLanguage": null
  },
  "remoteMovie": {
    "tmdbId": 1234,
    "imdbId": "5678",
    "title": "Test title",
    "year": 1970
  },
  "release": {
    "quality": "Test Quality",
    "qualityVersion": 1,
    "releaseGroup": "Test Group",
    "releaseTitle": "Test Title",
    "indexer": "Test Indexer",
    "size": 9999999,
    "customFormatScore": 0,
    "customFormats": null,
    "languages": null,
    "indexerFlags": null
  },
  "downloadClient": null,
  "downloadClientType": null,
  "downloadId": null,
  "customFormatInfo": null
}
```

Verified literals: movie `Id = 1`, `Title = "Test Title"`, `Year = 1970`, `FolderPath = "C:\\testpath"`,
`ReleaseDate = "1970-01-01"`, `Tags = ["test-tag"]`; remoteMovie `TmdbId = 1234`, `ImdbId = "5678"`,
`Title = "Test title"`, `Year = 1970`; release `Indexer = "Test Indexer"`, `Quality = "Test Quality"`,
`QualityVersion = 1`, `ReleaseGroup = "Test Group"`, `ReleaseTitle = "Test Title"`, `Size = 9999999`.

**Selectarr should use the Test payload to validate its webhook endpoint** — but note the payloads are
heavily null-populated, so the decoder must tolerate nulls everywhere.

### 6.3 Is there a pre-grab event, and can it veto? **No.** [VERIFIED]

This was the critical question and the answer is definitively negative.

`DownloadService.DownloadReport` performs the download **first** and publishes the grabbed event
**afterwards** (`verified: vendor/sonarr-DownloadService.cs`, abridged to the relevant ordering):

```csharp
string downloadClientId;
try
{
    downloadClientId = await downloadClient.Download(remoteEpisode, indexer);   // <-- release is SENT here
    _downloadClientStatusService.RecordSuccess(downloadClient.Definition.Id);
    _indexerStatusService.RecordSuccess(remoteEpisode.Release.IndexerId);
}
catch (…) { … throw; }

var episodeGrabbedEvent = new EpisodeGrabbedEvent(remoteEpisode);
episodeGrabbedEvent.DownloadClient = downloadClient.Name;
episodeGrabbedEvent.DownloadClientId = downloadClient.Definition.Id;
episodeGrabbedEvent.DownloadClientName = downloadClient.Definition.Name;
if (downloadClientId.IsNotNullOrWhiteSpace()) episodeGrabbedEvent.DownloadId = downloadClientId;

_logger.ProgressInfo("Report sent to {0}. Indexer {1}. {2}", …);
_eventAggregator.PublishEvent(episodeGrabbedEvent);     // <-- OnGrab notifications fire from here
```

Therefore:

- `OnGrab` / webhook `eventType: "Grab"` is a **post-facto notification**. The NZB/torrent has already
  been handed to the download client by the time your endpoint is called.
- The notification API cannot veto: `public override void OnGrab(GrabMessage message)` returns **`void`**
  and the webhook implementation simply does `_proxy.SendWebhook(BuildOnGrabPayload(message), Settings);`
  — the return value, HTTP status and body of your webhook are not consulted for any decision.
  `verified: vendor/sonarr-webhook/Webhook.cs`.
- There is **no** `OnBeforeGrab`, `OnReleaseDecision`, or any veto/approval hook anywhere in the vendored
  notification surface. The `WebhookEventType` enums in §6.1 are the complete event sets.

**Conclusion: you cannot implement "let Selectarr approve each grab" via webhooks.** The only way for
Selectarr to control *which* release is taken is to be the one that calls `POST /api/v3/release` — which
means Sonarr/Radarr's own automatic grabbing must be prevented from racing it (§6.4).

### 6.4 Can automatic search be disabled while keeping monitoring? Yes — via per-indexer flags

`IndexerResource` [VERIFIED, both specs]:

| field | type | nullable | notes |
| --- | --- | --- | --- |
| `id` | int32 | no | |
| `name` | string | yes | |
| `fields` | `Field[]` | yes | provider settings |
| `implementationName` | string | yes | |
| `implementation` | string | yes | e.g. `Newznab`, `Torznab` |
| `configContract` | string | yes | |
| `infoLink` | string | yes | |
| `message` | `ProviderMessage` | object | |
| `tags` | int32[] (`uniqueItems`) | yes | **filters which series/movies this indexer serves** |
| `presets` | `IndexerResource[]` | yes | |
| **`enableRss`** | bool | no | RSS sync participation |
| **`enableAutomaticSearch`** | bool | no | automatic (app-initiated) search participation |
| **`enableInteractiveSearch`** | bool | no | interactive search participation — **what `GET /release` uses** |
| `supportsRss` | bool | no | read-only capability |
| `supportsSearch` | bool | no | read-only capability |
| `protocol` | `DownloadProtocol` | no | |
| `priority` | int32 | no | Sonarr verified |
| `seasonSearchMaximumSingleEpisodeAge` | int32 | no | **Sonarr only** |
| `downloadClientId` | int32 | no | Sonarr verified |

Radarr's `IndexerResource` is verified identical through `protocol`; whether it also carries `priority` /
`downloadClientId` / other trailing fields is **[UNVERIFIED]** (outside my read window). Check
`components.schemas.IndexerResource` in the Radarr spec.

**Bulk update.** `IndexerBulkResource` exists in **both** specs [VERIFIED]:
`ids: int32[]?`, `tags: int32[]?`, `applyTags: ApplyTags`, `enableRss: bool?`,
`enableAutomaticSearch: bool?`, `enableInteractiveSearch: bool?`, `priority: int32?`.
`ApplyTags`: `"add" | "remove" | "replace"` [VERIFIED]. The corresponding route is presumably
`PUT /api/v3/indexer/bulk` — **[INFERRED]** from the schema's existence and the identical
`DownloadClientBulkResource` → `PUT /api/v3/downloadclient/bulk` pattern which I did verify. Verify the
path before relying on it.

**Global RSS interval.** `IndexerConfigResource` [VERIFIED]:
Sonarr `{ id, minimumAge, retention, maximumSize, rssSyncInterval }`;
Radarr `{ id, minimumAge, maximumSize, retention, rssSyncInterval, preferIndexerFlags, availabilityDelay, allowHardcodedSubs, whitelistedHardcodedSubs }`.
Endpoint `GET /api/v3/config/indexer`, `PUT /api/v3/config/indexer/{id}` (tag `IndexerConfig`)
[VERIFIED, Sonarr spec]. That `rssSyncInterval = 0` means "disabled" is **[UNVERIFIED]** — the field is
verified, the sentinel semantics are not in any vendored file. See
`https://wiki.servarr.com/sonarr/settings#options`.

#### Option-by-option assessment

| Option | Effect | Verified? | Verdict |
| --- | --- | --- | --- |
| **Per-indexer `enableAutomaticSearch = false` + `enableRss = false`, keep `enableInteractiveSearch = true`** | App's own automatic search and RSS never see the indexer; `GET /api/v3/release` still works fully | **[VERIFIED]** — §2.2 `Dispatch` + `IndexerResource` fields | **Recommended.** The only option that cleanly separates "app grabs" from "sidecar searches" |
| Global `rssSyncInterval = 0` | Stops RSS sync app-wide | field [VERIFIED], `0`-disables [UNVERIFIED] | Blunt; also kills RSS for anything you *do* want automatic. Use per-indexer `enableRss` instead |
| Unmonitor the series/movie | Stops all automatic activity | — | **Breaks the sidecar**: `wanted/missing` and `wanted/cutoff` default to `monitored=true`, so unmonitored items disappear from Selectarr's own work queue. Also disables `episodeRequested`/`movieRequested` semantics. **Do not use** |
| Quality profile with all qualities disallowed | Automatic grabs rejected | [INFERRED] | Poor: it also makes every release `rejected` in search output, destroying the `approved`/`rejections` signal Selectarr wants to read, and `cutoff` must reference an allowed quality. **Not recommended** |
| Very high `minFormatScore` | Automatic grabs rejected, manual grab still allowed | manual-grab-still-allowed is **[VERIFIED]** (§3.6) | Works as a *belt-and-braces* addition, see §6.5. Side effect: everything shows as `rejected` |

**Key insight, verified:** `enableAutomaticSearch` and `enableInteractiveSearch` are *independent*
booleans, and `GET /api/v3/release` is hard-coded to the **interactive** path. So the sidecar-driven
configuration is:

```
per indexer:  enableRss = false
              enableAutomaticSearch = false
              enableInteractiveSearch = true      <-- Selectarr still gets results
series/movie: monitored = true                    <-- so wanted/* still lists it
```

Applied with `PUT /api/v3/indexer/{id}` (body = the full `IndexerResource` you just GET'd, with the two
booleans flipped). `PUT /api/v3/indexer/{id}` takes `id` (int32) and an optional `forceSave: bool = false`
query parameter [the `forceSave` parameter is **[INFERRED]** by analogy with the verified
`POST/PUT /api/v3/downloadclient` operations which do declare it; I verified `forceSave` on
`downloadclient`, not on `indexer`].

#### Prowlarr interaction — **[UNVERIFIED]**

Prowlarr pushes indexer definitions into Sonarr/Radarr and, depending on its **Sync Level**, will
overwrite app-side indexer settings — which would silently undo `enableAutomaticSearch = false`. No
Prowlarr source or documentation was vendored for this run, so I cannot state:

- the exact `Sync Level` values (commonly described as "Add and Remove Only" vs "Full Sync"),
- whether "Full Sync" overwrites `enableRss` / `enableAutomaticSearch` / `enableInteractiveSearch`,
- whether Prowlarr's per-app "Sync Categories"/sync profile can preserve those flags.

**Verify before shipping** at:
- `https://wiki.servarr.com/prowlarr/settings#applications`
- `https://wiki.servarr.com/prowlarr/faq`
- `https://github.com/Prowlarr/Prowlarr/tree/develop/src/NzbDrone.Core/Applications` (the
  `SonarrV3`/`RadarrV3` application classes contain the field-mapping logic)

**Mitigation Selectarr should implement regardless [design recommendation]:** treat the indexer flags as
*desired state*. On every polling cycle, `GET /api/v3/indexer`, and if any indexer has
`enableAutomaticSearch == true` or `enableRss == true` while Selectarr is in sidecar-driven mode, either
(a) re-apply the desired state with `PUT`, or (b) raise a visible warning "Prowlarr has re-enabled
automatic search on indexer X; Selectarr and Sonarr may race". Option (a) is a reconciliation loop and is
the robust choice.

### 6.5 The `minFormatScore` / custom-format approach

**Verified mechanics:**

- `QualityProfileResource.minFormatScore : int32` exists and is settable via
  `PUT /api/v3/qualityprofile/{id}` (§5.2). [VERIFIED]
- Setting it above any achievable `customFormatScore` makes the **decision engine** reject every release,
  so automatic search/RSS grabs nothing. [INFERRED — `minFormatScore` is verified to exist on the
  profile, and rejections are verified to be produced by the decision engine on search; the specific
  specification class that compares them (`CustomFormatAllowedByProfileSpecification`) was not vendored.]
- **`POST /api/v3/release` does not consult `minFormatScore`, the cutoff, or `items[].allowed` at all** —
  this is fully **[VERIFIED]** in §3.6 from `ReleaseController.DownloadRelease` +
  `DownloadService.DownloadReport`. So manual/sidecar grabs still succeed.

**Assessment.** It works, but it is a *side-effecting* hack: every release in every search result becomes
`"rejected": true` with a `minFormatScore` rejection message, which destroys the `approved` /
`rejections` / `downloadAllowed` signal that Selectarr would otherwise want to use as input to its own
scoring. Prefer the indexer-flag approach (§6.4) and use `minFormatScore` only as an optional
"paranoid mode" for users whose Prowlarr keeps resetting indexer flags.

`shouldOverride` is **not** required to grab a rejected release — it is only needed when series/episode
(or movie) **mapping** fails, or when you want to force a different quality/language. [VERIFIED, §3.3]

### 6.6 Polling surfaces — avoiding double grabs

**Work queue.** `GET /api/v3/wanted/missing` + `GET /api/v3/wanted/cutoff` (§4.3 Sonarr, §4.5 Radarr).
Both default to `monitored=true`, `page=1`, `pageSize=10` — **raise `pageSize`** and paginate on
`totalRecords`.

**In-flight check — `GET /api/v3/queue`.** Sonarr parameters [VERIFIED]:
`page=1`, `pageSize=10`, `sortKey`, `sortDirection`, `includeUnknownSeriesItems=false`,
`includeSeries=false`, `includeEpisode=false`, `seriesIds: int32[]`, `protocol: DownloadProtocol`,
`languages: int32[]`, `quality: int32[]`, `status: QueueStatus[]`.
Radarr parameters [VERIFIED]: `page`, `pageSize`, `sortKey`, `sortDirection`,
`includeUnknownMovieItems=false`, `includeMovie=false`, `movieIds: int32[]`, `protocol`, `languages`,
`quality`, `status`. Returns `QueueResourcePagingResource`.

Cheaper targeted alternatives [VERIFIED]:
`GET /api/v3/queue/details?seriesId=&episodeIds=&includeSeries=&includeEpisode=` (Sonarr) and
`GET /api/v3/queue/details?movieId=&includeMovie=` (Radarr), both returning `QueueResource[]` unpaginated;
plus `GET /api/v3/queue/status` → `QueueStatusResource`
(`id, totalCount, count, unknownCount, errors, warnings, unknownErrors, unknownWarnings`).

**`QueueResource`** — Sonarr [VERIFIED]:

| field | type | nullable |
| --- | --- | --- |
| `id` | int32 | no |
| `seriesId` | int32 | yes |
| `episodeId` | int32 | yes |
| `seasonNumber` | int32 | yes |
| `series` | `SeriesResource` | object |
| `episode` | `EpisodeResource` | object |
| `languages` | `Language[]` | yes |
| `quality` | `QualityModel` | object |
| `customFormats` | `CustomFormatResource[]` | yes |
| `customFormatScore` | int32 | no |
| `size` | **double** | no |
| `title` | string | yes |
| `estimatedCompletionTime` | date-time | yes |
| `added` | date-time | yes |
| `status` | `QueueStatus` | no |
| `trackedDownloadStatus` | `TrackedDownloadStatus` | no |
| `trackedDownloadState` | `TrackedDownloadState` | no |
| `statusMessages` | `TrackedDownloadStatusMessage[]` | yes |
| `errorMessage` | string | yes |
| `downloadId` | string | yes |
| `protocol` | `DownloadProtocol` | no |
| `downloadClient` | string | yes |
| `downloadClientHasPostImportCategory` | bool | no |
| `indexer` | string | yes |
| `outputPath` | string | yes |
| `episodeHasFile` | bool | no |
| `sizeleft` | double | no, **`deprecated`** |
| `timeleft` | date-span | yes, **`deprecated`** |

Radarr `QueueResource` [VERIFIED] is the same minus `seriesId`/`episodeId`/`seasonNumber`/`series`/
`episode`/`episodeHasFile`, plus `movieId: int32?` and `movie: MovieResource`.

Note `size` is a **double** (not int64) on the queue, unlike `ReleaseResource.size`. `sizeleft` and
`timeleft` are explicitly `deprecated` in the spec — do not build on them.

Enums [VERIFIED, both apps, identical]:
- `QueueStatus`: `"unknown" | "queued" | "paused" | "downloading" | "completed" | "failed" | "warning" | "delay" | "downloadClientUnavailable" | "fallback"`
- `TrackedDownloadStatus`: `"ok" | "warning" | "error"`
- `TrackedDownloadState`: `"downloading" | "importBlocked" | "importPending" | "importing" | "imported" | "failedPending" | "failed" | "ignored"`
- `TrackedDownloadStatusMessage`: `{ title: string?, messages: string[]? }`

**Already-grabbed check — `GET /api/v3/history`.** Sonarr parameters [VERIFIED]:
`page=1`, `pageSize=10`, `sortKey`, `sortDirection`, `includeSeries: bool` (no default),
`includeEpisode: bool` (no default), **`eventType: int32[]`**, `episodeId: int32`, `downloadId: string`,
`seriesIds: int32[]`, `languages: int32[]`, `quality: int32[]`.
Radarr parameters [VERIFIED]: `page`, `pageSize`, `sortKey`, `sortDirection`, `includeMovie: bool`,
**`eventType: int32[]`**, `downloadId: string`, `movieIds: int32[]`, `languages: int32[]`,
`quality: int32[]`.

Two corrections to the brief: `eventType` is an **array of integers** (not a single value), and Radarr has
**`movieIds` (plural array)** with **no singular `movieId`** on `/api/v3/history`.

Also available [VERIFIED]:
`GET /api/v3/history/since?date=&eventType=&includeSeries=&includeEpisode=` → `HistoryResource[]`
(here `eventType` is a **single** `EpisodeHistoryEventType`, i.e. the string form);
`GET /api/v3/history/series?seriesId=&seasonNumber=&eventType=&includeSeries=&includeEpisode=` →
`HistoryResource[]`; `POST /api/v3/history/failed/{id}` → `200`.

**`HistoryResource`** — Sonarr [VERIFIED]:
`id: int32`, `episodeId: int32`, `seriesId: int32`, `sourceTitle: string?`, `languages: Language[]?`,
`quality: QualityModel`, `customFormats: CustomFormatResource[]?`, `customFormatScore: int32`,
`qualityCutoffNotMet: bool`, `date: date-time`, `downloadId: string?`,
`eventType: EpisodeHistoryEventType`, `data: map<string, string|null>?`, `episode: EpisodeResource`,
`series: SeriesResource`.

Radarr [VERIFIED]: `id`, `movieId: int32`, `sourceTitle`, `languages`, `quality`, `customFormats`,
`customFormatScore`, `qualityCutoffNotMet`, `date`, `downloadId`,
`eventType: MovieHistoryEventType`, `data`, `movie: MovieResource`.

`data` is a string→string dictionary. For a `grabbed` row it carries the release `guid`, `nzbInfoUrl`,
`protocol` etc. — this is exactly how Radarr's own `AddHistory` correlates history to releases
(`h.Data.TryGetValue("guid", out var guid)`, `h.Data.GetValueOrDefault("protocol")`);
`verified: vendor/radarr-ReleaseController.cs`. **Selectarr can use the same trick: read
`data["guid"]` from `grabbed` history rows to know whether a specific release guid was already taken.**
The full set of `data` keys is **[UNVERIFIED]** (`HistoryService`/`*History.cs` not vendored) — only
`guid`, `nzbInfoUrl` and `protocol` are verified to exist.

**Event type enums — names are verified, numbers are NOT.**

`EpisodeHistoryEventType` (Sonarr) — JSON **string** values, in spec declaration order [VERIFIED]:
`"unknown"`, `"grabbed"`, `"seriesFolderImported"`, `"downloadFolderImported"`, `"downloadFailed"`,
`"episodeFileDeleted"`, `"episodeFileRenamed"`, `"downloadIgnored"`.

`MovieHistoryEventType` (Radarr) — JSON **string** values, in spec declaration order [VERIFIED]:
`"unknown"`, `"grabbed"`, `"downloadFolderImported"`, `"downloadFailed"`, `"movieFileDeleted"`,
`"movieFolderImported"`, `"movieFileRenamed"`, `"downloadIgnored"`.

⚠️ **The numeric values used by the `eventType` query parameter are [UNVERIFIED].** The response field is
a *string*; the query filter is `int32[]`. The OpenAPI enum lists only names, and the underlying C# enums
were **not** vendored, so I cannot confirm the integers. For Sonarr, contiguous `0..7` assignment matches
the brief's claim (`grabbed=1`, `seriesFolderImported=2`, `downloadFolderImported=3`, `downloadFailed=4`,
`episodeFileDeleted=5`, `episodeFileRenamed=6`, `downloadIgnored=7`) — but that is an [INFERRED]
ordinal reading, not verified. For **Radarr the risk is higher**: Radarr's enum is known to have been
extended over time and may use non-contiguous explicit values, so ordinal position is an unsafe guide.

**Recommendation (design):** do **not** rely on numeric `eventType` filters. Either
(a) omit `eventType` and filter client-side on the **string** `eventType` in the response, or
(b) use `GET /api/v3/history/since?eventType=grabbed` where the parameter is the string enum
(`$ref: EpisodeHistoryEventType`) [VERIFIED that this parameter is the string enum type]. Option (b) plus
a `date` watermark is both cheaper and safer than paging `/api/v3/history`.
To confirm the integers, check
`https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/History/EpisodeHistory.cs` and
`https://github.com/Radarr/Radarr/blob/develop/src/NzbDrone.Core/History/MovieHistory.cs`.

### 6.7 Commands — and why a sidecar must not use the search ones

`POST /api/v3/command` body is `CommandResource`; `GET /api/v3/command/{id}` returns `CommandResource`
[the `CommandResource` schema is VERIFIED; the exact `/api/v3/command` path operations are **[INFERRED]**
from the `Command` tag being present in the Sonarr spec — I verified the schema, not each operation].

**`CommandResource`** [VERIFIED, `vendor/sonarr-openapi.json`]:
`id: int32`, `name: string?`, `commandName: string?`, `message: string?`, `body: Command`,
`priority: CommandPriority`, `status: CommandStatus`, `result: CommandResult`, `queued: date-time`,
`started: date-time?`, `ended: date-time?`, `duration: date-span?`, `exception: string?`,
`trigger: CommandTrigger`, `clientUserAgent: string?`, `stateChangeTime: date-time?`,
`sendUpdatesToClient: bool`, `updateScheduledTask: bool`, `lastExecutionTime: date-time?`.

Enums [VERIFIED]:
- `CommandStatus`: `"queued" | "started" | "completed" | "failed" | "aborted" | "cancelled" | "orphaned"`
- `CommandResult`: `"unknown" | "successful" | "unsuccessful"`
- `CommandTrigger`: `"unspecified" | "manual" | "scheduled"`
- `CommandPriority`: values **[UNVERIFIED]** (schema referenced but its body was not in my read window)

**Command-specific request properties are [UNVERIFIED].** `CommandResource` is
`"additionalProperties": false` in the spec and has no `episodeIds` / `seriesId` / `movieIds` fields —
the real endpoint uses a polymorphic body binder that the generated OpenAPI cannot express. Therefore the
following names come from **model knowledge, not the vendored sources**, and must be confirmed:

```json
{ "name": "EpisodeSearch",        "episodeIds": [123, 124] }
{ "name": "SeriesSearch",         "seriesId": 42 }
{ "name": "SeasonSearch",         "seriesId": 42, "seasonNumber": 2 }
{ "name": "MissingEpisodeSearch" }
{ "name": "RssSync" }
{ "name": "MoviesSearch",         "movieIds": [77] }
{ "name": "MissingMoviesSearch" }
```

Confirm at `https://wiki.servarr.com/sonarr/api` / `https://wiki.servarr.com/radarr/api` and in
`src/NzbDrone.Core/IndexerSearch/*Command.cs`
(e.g. `https://github.com/Sonarr/Sonarr/blob/develop/src/NzbDrone.Core/IndexerSearch/EpisodeSearchCommand.cs`).

**⚠️ Critical warning for Selectarr — do not use these commands in sidecar-driven mode.**

All of the `*Search` commands and `RssSync` run **Sonarr/Radarr's own decision engine and grab the
winner themselves**. Evidence: the non-interactive search path goes through
`_indexerFactory.AutomaticSearchEnabled()` and ends in `_makeDownloadDecision.GetSearchDecision(...)`
(`verified: vendor/sonarr-ReleaseSearchService.cs`, `vendor/radarr-ReleaseSearchService.cs`), and grabbing
is performed by the same `DownloadService.DownloadReport` that the manual endpoint uses
(`verified: vendor/sonarr-DownloadService.cs`). The command API gives you **no hook** to intercept the
choice (§6.3).

So:

- If Selectarr wants to pick the release itself → **never** issue `EpisodeSearch`, `SeriesSearch`,
  `SeasonSearch`, `MoviesSearch`, `MissingEpisodeSearch`, `MissingMoviesSearch`, `CutoffUnmetEpisodeSearch`
  or `RssSync`. Use `GET /api/v3/release` (which is interactive and does **not** grab) followed by
  `POST /api/v3/release`.
- The commands are still useful for *non-selection* work: `RefreshSeries`/`RefreshMovie`,
  `RescanSeries`, `RenameFiles`, etc. [command names here are [UNVERIFIED], same caveat as above].
- `GET /api/v3/command/{id}` + `status`/`result` is how you await completion if you do use one.

### 6.8 Recommended Selectarr design

Three modes. I state explicitly which parts are verified mechanics and which are my design proposal.

#### Mode 1 — "advisory" (safest, no configuration changes)

Sonarr/Radarr keep grabbing automatically exactly as today. Selectarr only acts when a human asks.

- Trigger: a user request in Selectarr's UI, or a webhook `eventType: "SeriesAdd"` / `"MovieAdded"` used
  purely as a *notification* to offer a suggestion.
- Flow: `GET /api/v3/release?episodeId=…` (or `?movieId=…`) → hard rules + scoring → optional LLM →
  present ranked list → on user confirm, `POST /api/v3/release {guid, indexerId}`.
- Risk: Sonarr/Radarr may grab something first, or grab an upgrade later that overrides Selectarr's pick.
  Accept this; it is inherent to leaving automation on.
- **Verified enablers:** `GET`/`POST /api/v3/release` semantics (§2, §3); 30-minute cache (§3.4);
  rejections are non-binding on grab (§3.6).

#### Mode 2 — "sidecar-driven" (Selectarr owns selection) — **recommended default for the product's purpose**

**Setup (one-time, ideally automated by Selectarr with explicit user consent):** for each indexer that
Selectarr should own, `PUT /api/v3/indexer/{id}` with

```
enableRss              = false
enableAutomaticSearch  = false
enableInteractiveSearch = true
```

Keep all series/movies **monitored**. Optionally also set a high `minFormatScore` on the quality profile
as a second line of defence (§6.5), accepting the loss of the `approved` signal.

**Verified basis:** `Dispatch` selects indexers by `InteractiveSearchEnabled()` for interactive searches
and `AutomaticSearchEnabled()` otherwise; `GET /api/v3/release` is always interactive (§2.2). This is the
load-bearing fact and it is directly verified in both apps' `ReleaseSearchService.Dispatch`.

**Loop (design recommendation):**

1. **Discover work.** Page `GET /api/v3/wanted/missing?pageSize=200&monitored=true` and
   `GET /api/v3/wanted/cutoff?pageSize=200&monitored=true` (Sonarr also `includeSeries=true` to avoid
   N+1 series fetches; Radarr's records are already full movies).
2. **De-duplicate against in-flight work.** `GET /api/v3/queue?pageSize=…&includeUnknownSeriesItems=true`
   (Radarr: `includeUnknownMovieItems=true`). Skip any item whose `episodeId`/`movieId` appears with
   `status` in `queued|paused|downloading|completed|delay` or whose `trackedDownloadState` is
   `importPending|importing|imported`. Treat `failed`/`failedPending`/`importBlocked` as "eligible again".
3. **De-duplicate against history.** `GET /api/v3/history/since?date=<watermark>&eventType=grabbed`
   (string enum — verified) and index `data["guid"]` per `episodeId`/`movieId`. Never re-grab a guid you
   already grabbed unless a later `downloadFailed` row exists for the same `downloadId`. Radarr users get
   this for free per-release via `ReleaseResource.history` (§2.4).
4. **Rate-limit.** Respect `episode.lastSearchTime` / `movie.lastSearchTime` (verified to be updated by
   every search, §2.2) and keep a Selectarr-side cooldown per item. Note `DownloadService` itself
   rate-limits grabs to one per 2 seconds per download host (verified) — do not fight it.
5. **Search.** `GET /api/v3/release?episodeId=N` (single), `?seriesId=N&seasonNumber=M` (season pack), or
   `?movieId=N`. **Never** `?seriesId=` alone (§2.1).
6. **Select.** Deterministic hard rules first (protocol, size band from `size`+`runtime`, `seeders`,
   `languages`, `indexerFlags`, blocked release groups, codec/audio parsed from `title` per §2.7), then
   scoring (`customFormatScore`, `qualityWeight`, `age`, `releaseWeight`), then optionally the LLM for the
   final tie-break among the top N.
7. **Grab immediately.** `POST /api/v3/release` with `{guid, indexerId}` (+ `episodeId`/`movieId` as a
   mapping safety net). **Must happen within 30 minutes of step 5** (§3.4). If the LLM round trip is slow,
   re-run step 5 and re-match by `guid` before posting.
8. **Confirm.** Optionally poll `GET /api/v3/queue/details?episodeIds=…` / `?movieId=…` to confirm the
   item appeared, and record your own audit row.

**Reconciliation guard (design):** every cycle, `GET /api/v3/indexer` and re-assert the desired
`enableRss`/`enableAutomaticSearch` flags, or warn loudly — because Prowlarr sync may reset them
(§6.4, [UNVERIFIED] behaviour).

#### Mode 3 — webhook-assisted triggers (an optimisation layered on Mode 1 or 2)

Register a Webhook notification pointing at Selectarr with `onSeriesAdd`/`onMovieAdded`,
`onGrab`, `onDownload`, `onHealthIssue`, and `onManualInteractionRequired` enabled, so Selectarr reacts
in seconds instead of waiting for its poll interval.

- `"SeriesAdd"` / `"MovieAdded"` → enqueue an immediate selection pass for the new item.
- `"Download"` → mark the item satisfied; cancel any pending selection. Remember to disambiguate
  per-file import vs import-complete by payload shape, and to read `isUpgrade` (§6.1).
- `"Grab"` → **audit only.** If Selectarr did not initiate it, this proves something else grabbed
  (mis-configured indexer flags, or Prowlarr reset them) → raise the reconciliation warning.
- `"ManualInteractionRequired"` → surface to the user.
- `"Test"` → validate the endpoint; expect the heavily-null payload of §6.2.

**Verified constraint:** webhooks are strictly *reactive*. They cannot delay, approve or veto a grab
(§6.3). Mode 3 is therefore only a latency optimisation, never a control mechanism. Webhook delivery is
also not guaranteed/retried as far as the vendored source shows, so **polling (Mode 2) must remain the
source of truth** and webhooks only shortcut it. [The absence of retry logic is [INFERRED] — `WebhookProxy`
was not vendored; `Webhook.OnGrab` simply calls `_proxy.SendWebhook(...)` with no visible retry.]

---

## 7. OpenAI-compatible chat completions

> **Scope warning.** Nothing in this section was verified against a primary source during this run — no
> OpenAI, llama.cpp, Ollama, vLLM or LM Studio documentation was available to the tools I had. Everything
> below is **[UNVERIFIED — model knowledge]** and each claim carries a URL to check. Treat §7 as a
> starting shape for the OCaml types, and validate against your target server before release.

### 7.1 Request

`POST {base_url}/chat/completions` where `base_url` typically ends in `/v1`
(e.g. `https://api.openai.com/v1`, `http://localhost:11434/v1`, `http://localhost:8080/v1`).

Headers: `Authorization: Bearer <api_key>`, `Content-Type: application/json`.

```json
{
  "model": "gpt-4o-mini",
  "messages": [
    { "role": "system", "content": "You pick the best release. Reply with JSON only." },
    { "role": "user",   "content": "{\"candidates\":[…]}" }
  ],
  "temperature": 0,
  "max_tokens": 512,
  "response_format": { "type": "json_object" },
  "stream": false
}
```

Field notes (all [UNVERIFIED]):

- `model` — string, required.
- `messages` — array of `{ role, content }`. `role` ∈ `"system" | "user" | "assistant" | "tool"`.
  `content` is a string in the simple case (it can also be a content-part array on OpenAI proper, which
  many local servers do not support — send a plain string).
- `temperature` — number, `0`–`2` on OpenAI; use `0` for determinism.
- `max_tokens` — integer. Deprecated on OpenAI in favour of `max_completion_tokens`, but
  `max_tokens` remains the portable choice for local servers.
- `response_format: { "type": "json_object" }` — JSON mode. See §7.3 for support caveats.
  (`{"type": "json_schema", "json_schema": {...}}` = Structured Outputs, much less portable.)
- `stream` — bool. Selectarr should send `false` (or omit) and use non-streaming parsing.
- `seed`, `top_p`, `stop`, `n`, `presence_penalty`, `frequency_penalty` — optional, variable support.

Check: `https://platform.openai.com/docs/api-reference/chat/create`

### 7.2 Response

```json
{
  "id": "chatcmpl-ABC123",
  "object": "chat.completion",
  "created": 1715200000,
  "model": "gpt-4o-mini-2024-07-18",
  "choices": [
    {
      "index": 0,
      "message": { "role": "assistant", "content": "{\"pick\":\"<guid>\",\"reason\":\"best CF score\"}", "refusal": null },
      "logprobs": null,
      "finish_reason": "stop"
    }
  ],
  "usage": { "prompt_tokens": 812, "completion_tokens": 41, "total_tokens": 853 },
  "system_fingerprint": "fp_abc123"
}
```

- Text is at `choices[0].message.content` (a **string**).
- `finish_reason` ∈ `"stop" | "length" | "content_filter" | "tool_calls" | "function_call"`.
  **Selectarr must treat `"length"` as a failure** — a truncated JSON object will not parse.
- `usage` ∈ `{ prompt_tokens, completion_tokens, total_tokens }` (OpenAI adds
  `prompt_tokens_details` / `completion_tokens_details`; local servers often omit `usage` entirely, so
  make it optional).
- `object`, `created`, `system_fingerprint`, `logprobs`, `refusal` are frequently **absent** on local
  servers → all optional in the OCaml record.

### 7.3 `response_format` support across servers — [UNVERIFIED], verify per-deployment

| server | `{"type":"json_object"}` | notes | check |
| --- | --- | --- | --- |
| OpenAI | yes | also supports `json_schema` Structured Outputs | `https://platform.openai.com/docs/guides/structured-outputs` |
| llama.cpp (`llama-server`) | generally yes | also accepts a non-standard `json_schema` / `grammar` (GBNF) field | `https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md` |
| Ollama (`/v1/chat/completions`) | generally yes | native API uses `format: "json"` / a JSON schema instead; OpenAI-compat layer maps it | `https://github.com/ollama/ollama/blob/main/docs/openai.md` |
| vLLM | generally yes | plus `guided_json` / `guided_choice` extras | `https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html` |
| LM Studio | generally yes | schema support varies by version | `https://lmstudio.ai/docs/app/api/endpoints/openai` |

**Design recommendation:** make JSON mode a *per-provider config flag*, default **off**, and never depend
on it. Always (a) instruct JSON-only in the system prompt, (b) strip code fences, (c) parse leniently, and
(d) fall back to the deterministic scorer if parsing fails. A server that rejects an unknown
`response_format` typically returns HTTP 400 — so sending it unconditionally can break otherwise-working
backends.

### 7.4 Fence stripping — required

Many servers (and many models regardless of server) wrap JSON in Markdown fences:

````
```json
{"pick": "…"}
```
````

The OCaml client should, before `Yojson` parsing: trim whitespace; if the text starts with ` ``` `, drop
the first line (which may be ` ```json `, ` ```JSON `, or bare ` ``` `) and drop a trailing ` ``` ` line;
then, as a last resort, extract the substring from the first `{` to the last `}`. [UNVERIFIED as a
documented behaviour — this is a well-known practical necessity, not a spec'd one.]

### 7.5 Error shape

```json
{ "error": { "message": "Invalid value for 'temperature'…", "type": "invalid_request_error", "param": "temperature", "code": null } }
```

`error.message` is reliably present; `type`, `param`, `code` are all optional and often `null` or missing
on local servers (some return a bare `{"error": "string"}`). Decode as
`{ message : string; type_ : string option; param : string option; code : Yojson.Safe.t option }` with a
fallback for the string form.

Statuses worth special handling: `401` (bad key), `404` (wrong `base_url` — e.g. `/v1` missing or doubled),
`400` (unsupported parameter, commonly `response_format`), `429` (rate limit — honour `Retry-After`),
`500`/`503` (retry with backoff), and `context_length_exceeded` (reduce candidate count).
Check `https://platform.openai.com/docs/guides/error-codes`.

### 7.6 Ollama specifics — [UNVERIFIED]

Ollama exposes an OpenAI-compatible surface at `http://localhost:11434/v1` (so
`POST http://localhost:11434/v1/chat/completions`) alongside its native `/api/chat`. The API key is
ignored but many clients must send a non-empty `Authorization` header, so send `Bearer ollama`. `usage`
and several optional response fields may be absent or zeroed. Check
`https://github.com/ollama/ollama/blob/main/docs/openai.md`.

**Selectarr guidance:** normalise the configured base URL (strip a trailing `/`, append `/v1` only if the
user did not already provide a path), and log the full request URL once at startup — misconfigured
`base_url` is by far the most common failure mode.

---

## Verification sources

**Primary sources actually read (vendored from upstream `develop`):**

- `vendor/sonarr-openapi.json` — paths and every schema cited: `SystemResource`, `ReleaseResource`,
  `ReleaseEpisodeResource`, `AlternateTitleResource`, `EpisodeResource`, `EpisodeFileResource`,
  `EpisodeResourcePagingResource`, `EpisodesMonitoredResource`, `SeriesResource`, `SeasonResource`,
  `SeasonStatisticsResource`, `SeriesStatisticsResource`, `SeriesStatusType`, `SeriesTypes`,
  `NewItemMonitorTypes`, `AddSeriesOptions`, `Ratings`, `QualityProfileResource`,
  `QualityProfileQualityItemResource`, `ProfileFormatItemResource`, `Quality`, `QualityModel`, `Revision`,
  `QualitySource`, `QualityDefinitionResource`, `QualityDefinitionLimitsResource`, `CustomFormatResource`,
  `CustomFormatSpecificationSchema`, `CustomFormatBulkResource`, `Field`, `SelectOption`, `PrivacyLevel`,
  `QueueResource`, `QueueResourcePagingResource`, `QueueStatus`, `QueueStatusResource`,
  `TrackedDownloadStatus`, `TrackedDownloadState`, `TrackedDownloadStatusMessage`, `HistoryResource`,
  `HistoryResourcePagingResource`, `EpisodeHistoryEventType`, `IndexerResource`, `IndexerBulkResource`,
  `IndexerConfigResource`, `IndexerFlagResource`, `NotificationResource`, `CommandResource`,
  `CommandStatus`, `CommandResult`, `CommandTrigger`, `DownloadProtocol`, `SortDirection`, `Language`,
  `ReleaseType`, `RejectionType`, `HealthCheckResult`, `ApplyTags`, `securitySchemes`
- `vendor/radarr-openapi.json` — `SystemResource`, `ReleaseResource`, `MovieResource`,
  `MovieResourcePagingResource`, `MovieFileResource`, `MovieCollectionResource`,
  `MovieStatisticsResource`, `MovieStatusType`, `MovieHistoryEventType`, `MovieRuntimeFormatType`,
  `MonitorTypes`, `Ratings`, `RatingChild`, `RatingType`, `Quality`, `QualitySource`, `Modifier`,
  `QualityProfileResource`, `QueueResource`, `HistoryResource`, `IndexerResource`,
  `IndexerBulkResource`, `IndexerConfigResource`, `NotificationResource`, paths for
  `/api/v3/release`, `/api/v3/movie`, `/api/v3/wanted/missing`, `/api/v3/wanted/cutoff`,
  `/api/v3/queue`, `/api/v3/queue/details`, `/api/v3/history`, `/api/v3/customformat*`,
  `/api/v3/system/status`, `securitySchemes`
- `vendor/sonarr-ReleaseController.cs` — GET dispatch, POST validation, `shouldOverride`, cache key,
  30-minute TTL, error messages
- `vendor/radarr-ReleaseController.cs` — same, plus `AddHistory`/`ReleaseHistoryResource` population
- `vendor/sonarr-ReleaseResource.cs`, `vendor/radarr-ReleaseResource.cs` — field-by-field C# truth,
  `JsonIgnore` behaviour, `rejections` mapping, `indexerFlags` asymmetry
- `vendor/sonarr-DownloadService.cs` — grab ordering (download before event), no profile checks,
  2 s/host rate limit, exception set
- `vendor/sonarr-ReleaseSearchService.cs`, `vendor/radarr-ReleaseSearchService.cs` —
  `interactiveSearch` → `InteractiveSearchEnabled()` vs `AutomaticSearchEnabled()`, tag filtering,
  `LastSearchTime` update, `DeDupeDecisions`
- `vendor/sonarr-Quality.cs`, `vendor/radarr-Quality.cs` — complete id/name/source/resolution(/modifier)
  tables
- `vendor/sonarr-QualitySource.cs`, `vendor/radarr-QualitySource.cs`, `vendor/radarr-Modifier.cs` — enums
- `vendor/sonarr-WebhookEventType.cs`, `vendor/radarr-WebhookEventType.cs` — event sets + PascalCase
  serialization
- `vendor/sonarr-webhook/WebhookBase.cs`, `vendor/radarr-webhook/WebhookBase.cs` — every payload builder
  and both literal Test payloads
- `vendor/sonarr-webhook/Webhook.cs` — `void` notification methods (no veto), settings link
- `vendor/sonarr-webhook/WebhookPayload.cs`, `WebhookGrabPayload.cs`, `WebhookSeries.cs`,
  `WebhookEpisode.cs`, `WebhookRelease.cs`, `WebhookCustomFormatInfo.cs`
- `vendor/radarr-webhook/WebhookGrabPayload.cs`, `WebhookMovie.cs`, `WebhookRelease.cs`,
  `WebhookRemoteMovie.cs`

**Upstream URLs for re-verification:**

- `https://raw.githubusercontent.com/Sonarr/Sonarr/develop/src/Sonarr.Api.V3/openapi.json`
- `https://raw.githubusercontent.com/Radarr/Radarr/develop/src/Radarr.Api.V3/openapi.json`
- `https://github.com/Sonarr/Sonarr/tree/develop/src/NzbDrone.Core/Notifications/Webhook`
- `https://github.com/Radarr/Radarr/tree/develop/src/NzbDrone.Core/Notifications/Webhook`
- `https://github.com/Sonarr/Sonarr/tree/develop/src/Sonarr.Api.V3/Indexers`
- `https://github.com/Radarr/Radarr/tree/develop/src/Radarr.Api.V3/Indexers`
- `https://sonarr.tv/docs/api/`, `https://radarr.video/docs/api/`
- `https://wiki.servarr.com/sonarr`, `https://wiki.servarr.com/radarr`, `https://wiki.servarr.com/prowlarr`

## Explicitly NOT verified — open items before coding

1. **Numeric values of `EpisodeHistoryEventType` / `MovieHistoryEventType`** — only the string names are
   verified. Do not use integer `eventType` filters without checking
   `src/NzbDrone.Core/History/EpisodeHistory.cs` / `MovieHistory.cs`. Workaround in §6.6.
2. **Command request payloads** (`EpisodeSearch`, `MoviesSearch`, `RssSync`, …) — names are model
   knowledge; the OpenAPI `CommandResource` cannot express them. Check
   `src/NzbDrone.Core/IndexerSearch/*Command.cs` and the wiki. (Selectarr should not use the search ones
   anyway — §6.7.)
3. **Prowlarr sync behaviour** — whether Full Sync overwrites `enableRss` /
   `enableAutomaticSearch` / `enableInteractiveSearch`, and whether a sync profile can preserve them.
   Load-bearing for Mode 2 robustness. §6.4.
4. **`MediaCover`, `WebhookImage`, `WebhookCustomFormat`, `AddMovieOptions`, `CommandPriority`** field
   names — schemas/files not in my read windows.
5. **Leading fields of Radarr `AlternativeTitleResource`**, and Radarr `IndexerResource` fields after
   `protocol`.
6. **`rssSyncInterval = 0` meaning "disabled"** — field verified, sentinel semantics not.
7. **`QualityDefinition` size units** (MB vs MB/hour).
8. **`forceSave` query parameter on `PUT /api/v3/indexer/{id}`**, and the existence of
   `PUT /api/v3/indexer/bulk` — inferred by analogy with verified `downloadclient` operations.
9. **Notification endpoint path list** (`/api/v3/notification*`) — the resource schema is verified, the
   individual operations are not.
10. **All of §7 (OpenAI / llama.cpp / Ollama / vLLM / LM Studio)** — no source was available to this run.
11. **Radarr `ReleaseResource.history`** — present in C# source, absent from the vendored spec
    (§2.4). Confirm against a live Radarr 5.x instance.
12. **HTTP status mapping for non-`ReleaseDownloadException` grab failures** (`DownloadClientUnavailableException`,
    `ReleaseBlockedException`, …) — the global exception handler was not vendored.
13. **Valid `sortKey` values** for the paged endpoints — free-form string in the spec.
