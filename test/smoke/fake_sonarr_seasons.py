#!/usr/bin/env python3
"""Fake Sonarr for the Pickarr "seasons" smoke test.

Serves: /api/v3/system/status, /api/v3/series/{id}, /api/v3/episode?seriesId=,
/api/v3/episode/{id}, /api/v3/release?seriesId=&seasonNumber=,
/api/v3/release?episodeId=, /api/v3/tag, /api/v3/qualityprofile/{id} and
POST /api/v3/release (records the grab bodies).

Season 2 is entirely missing (2/2) -> a pack is expected.
Season 1 misses 1 of 4 -> per-episode is expected.
"""
import json
import os
import re
import sys
import http.server
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19200
# Fixtures directory: argv[2], or the repository's own, resolved from this
# file so the script can be run from anywhere.
FIXTURES = (
    sys.argv[2]
    if len(sys.argv) > 2
    else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "arr", "fixtures")
)

BASE = json.load(open(os.path.join(FIXTURES, "sonarr_releases.json")))
SERIES = json.load(open(os.path.join(FIXTURES, "sonarr_episode.json")))["series"]

GRABS = []


def episode(eid, season, number, has_file, monitored=True):
    ep = {
        "id": eid,
        "seriesId": SERIES["id"],
        "seasonNumber": season,
        "episodeNumber": number,
        "title": f"S{season:02d}E{number:02d}",
        "airDateUtc": "2021-02-02T01:00:00Z",
        "runtime": 45,
        "hasFile": has_file,
        "monitored": monitored,
        "series": SERIES,
    }
    if has_file:
        ep["episodeFile"] = {
            "id": 900 + eid,
            "quality": {
                "quality": {"id": 4, "name": "HDTV-720p", "source": "television", "resolution": 720},
                "revision": {"version": 1, "real": 0, "isRepack": False},
            },
        }
    return ep


EPISODES = [
    # season 1: 4 episodes, 1 missing -> 0.25 missing fraction
    episode(101, 1, 1, True),
    episode(102, 1, 2, True),
    episode(103, 1, 3, True),
    episode(104, 1, 4, False),
    # season 2: 2 episodes, both missing -> 1.0 missing fraction
    episode(201, 2, 1, False),
    episode(202, 2, 2, False),
]


def release(guid, title, *, full_season, season, size, seeders, indexer_id, rejected=False):
    r = dict(BASE[0])
    r.update(
        {
            "guid": guid,
            "title": title,
            "fullSeason": full_season,
            # Pickarr reads mappedSeasonNumber first (Sonarr's resolution
            # against the library), so both must agree in the fake.
            "seasonNumber": season,
            "mappedSeasonNumber": season,
            "size": size,
            "seeders": seeders,
            "indexerId": indexer_id,
            "rejected": rejected,
            "temporarilyRejected": False,
            "approved": not rejected,
            "rejections": ["Not wanted in profile"] if rejected else [],
        }
    )
    return r


def season_releases(season):
    """A season search returns packs and the single episodes of the season."""
    return [
        release(
            f"pack-s{season}-flux",
            f"Some.Show.S{season:02d}.1080p.WEB-DL.DDP5.1.H.264-NTb",
            full_season=True, season=season, size=12_000_000_000, seeders=30, indexer_id=4,
        ),
        release(
            f"pack-s{season}-small",
            f"Some.Show.S{season:02d}.1080p.WEBRip.x265-GRP",
            full_season=True, season=season, size=6_000_000_000, seeders=4, indexer_id=4,
        ),
        release(
            f"single-s{season}e01",
            f"Some.Show.S{season:02d}E01.1080p.WEB-DL.DDP5.1.H.264-NTb",
            full_season=False, season=season, size=2_952_790_016, seeders=44, indexer_id=4,
        ),
        release(
            f"pack-s{season+1}-wrong",
            f"Some.Show.S{season+1:02d}.1080p.WEB-DL.H.264-NTb",
            full_season=True, season=season + 1, size=9_000_000_000, seeders=10, indexer_id=4,
        ),
    ]


def episode_releases(episode_id):
    return [
        release(
            f"ep-{episode_id}-webdl",
            f"Some.Show.Episode.{episode_id}.1080p.WEB-DL.DDP5.1.H.264-NTb",
            full_season=False, season=1, size=2_952_790_016, seeders=44, indexer_id=4,
        )
    ]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        print("GET", self.path, flush=True)
        if path == "/api/v3/system/status":
            return self._send({"appName": "Sonarr", "version": "4.0.14.2939", "instanceName": "FakeSonarr"})
        if path == "/api/v3/tag":
            return self._send([])
        if re.fullmatch(r"/api/v3/qualityprofile/\d+", path):
            return self._send({"id": 6, "name": "HD-1080p"})
        if path == "/api/v3/series":
            # Lookup by TheTVDB id, as the Seerr fulfilment path does.
            if "tvdbId" in query:
                wanted = int(query["tvdbId"][0])
                return self._send([SERIES] if wanted == SERIES["tvdbId"] else [])
            return self._send([SERIES])
        if re.fullmatch(r"/api/v3/series/\d+", path):
            return self._send(SERIES)
        if path == "/api/v3/episode":
            eps = EPISODES
            if "seasonNumber" in query:
                n = int(query["seasonNumber"][0])
                eps = [e for e in eps if e["seasonNumber"] == n]
            return self._send(eps)
        if re.fullmatch(r"/api/v3/episode/\d+", path):
            eid = int(path.rsplit("/", 1)[1])
            for e in EPISODES:
                if e["id"] == eid:
                    return self._send(e)
            return self._send({"message": "NotFound"}, 404)
        if path in ("/api/v3/wanted/missing", "/api/v3/wanted/cutoff"):
            missing = [e for e in EPISODES if e["monitored"] and not e["hasFile"]]
            records = missing if path.endswith("missing") else []
            return self._send({"page": 1, "pageSize": len(records), "totalRecords": len(records), "records": records})
        if path == "/api/v3/queue":
            return self._send({"page": 1, "pageSize": 0, "totalRecords": 0, "records": []})
        if path.startswith("/api/v3/history"):
            return self._send([])
        if path == "/api/v3/release":
            if "seriesId" in query and "seasonNumber" in query:
                return self._send(season_releases(int(query["seasonNumber"][0])))
            if "episodeId" in query:
                return self._send(episode_releases(int(query["episodeId"][0])))
            return self._send([])
        if path == "/__grabs":
            return self._send(GRABS)
        return self._send({"message": "NotFound"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if urlparse(self.path).path == "/api/v3/release":
            GRABS.append(body)
            print("GRAB", json.dumps(body), flush=True)
            return self._send(body)
        return self._send({"message": "NotFound"}, 404)


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
