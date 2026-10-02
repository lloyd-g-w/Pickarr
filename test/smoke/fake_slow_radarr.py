#!/usr/bin/env python3
"""A Radarr whose interactive search is slow, like a real one waiting on
Prowlarr and its indexers.

Usage: fake_slow_radarr.py PORT [INITIAL_DELAY_SECONDS]

Everything except GET /api/v3/release answers immediately, so a short read
timeout does not affect the rest of the flow. The search delay can be changed
while running:

    GET /__delay?seconds=7    -> {"delay": 7.0}
    GET /__fail?status=500    -> the release search answers that status (0 = stop failing)
    GET /__state              -> {"searches": n, "grabs": [...], "delay": s, "fail": status}
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0

STATE = {"searches": 0, "grabs": [], "delay": DELAY, "fail": 0}
LOCK = threading.Lock()

MOVIE = {
    "id": 440,
    "title": "Come and See",
    "year": 1985,
    "monitored": True,
    "hasFile": False,
    "qualityProfileId": 1,
    "tmdbId": 25237,
    "imdbId": "tt0091251",
    "titleSlug": "come-and-see-1985",
    "path": "/movies/Come and See (1985)",
    "runtime": 142,
    "genres": ["Drama", "War"],
    "originalLanguage": {"id": 11, "name": "Russian"},
    "tags": [],
}

RELEASES = [
    {
        "guid": "https://indexer.example/api/t/slow1",
        "title": "Come.and.See.1985.1080p.BluRay.x264-GROUP",
        "size": 12884901888,
        "indexerId": 2,
        "indexer": "Slow Indexer",
        "protocol": "torrent",
        "seeders": 31,
        "leechers": 2,
        "quality": {
            "quality": {"id": 7, "name": "Bluray-1080p", "source": "bluray", "resolution": 1080},
            "revision": {"version": 1, "real": 0, "isRepack": False},
        },
        "customFormatScore": 0,
        "customFormats": [],
        "languages": [{"id": 11, "name": "Russian"}],
        "rejected": False,
        "temporarilyRejected": False,
        "rejections": [],
        "downloadAllowed": True,
        "approved": True,
        "movieId": 440,
    }
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if path == "/__state":
            with LOCK:
                return self._send(dict(STATE))
        if path == "/__fail":
            status = int(query.get("status", ["0"])[0])
            with LOCK:
                STATE["fail"] = status
            return self._send({"fail": status})
        if path == "/__delay":
            seconds = float(query.get("seconds", ["5"])[0])
            with LOCK:
                STATE["delay"] = seconds
            return self._send({"delay": seconds})

        if path == "/api/v3/system/status":
            return self._send(
                {"appName": "Radarr", "version": "5.14.0.9383", "instanceName": "Slow Radarr"}
            )
        if path == "/api/v3/movie/440":
            return self._send(MOVIE)
        if path == "/api/v3/movie":
            return self._send([MOVIE])
        if path == "/api/v3/tag":
            return self._send([])
        if path.startswith("/api/v3/qualityprofile"):
            return self._send({"id": 1, "name": "HD-1080p"})
        if path == "/api/v3/queue":
            return self._send({"page": 1, "pageSize": 1000, "totalRecords": 0, "records": []})
        if path.startswith("/api/v3/history"):
            return self._send({"page": 1, "pageSize": 100, "totalRecords": 0, "records": []})

        if path == "/api/v3/release":
            # The interactive search: this is the call that can outlast a
            # 30 second timeout on a real instance.
            with LOCK:
                STATE["searches"] += 1
                delay = STATE["delay"]
                fail = STATE["fail"]
            time.sleep(delay)
            if fail:
                return self._send({"message": "Search failed (fake)"}, fail)
            return self._send(RELEASES)

        return self._send({"message": "not found: " + path}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode() if length else ""
        if urlparse(self.path).path == "/api/v3/release":
            with LOCK:
                STATE["grabs"].append(raw)
            return self._send({"guid": "grabbed"})
        return self._send({"message": "not found"}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
