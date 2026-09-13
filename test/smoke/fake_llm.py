#!/usr/bin/env python3
"""Fake OpenAI-compatible server for the LLM prompt e2e test.

Usage: fake_llm.py <port> <mode> [state-file]

MODE decides what the assistant answers:
  short      valid strict JSON using the short ids it was given
  mangled    a valid selected_id, but one ranking entry echoes a truncated
             magnet link (the failure the user reported)
  titles     answers with the candidate's title instead of its id
  percent    confidence given as 85 instead of 0.85, ranking omitted
  prose      no JSON at all
  truncated  finish_reason=length with a cut-off body

The request the server received is written to the state file (default
/tmp/pickarr-llm-e2e-request.json) so the test can assert on the prompt.
"""
import json
import re
import sys
import http.server

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "short"
STATE = sys.argv[3] if len(sys.argv) > 3 else "/tmp/pickarr-llm-e2e-request.json"

MANGLED = (
    "magnet:?xt=urn:btih:C3A821D65D39BE40989D733376A553CC116CD04B&dn=The+Dead+"
    "Pool+%281988+ITA%2FENG%29+%5B1080p+x265%5D+%5BPaso77%5D&tr=udp%3A%2F%2Ftracker"
)


def answer(user_message):
    """Build the assistant content for MODE, using the prompt we were sent."""
    try:
        payload = json.loads(user_message)
        candidates = payload.get("candidates") or []
    except Exception:
        candidates = []
    ids = [c.get("id") for c in candidates]
    titles = [c.get("title") for c in candidates]
    first = ids[0] if ids else "r1"
    second = ids[1] if len(ids) > 1 else first

    if MODE == "short":
        return json.dumps(
            {
                "selected_id": second,
                "confidence": 0.93,
                "reason": "smaller x265 encode with plenty of seeders",
                "ranking": [
                    {"id": second, "score": 95, "reason": "best size/quality trade-off"},
                    {"id": first, "score": 60, "reason": "much larger for little gain"},
                ],
                "influences": ["you prefer x265 when quality is comparable"],
                "conflicts": [],
            }
        )
    if MODE == "mangled":
        return json.dumps(
            {
                "selected_id": first,
                "confidence": 0.88,
                "reason": "best available source",
                "ranking": [
                    {"id": first, "score": 90, "reason": "best source"},
                    {"id": MANGLED, "score": 40, "reason": "worse encode"},
                ],
                "influences": ["you prefer WEB-DL over WEBRip"],
            }
        )
    if MODE == "titles":
        return json.dumps(
            {
                "selected_id": titles[0] if titles else "unknown",
                "confidence": 0.7,
                "reason": "answered with the title instead of the id",
                "ranking": [{"id": titles[0] if titles else "unknown", "score": 80}],
            }
        )
    if MODE == "percent":
        return json.dumps(
            {"selected_id": first, "confidence": 85, "reason": "percentage confidence"}
        )
    if MODE == "prose":
        return "I would go with the first one, it looks like the best quality."
    if MODE == "truncated":
        return '{"selected_id":"' + first + '","confidence":0.9,"ranking":[{"id":"'
    raise SystemExit("unknown mode " + MODE)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode() if n else "{}"
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        with open(STATE, "w") as fh:
            json.dump(req, fh)
        messages = req.get("messages") or []
        user = ""
        system = ""
        for m in messages:
            if m.get("role") == "user":
                user = m.get("content") or ""
            if m.get("role") == "system":
                system = m.get("content") or ""
        _ = system
        content = answer(user)
        finish = "length" if MODE == "truncated" else "stop"
        body = json.dumps(
            {
                "id": "chatcmpl-fake",
                "object": "chat.completion",
                "model": req.get("model", "fake"),
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": finish,
                    }
                ],
                "usage": {"total_tokens": len(re.findall(r"\S+", user))},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
