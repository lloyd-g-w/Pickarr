#!/usr/bin/env python3
"""Fake Sonarr whose releases have magnet-link guids.

Usage: fake_sonarr_magnet.py <port>

Serves just enough of the Sonarr v3 API for one interactive-search selection
(system/status, episode, series, tag, qualityprofile, release) and records
every grab body to /tmp/pickarr-llm-e2e-<port>.grabs.jsonl.  The releases come
from test/smoke/fixtures/sonarr_releases_magnet.json, whose guids are real
magnet links of 200-320 characters: that is the shape that used to make the
model's answer unusable.
"""
import json
import os
import sys
import http.server

PORT = int(sys.argv[1])
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
GRABS = "/tmp/pickarr-llm-e2e-%d.grabs.jsonl" % PORT

EPISODE = json.load(open(os.path.join(REPO, "test/arr/fixtures/sonarr_episode.json")))
RELEASES = json.load(open(os.path.join(HERE, "fixtures/sonarr_releases_magnet.json")))
SERIES = EPISODE.get("series") or {
    "id": EPISODE["seriesId"],
    "title": "Some Show",
    "seriesType": "standard",
    "monitored": True,
}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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
        p = self.path
        if p.startswith("/api/v3/system/status"):
            return self._send(
                {"appName": "Sonarr", "version": "4.0.0.1", "instanceName": "FakeSonarr"}
            )
        if p.startswith("/api/v3/tag"):
            return self._send([])
        if p.startswith("/api/v3/qualityprofile/"):
            return self._send({"id": 1, "name": "HD-1080p"})
        if p.startswith("/api/v3/episode/"):
            return self._send(EPISODE)
        if p.startswith("/api/v3/episode?"):
            return self._send([EPISODE])
        if p.startswith("/api/v3/series/"):
            return self._send(SERIES)
        if p.startswith("/api/v3/series?"):
            return self._send([SERIES])
        if p.startswith("/api/v3/release"):
            return self._send(RELEASES)
        if p.startswith("/api/v3/queue"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        if p.startswith("/api/v3/history"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        return self._send({"message": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else ""
        if self.path.startswith("/api/v3/release"):
            with open(GRABS, "a") as fh:
                fh.write(raw + "\n")
            try:
                return self._send(json.loads(raw), 201)
            except Exception:
                return self._send({}, 201)
        return self._send({"message": "not found"}, 404)


http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
