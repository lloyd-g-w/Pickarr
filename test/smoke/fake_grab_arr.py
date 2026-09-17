#!/usr/bin/env python3
"""Scriptable fake Sonarr/Radarr for the grab-path smoke test.

Usage:
  fake_grab_arr.py <sonarr|radarr> <port> [--scenario S] [--queue Q] [--indexer-zero]

--scenario decides how POST /api/v3/release behaves, reproducing the verified
Sonarr/Radarr answers (docs/API_RESEARCH.md "3.5"):

  ok                    201, echoing the posted body
  cachemiss_then_ok     the first POST is 404 "Couldn't find requested release
                        in cache, try searching again"; later POSTs succeed
                        (the release is still offered by a new search)
  cachemiss_drop        every POST is that same 404, and the *second* and later
                        searches no longer offer the release at all
  mapping_override      the first POST is 404 "...will need to be manually
                        provided"; a POST with shouldOverride succeeds, but
                        only when it carries every field the real app asserts
                        on (Sonarr: seriesId + non-empty episodeIds + quality
                        + languages; Radarr: movieId + quality + languages)
  search_drops          POST always succeeds, but the *second* and later
                        searches no longer offer the release: the flaky-indexer
                        case that used to break the per-candidate Grab button
  permanent             409 "Unable to add release" every time

--queue decides what GET /api/v3/queue/details answers:
  none (default) | downloading | warning

--indexer-zero serves the releases with "indexerId": 0, which no grab can use.

Recorded for assertions:
  /tmp/grabpaths-<port>.grabs.jsonl     one JSON body per POST /api/v3/release
  /tmp/grabpaths-<port>.requests.log    every request line
  /tmp/grabpaths-<port>.searches        number of GET /api/v3/release calls
"""
import json
import os
import re
import sys
import http.server
from urllib.parse import urlparse, parse_qs

APP = sys.argv[1]
PORT = int(sys.argv[2])


def flag(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


SCENARIO = flag("--scenario", "ok")
QUEUE = flag("--queue", "none")
INDEXER_ZERO = "--indexer-zero" in sys.argv

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "arr", "fixtures")
GRABS = "/tmp/grabpaths-%d.grabs.jsonl" % PORT
REQUESTS = "/tmp/grabpaths-%d.requests.log" % PORT
SEARCHES = "/tmp/grabpaths-%d.searches" % PORT

EPISODE = json.load(open(os.path.join(FIXTURES, "sonarr_episode.json")))
SERIES = EPISODE["series"]
MOVIE = json.load(open(os.path.join(FIXTURES, "radarr_movie.json")))
SONARR_RELEASES = json.load(open(os.path.join(FIXTURES, "sonarr_releases.json")))
RADARR_RELEASES = json.load(open(os.path.join(FIXTURES, "radarr_releases.json")))

state = {"searches": 0, "posts": 0}


def releases():
    base = SONARR_RELEASES if APP == "sonarr" else RADARR_RELEASES
    out = json.loads(json.dumps(base))
    if INDEXER_ZERO:
        for r in out:
            r["indexerId"] = 0
    return out


def approved_releases():
    """Only the releases Pickarr will offer as candidates."""
    return [r for r in releases() if not r.get("rejected")]


def queue_details():
    if QUEUE == "downloading":
        item = {
            "id": 5,
            "title": "Some.Release",
            "status": "downloading",
            "trackedDownloadStatus": "ok",
            "trackedDownloadState": "downloading",
            "downloadClient": "qBittorrent",
            "protocol": "torrent",
            "statusMessages": [],
        }
    elif QUEUE == "warning":
        item = {
            "id": 6,
            "title": "Some.Release",
            "status": "warning",
            "trackedDownloadStatus": "warning",
            "trackedDownloadState": "importPending",
            "errorMessage": "qBittorrent rejected the release",
            "downloadClient": "qBittorrent",
            "protocol": "torrent",
            "statusMessages": [{"title": "Some.Release", "messages": ["Sample file detected"]}],
        }
    else:
        return []
    if APP == "sonarr":
        item["seriesId"] = SERIES["id"]
        item["episodeId"] = EPISODE["id"]
    else:
        item["movieId"] = MOVIE["id"]
    return [item]


def missing(field, body):
    value = body.get(field)
    if value is None:
        return True
    if isinstance(value, list) and not value:
        return True
    return False


def override_is_complete(body):
    """The assertions the real controllers make (API_RESEARCH 3.3)."""
    needed = ["quality", "languages"]
    needed += ["seriesId", "episodeIds"] if APP == "sonarr" else ["movieId"]
    return [f for f in needed if missing(f, body)]


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _record(self, line):
        with open(REQUESTS, "a") as fh:
            fh.write(line + "\n")

    def _send(self, obj, code=200, raw=None):
        body = raw.encode() if raw is not None else json.dumps(obj).encode()
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
        if re.fullmatch(r"/api/v3/qualityprofile/\d+", path):
            return self._send({"id": 6, "name": "HD-1080p"})
        if path == "/api/v3/queue/details":
            return self._send(queue_details())
        if path == "/api/v3/queue":
            return self._send({"page": 1, "pageSize": 0, "totalRecords": 0, "records": []})
        if path.startswith("/api/v3/history"):
            return self._send([])
        if path == "/api/v3/release":
            state["searches"] += 1
            with open(SEARCHES, "w") as fh:
                fh.write(str(state["searches"]))
            # The release vanishes from every search after the first one, so
            # the retry has nothing to grab.
            if SCENARIO in ("cachemiss_drop", "search_drops") and state["searches"] > 1:
                return self._send([])
            return self._send(releases())
        if APP == "sonarr":
            if re.fullmatch(r"/api/v3/episode/\d+", path):
                return self._send(EPISODE)
            if path == "/api/v3/episode":
                return self._send([EPISODE])
            if re.fullmatch(r"/api/v3/series/\d+", path):
                return self._send(SERIES)
            if path == "/api/v3/series":
                return self._send([SERIES])
        else:
            if re.fullmatch(r"/api/v3/movie/\d+", path):
                return self._send(MOVIE)
            if path == "/api/v3/movie":
                return self._send([MOVIE])
        if path.startswith("/api/v3/wanted/"):
            record = EPISODE if APP == "sonarr" else MOVIE
            return self._send({"page": 1, "pageSize": 1, "totalRecords": 1, "records": [record]})
        return self._send({"message": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else ""
        self._record("POST " + self.path + " " + raw)
        if not self.path.startswith("/api/v3/release"):
            return self._send({"message": "not found"}, 404)
        with open(GRABS, "a") as fh:
            fh.write(raw + "\n")
        state["posts"] += 1
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        cache_miss = {"message": "Couldn't find requested release in cache, try searching again"}
        if SCENARIO == "permanent":
            return self._send({"message": "Unable to add release"}, 409)
        if SCENARIO == "cachemiss_drop":
            return self._send(cache_miss, 404)
        if SCENARIO == "cachemiss_then_ok" and state["posts"] == 1:
            return self._send(cache_miss, 404)
        if SCENARIO == "mapping_override":
            if not body.get("shouldOverride"):
                message = (
                    "Unable to find matching series and episodes, will need to be manually provided"
                    if APP == "sonarr"
                    else "Unable to find matching movie, will need to be manually provided"
                )
                return self._send({"message": message}, 404)
            absent = override_is_complete(body)
            if absent:
                return self._send({"message": "override is missing " + ", ".join(absent)}, 400)
        return self._send(body, 201)


if __name__ == "__main__":
    for f in (GRABS, REQUESTS):
        open(f, "w").close()
    with open(SEARCHES, "w") as fh:
        fh.write("0")
    http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
