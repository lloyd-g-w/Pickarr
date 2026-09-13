#!/usr/bin/env python3
"""Fake Sonarr/Radarr with a browsable library, for library_e2e.sh.

Usage: fake_library_arr.py <sonarr|radarr> <port>

Serves the whole-library endpoints the Search page browses
(GET /api/v3/series, GET /api/v3/movie) from the test fixtures, plus the
detail and release endpoints a selection needs. Every request is appended to
/tmp/pickarr-library-<port>.requests.log and every grab body to
/tmp/pickarr-library-<port>.grabs.jsonl so the test can assert on them.
"""
import json
import os
import sys
import http.server
from urllib.parse import urlparse, parse_qs

APP = sys.argv[1]
PORT = int(sys.argv[2])
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
FIX = os.path.join(ROOT, "test", "arr", "fixtures")

REQUESTS = "/tmp/pickarr-library-%d.requests.log" % PORT
GRABS = "/tmp/pickarr-library-%d.grabs.jsonl" % PORT


def fixture(name):
    with open(os.path.join(FIX, name)) as fh:
        return json.load(fh)


SERIES_LIST = fixture("sonarr_series_list.json")
MOVIE_LIST = fixture("radarr_movie_list.json")
SEASON_EPISODES = fixture("sonarr_season_episodes.json")
EPISODE = fixture("sonarr_episode.json")
SONARR_RELEASES = fixture("sonarr_releases.json")
RADARR_RELEASES = fixture("radarr_releases.json")
MOVIE = fixture("radarr_movie.json")

# The movie the library lists must be the one a selection can load, so the
# detail fixture is merged onto the listed row (keeping its id and slug).
MOVIE_BY_ID = {}
for row in MOVIE_LIST:
    merged = dict(MOVIE)
    merged.update(row)
    MOVIE_BY_ID[row["id"]] = merged

SERIES_BY_ID = {row["id"]: row for row in SERIES_LIST}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _record(self, line):
        with open(REQUESTS, "a") as fh:
            fh.write(line + "\n")

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
        self._record("GET " + self.path)

        if path == "/api/v3/system/status":
            return self._send(
                {
                    "appName": "Sonarr" if APP == "sonarr" else "Radarr",
                    "version": "4.0.0.1",
                    "instanceName": "Fake" + APP.capitalize(),
                }
            )
        if path == "/api/v3/tag":
            return self._send([])
        if path.startswith("/api/v3/qualityprofile/"):
            return self._send({"id": 1, "name": "HD-1080p"})

        if APP == "sonarr":
            if path == "/api/v3/series":
                tvdb = query.get("tvdbId")
                if tvdb:
                    return self._send(
                        [s for s in SERIES_LIST if str(s.get("tvdbId")) == tvdb[0]]
                    )
                return self._send(SERIES_LIST)
            if path.startswith("/api/v3/series/"):
                sid = int(path.rsplit("/", 1)[1])
                if sid not in SERIES_BY_ID:
                    return self._send({"message": "series not found"}, 404)
                return self._send(SERIES_BY_ID[sid])
            if path == "/api/v3/episode":
                season = query.get("seasonNumber")
                episodes = SEASON_EPISODES
                if season:
                    episodes = [
                        e for e in episodes if str(e.get("seasonNumber")) == season[0]
                    ]
                return self._send(episodes)
            if path.startswith("/api/v3/episode/"):
                eid = int(path.rsplit("/", 1)[1])
                for e in SEASON_EPISODES:
                    if e.get("id") == eid:
                        merged = dict(EPISODE)
                        merged.update(e)
                        merged["series"] = SERIES_BY_ID.get(
                            e.get("seriesId", 12), SERIES_LIST[0]
                        )
                        return self._send(merged)
                return self._send({"message": "episode not found"}, 404)
            if path == "/api/v3/release":
                return self._send(SONARR_RELEASES)
        else:
            if path == "/api/v3/movie":
                tmdb = query.get("tmdbId")
                if tmdb:
                    return self._send(
                        [m for m in MOVIE_LIST if str(m.get("tmdbId")) == tmdb[0]]
                    )
                return self._send(MOVIE_LIST)
            if path.startswith("/api/v3/movie/"):
                mid = int(path.rsplit("/", 1)[1])
                if mid not in MOVIE_BY_ID:
                    return self._send({"message": "movie not found"}, 404)
                return self._send(MOVIE_BY_ID[mid])
            if path == "/api/v3/release":
                return self._send(RADARR_RELEASES)

        if path.startswith("/api/v3/queue"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        if path.startswith("/api/v3/history"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        if path.startswith("/api/v3/wanted/"):
            records = [EPISODE] if APP == "sonarr" else [MOVIE_BY_ID[77]]
            return self._send(
                {"page": 1, "pageSize": 10, "totalRecords": 1, "records": records}
            )
        return self._send({"message": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else ""
        self._record("POST " + self.path + " " + raw)
        if self.path.startswith("/api/v3/release"):
            with open(GRABS, "a") as fh:
                fh.write(raw + "\n")
            try:
                return self._send(json.loads(raw), 201)
            except Exception:
                return self._send({}, 201)
        return self._send({"message": "not found"}, 404)


if __name__ == "__main__":
    open(REQUESTS, "w").close()
    open(GRABS, "w").close()
    http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
