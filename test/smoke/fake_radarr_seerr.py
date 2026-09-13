#!/usr/bin/env python3
"""Fake Radarr for the Pickarr Seerr integration smoke test.

Serves the endpoints Client.fetch_media / search_releases / grab use and
records grabs to a JSON file. argv: <port> <state file> <instance name>
"""
import json
import os
import sys
import http.server
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
STATE = sys.argv[2]
NAME = sys.argv[3]
FIXTURES = sys.argv[4]

MOVIE = json.load(open(os.path.join(FIXTURES, "radarr_movie.json")))
RELEASES = json.load(open(os.path.join(FIXTURES, "radarr_releases.json")))


def load():
    if os.path.exists(STATE):
        with open(STATE) as fh:
            return json.load(fh)
    return {"grabs": [], "searches": []}


def save(s):
    with open(STATE, "w") as fh:
        json.dump(s, fh)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        if path == "/api/v3/system/status":
            return self.send({"appName": "Radarr", "version": "5.14.0.9383", "instanceName": NAME})
        if path == "/api/v3/movie":
            tmdb = int(query.get("tmdbId", ["0"])[0])
            return self.send([MOVIE] if tmdb == MOVIE["tmdbId"] else [])
        if path.startswith("/api/v3/movie/"):
            mid = int(path.rsplit("/", 1)[1])
            return self.send(MOVIE) if mid == MOVIE["id"] else self.send({"message": "not found"}, 404)
        if path == "/api/v3/release":
            state = load()
            state["searches"].append(query.get("movieId", [""])[0])
            save(state)
            return self.send(RELEASES)
        if path == "/api/v3/tag":
            return self.send([])
        if path.startswith("/api/v3/qualityprofile/"):
            return self.send({"id": 4, "name": "Ultra-HD"})
        return self.send({"message": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if urlparse(self.path).path == "/api/v3/release":
            state = load()
            state["grabs"].append(body)
            save(state)
            return self.send(body)
        return self.send({"message": "not found"}, 404)


if __name__ == "__main__":
    save({"grabs": [], "searches": []})
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
