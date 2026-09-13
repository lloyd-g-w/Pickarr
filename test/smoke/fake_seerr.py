#!/usr/bin/env python3
"""Fake Seerr for the Pickarr Seerr integration smoke test.

Serves the /api/v1 endpoints Pickarr uses and records every mutating call so
the test can assert on them. State lives in a JSON file so the driver script
can read it between steps.
"""
import json
import os
import sys
import http.server
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
STATE = sys.argv[2]

# tmdb 654321 -> the movie in test/arr/fixtures/radarr_movie.json
REQUESTS = {
    # pending movie request, not pushed to Radarr yet
    43: {
        "id": 43, "status": 1, "type": "movie", "is4k": False, "seasons": [],
        "createdAt": "2026-02-02T08:00:00.000Z",
        "media": {"id": 79, "mediaType": "movie", "tmdbId": 654321, "tvdbId": None,
                  "status": 2, "status4k": 1,
                  "externalServiceId": None, "externalServiceId4k": None},
        "requestedBy": {"id": 5, "email": "carol@example.com", "displayName": "carol"},
    },
    # approved movie request, already in Radarr
    41: {
        "id": 41, "status": 2, "type": "movie", "is4k": False, "seasons": [],
        "createdAt": "2026-02-01T09:12:00.000Z",
        "media": {"id": 77, "mediaType": "movie", "tmdbId": 654321, "tvdbId": None,
                  "status": 3, "status4k": 1,
                  "externalServiceId": 77, "externalServiceId4k": None},
        "requestedBy": {"id": 3, "email": "alice@example.com", "displayName": "alice"},
    },
    # approved movie request whose media is already AVAILABLE -> must be skipped
    40: {
        "id": 40, "status": 2, "type": "movie", "is4k": False, "seasons": [],
        "createdAt": "2026-01-20T09:12:00.000Z",
        "media": {"id": 70, "mediaType": "movie", "tmdbId": 999999, "tvdbId": None,
                  "status": 5, "status4k": 1,
                  "externalServiceId": 70, "externalServiceId4k": None},
        "requestedBy": {"id": 3, "email": "alice@example.com", "displayName": "alice"},
    },
    # approved 4K movie request -> must go to the "Radarr 4K" instance
    44: {
        "id": 44, "status": 2, "type": "movie", "is4k": True, "seasons": [],
        "createdAt": "2026-02-03T09:12:00.000Z",
        "media": {"id": 80, "mediaType": "movie", "tmdbId": 654321, "tvdbId": None,
                  "status": 5, "status4k": 3,
                  "externalServiceId": 77, "externalServiceId4k": 77},
        "requestedBy": {"id": 3, "email": "alice@example.com", "displayName": "alice"},
    },
}

TITLES = {
    ("movie", 654321): {"id": 654321, "title": "Some Movie", "releaseDate": "2024-05-01"},
    ("movie", 999999): {"id": 999999, "title": "Already Here", "releaseDate": "2020-01-01"},
}


def load():
    if os.path.exists(STATE):
        with open(STATE) as fh:
            return json.load(fh)
    return {"approved": [], "declined": [], "requests_served": 0}


def save(s):
    with open(STATE, "w") as fh:
        json.dump(s, fh)


def selected(filter_name):
    """Mirror server/routes/request.ts: which statuses each filter returns."""
    out = []
    for r in REQUESTS.values():
        if filter_name == "pending" and r["status"] == 1:
            out.append(r)
        elif filter_name == "approved" and r["status"] == 2:
            out.append(r)
        elif filter_name == "processing" and r["status"] == 2:
            status = r["media"]["status4k"] if r["is4k"] else r["media"]["status"]
            if status in (1, 2, 3, 4):
                out.append(r)
        elif filter_name == "all":
            out.append(r)
    return sorted(out, key=lambda r: r["id"])


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
        if self.headers.get("X-Api-Key") != "seerr-key":
            return self.send({"message": "unauthorized"}, 401)
        if path == "/api/v1/status":
            return self.send({"version": "3.0.1", "commitTag": "test", "updateAvailable": False})
        if path == "/api/v1/request":
            state = load()
            state["requests_served"] += 1
            save(state)
            results = selected(query.get("filter", ["all"])[0])
            return self.send({
                "pageInfo": {"page": 1, "pages": 1, "pageSize": len(results), "results": len(results)},
                "results": results,
            })
        if path == "/api/v1/request/count":
            return self.send({"total": len(REQUESTS), "movie": len(REQUESTS), "tv": 0,
                              "pending": len(selected("pending")), "approved": len(selected("approved")),
                              "declined": 0, "processing": len(selected("processing")),
                              "available": 1, "completed": 1})
        if path.startswith("/api/v1/request/"):
            rid = int(path.rsplit("/", 1)[1])
            if rid in REQUESTS:
                return self.send(REQUESTS[rid])
            return self.send({"message": "not found"}, 404)
        for kind in ("movie", "tv"):
            prefix = f"/api/v1/{kind}/"
            if path.startswith(prefix):
                tmdb = int(path[len(prefix):])
                found = TITLES.get((kind, tmdb))
                return self.send(found) if found else self.send({"message": "not found"}, 404)
        return self.send({"message": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if self.headers.get("X-Api-Key") != "seerr-key":
            return self.send({"message": "unauthorized"}, 401)
        # api/v1/request/{id}/{approve|decline}
        if len(parts) == 5 and parts[2] == "request":
            rid, action = int(parts[3]), parts[4]
            if rid not in REQUESTS:
                return self.send({"message": "not found"}, 404)
            state = load()
            if action == "approve":
                REQUESTS[rid]["status"] = 2
                REQUESTS[rid]["media"]["status"] = 3
                state["approved"].append(rid)
            elif action == "decline":
                REQUESTS[rid]["status"] = 3
                state["declined"].append(rid)
            else:
                return self.send({"message": "bad status"}, 400)
            save(state)
            return self.send(REQUESTS[rid])
        return self.send({"message": "not found"}, 404)


if __name__ == "__main__":
    save({"approved": [], "declined": [], "requests_served": 0})
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
