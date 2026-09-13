#!/usr/bin/env python3
"""Fake Sonarr/Radarr for the grab-bug e2e test.

Usage: grabbug-fake-arr.py <sonarr|radarr> <port> [--grab-mode MODE]

MODE controls what POST /api/v3/release returns:
  echo     (default) 201 with the posted body echoed back, like the real apps
  nulls    200 with a ReleaseResource whose fields are mostly null
  empty    200 with an empty body
  text     200 with a non-JSON text body
  notfound 404 {"message":"Couldn't find requested release in cache, try searching again"}
  conflict 409 {"message":"Unable to add release"}

Every received POST body is appended to <port>.grabs.jsonl so the test can
assert on {guid, indexerId, episodeId|movieId}.
"""
import json
import sys
import http.server

APP = sys.argv[1]
PORT = int(sys.argv[2])
MODE = "echo"
if "--grab-mode" in sys.argv:
    MODE = sys.argv[sys.argv.index("--grab-mode") + 1]

FIX = "test/arr/fixtures/"
GRABS = "/tmp/grabbug-%d.grabs.jsonl" % PORT
REQUESTS = "/tmp/grabbug-%d.requests.log" % PORT

EPISODE = json.load(open(FIX + "sonarr_episode.json"))
SONARR_RELEASES = json.load(open(FIX + "sonarr_releases.json"))
MOVIE = json.load(open(FIX + "radarr_movie.json"))
RADARR_RELEASES = json.load(open(FIX + "radarr_releases.json"))
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

    def _record(self, line):
        with open(REQUESTS, "a") as fh:
            fh.write(line + "\n")

    def _send(self, obj, code=200, raw=None):
        if raw is not None:
            body = raw.encode()
        else:
            body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        self._record("GET " + p)
        if p.startswith("/api/v3/system/status"):
            return self._send(
                {
                    "appName": "Sonarr" if APP == "sonarr" else "Radarr",
                    "version": "4.0.0.1",
                    "instanceName": "Fake" + APP.capitalize(),
                }
            )
        if p.startswith("/api/v3/tag"):
            return self._send([])
        if p.startswith("/api/v3/qualityprofile/"):
            return self._send({"id": 1, "name": "HD-1080p"})
        if APP == "sonarr":
            if p.startswith("/api/v3/episode/"):
                return self._send(EPISODE)
            if p.startswith("/api/v3/episode?"):
                return self._send([EPISODE])
            if p.startswith("/api/v3/series/") or p.startswith("/api/v3/series?"):
                return self._send(SERIES if "/series/" in p else [SERIES])
            if p.startswith("/api/v3/release"):
                return self._send(SONARR_RELEASES)
            if p.startswith("/api/v3/wanted/"):
                return self._send({"page": 1, "pageSize": 10, "totalRecords": 1, "records": [EPISODE]})
        else:
            if p.startswith("/api/v3/movie/") or p.startswith("/api/v3/movie?"):
                return self._send(MOVIE if "/movie/" in p else [MOVIE])
            if p.startswith("/api/v3/release"):
                return self._send(RADARR_RELEASES)
            if p.startswith("/api/v3/wanted/"):
                return self._send({"page": 1, "pageSize": 10, "totalRecords": 1, "records": [MOVIE]})
        if p.startswith("/api/v3/queue"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        if p.startswith("/api/v3/history"):
            return self._send({"page": 1, "pageSize": 10, "totalRecords": 0, "records": []})
        return self._send({"message": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else ""
        self._record("POST " + self.path + " " + raw)
        if self.path.startswith("/api/v3/release"):
            with open(GRABS, "a") as fh:
                fh.write(raw + "\n")
            if MODE == "notfound":
                return self._send(
                    {"message": "Couldn't find requested release in cache, try searching again"}, 404
                )
            if MODE == "conflict":
                return self._send({"message": "Unable to add release"}, 409)
            if MODE == "empty":
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if MODE == "text":
                return self._send(None, 200, raw="Release grabbed")
            if MODE == "nulls":
                return self._send(
                    {
                        "guid": None,
                        "indexerId": 0,
                        "title": None,
                        "size": 0,
                        "rejected": False,
                        "rejections": [],
                    },
                    200,
                )
            try:
                return self._send(json.loads(raw), 201)
            except Exception:
                return self._send({}, 201)
        return self._send({"message": "not found"}, 404)


if __name__ == "__main__":
    open(GRABS, "w").close()
    open(REQUESTS, "w").close()
    http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
