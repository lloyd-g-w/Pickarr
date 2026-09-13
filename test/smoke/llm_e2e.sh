#!/bin/bash
# End-to-end smoke test for AI selection when release guids are magnet links.
#
#   bash test/smoke/llm_e2e.sh
#
# Reproduces the reported failure ("AI unavailable, used deterministic
# scoring: invalid response: ranking contains unknown release id
# \"magnet:?xt=urn:btih:...\"") against the real binary, a fake Sonarr whose
# guids are 200-320 character magnet links, and a fake OpenAI-compatible
# server that answers in several sloppy ways.
#
# Ports 19400-19449 belong to this worker.
set -u

WT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$WT/test/smoke"
PK_PORT=19400
SONARR_PORT=19401
LLM_PORT=19402
DATA=/tmp/pickarr-llm-e2e-data
COOKIE=/tmp/pickarr-llm-e2e-cookie
REQ=/tmp/pickarr-llm-e2e-request.json
RESP=/tmp/pickarr-llm-e2e-resp.json
BASE=http://127.0.0.1:$PK_PORT
EP=5150
FAIL=0

cd "$WT" || exit 1

cleanup() {
  for pid in ${PIDS:-}; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  PASS $1"
  else
    echo "  FAIL $1: expected [$2] got [$3]"
    FAIL=$((FAIL + 1))
  fi
}

start_llm() { # start_llm <mode>
  if [ -n "${LLM_PID:-}" ]; then kill "$LLM_PID" 2>/dev/null; wait "$LLM_PID" 2>/dev/null; fi
  rm -f "$REQ"
  python3 "$HERE/fake_llm.py" $LLM_PORT "$1" "$REQ" &
  LLM_PID=$!
  PIDS="${PIDS:-} $LLM_PID"
  for _ in $(seq 1 40); do
    sleep 0.1
    (exec 3<>/dev/tcp/127.0.0.1/$LLM_PORT) 2>/dev/null && { exec 3<&-; break; }
  done
}

select_now() { # select_now <label>
  curl -s -o $RESP -b $COOKIE -X POST -H 'Content-Type: application/json' \
    "$BASE/api/select/sonarr/episode/$EP" -d '{"grab":false,"use_ai":true}' >/dev/null
  echo "-- $1"
}

jq_field() { python3 -c "
import json,sys
r=json.load(open('$RESP'))
path='$1'.split('.')
cur=r
for k in path:
    if cur is None: break
    cur=cur.get(k) if isinstance(cur,dict) else None
print(json.dumps(cur))"; }

rm -rf "$DATA"; mkdir -p "$DATA"; rm -f "$COOKIE" "/tmp/pickarr-llm-e2e-$SONARR_PORT.grabs.jsonl"

python3 "$HERE/fake_sonarr_magnet.py" $SONARR_PORT & PIDS="$!"
DATA_DIR=$DATA PORT=$PK_PORT HOST=127.0.0.1 PICKARR_USERNAME=admin \
  PICKARR_PASSWORD=secret123 ./_build/default/bin/main.exe > /tmp/pickarr-llm-e2e-server.log 2>&1 & PIDS="$PIDS $!"

for _ in $(seq 1 60); do
  sleep 0.25
  curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break
done

echo "== login and configure"
code=$(curl -s -o /dev/null -w '%{http_code}' -c $COOKIE -H 'Content-Type: application/json' \
  -H "Origin: $BASE" -d '{"username":"admin","password":"secret123"}' "$BASE/login")
check "login 200" 200 "$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -b $COOKIE -X PUT -H 'Content-Type: application/json' \
  "$BASE/api/config" -d "{
    \"instances\":[{\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"http://127.0.0.1:$SONARR_PORT\",\"api_key\":\"k\",\"enabled\":true}],
    \"llm\":{\"enabled\":true,\"base_url\":\"http://127.0.0.1:$LLM_PORT/v1\",\"api_key\":\"x\",\"model\":\"local\",\"json_mode\":false},
    \"hard_rules\":{\"min_seeders\":0},
    \"nl_preferences\":\"Prefer x265 when quality is comparable.\"}")
check "config PUT 200" 200 "$code"

echo
echo "== (a) the model answers with the short ids"
start_llm short
select_now "valid answer"
check "method is llm" '"llm"' "$(jq_field method.kind)"
python3 - <<'PY'
import json
req = json.load(open('/tmp/pickarr-llm-e2e-request.json'))
user = [m for m in req.get('messages', []) if m.get('role') == 'user'][0]['content']
system = [m for m in req.get('messages', []) if m.get('role') == 'system'][0]['content']
payload = json.loads(user)
fails = 0
def check(label, ok, extra=""):
    global fails
    print(("  PASS " if ok else "  FAIL ") + label + ("" if ok else " " + extra))
    if not ok: fails += 1

check("top level keys, media first",
      list(payload.keys()) == ["media", "hard_constraints", "structured_preferences",
                               "natural_language_preferences", "temporary_instruction",
                               "candidates"],
      str(list(payload.keys())))
ids = [c["id"] for c in payload["candidates"]]
check("candidate ids are r1..rN", ids == ["r%d" % (i + 1) for i in range(len(ids))], str(ids))
blob = json.dumps(payload["candidates"])
for needle in ("magnet:", "urn:btih", "&tr=", "guid", "downloadUrl", "infoHash"):
    check("candidates never contain %r" % needle, needle not in blob)
check("candidates carry a deterministic rank",
      all("deterministic_rank" in c for c in payload["candidates"]))
check("nl preferences passed verbatim",
      "Prefer x265 when quality is comparable." in payload["natural_language_preferences"])
check("system prompt teaches the short ids",
      "r1, r2" in system and "magnet" in system.lower())
raise SystemExit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
python3 - <<'PY'
import json
r = json.load(open('/tmp/pickarr-llm-e2e-resp.json'))
sel = (r.get("selected") or {}).get("release") or {}
llm = r.get("llm") or {}
ok = sel.get("id", "").startswith("magnet:")
print(("  PASS " if ok else "  FAIL ") + "the selected id is the real magnet guid")
ids = [e["id"] for e in llm.get("ranking", [])]
ok2 = all(i.startswith("magnet:") for i in ids) and len(ids) == 2
print(("  PASS " if ok2 else "  FAIL ") + "ranking ids were translated back to real ids " + str(len(ids)))
notes = [b for b in r.get("explanation", []) if b.startswith("AI response note")]
print(("  PASS " if not notes else "  FAIL ") + "a clean answer produces no notes " + str(notes))
PY

echo
echo "== (b) the model mangles a magnet link in the ranking"
start_llm mangled
select_now "mangled ranking id"
check "still an AI selection" '"llm"' "$(jq_field method.kind)"
python3 - <<'PY'
import json
r = json.load(open('/tmp/pickarr-llm-e2e-resp.json'))
llm = r.get("llm") or {}
ids = [e["id"] for e in llm.get("ranking", [])]
ok = len(ids) == 1 and ids[0].startswith("magnet:")
print(("  PASS " if ok else "  FAIL ") + "the unusable entry was dropped, the good one kept " + str(len(ids)))
notes = [b for b in r.get("explanation", []) if b.startswith("AI response note")]
print(("  PASS " if notes else "  FAIL ") + "the user is told what was repaired: " + str(notes))
PY

echo
echo "== (c) the model replies with prose"
start_llm prose
select_now "prose"
check "falls back to deterministic" '"deterministic_fallback"' "$(jq_field method.kind)"
python3 - <<'PY'
import json
r = json.load(open('/tmp/pickarr-llm-e2e-resp.json'))
err = (r.get("method") or {}).get("llm_error") or ""
print(("  PASS " if "not JSON" in err or "not json" in err.lower() else "  FAIL ")
      + "the reason names the problem: " + err[:90])
print(("  PASS " if r.get("selected") else "  FAIL ") + "a release is still selected")
PY

echo
echo "== (d) the model answers with a title instead of an id"
start_llm titles
select_now "title as id"
check "title resolved, still an AI selection" '"llm"' "$(jq_field method.kind)"

echo
echo "== (e) confidence given as a percentage, ranking omitted"
start_llm percent
select_now "percentage confidence"
check "still an AI selection" '"llm"' "$(jq_field method.kind)"
python3 - <<'PY'
import json
r = json.load(open('/tmp/pickarr-llm-e2e-resp.json'))
c = (r.get("llm") or {}).get("confidence")
print(("  PASS " if c == 0.85 else "  FAIL ") + "85 was read as 0.85, got " + str(c))
ids = [e["id"] for e in (r.get("llm") or {}).get("ranking", [])]
print(("  PASS " if len(ids) == 1 else "  FAIL ") + "a missing ranking becomes the pick alone " + str(len(ids)))
PY

echo
echo "== (f) the answer is cut off (finish_reason=length)"
start_llm truncated
select_now "truncated"
check "falls back to deterministic" '"deterministic_fallback"' "$(jq_field method.kind)"
python3 - <<'PY'
import json
r = json.load(open('/tmp/pickarr-llm-e2e-resp.json'))
err = (r.get("method") or {}).get("llm_error") or ""
print(("  PASS " if "max_tokens" in err else "  FAIL ") + "the reason suggests raising max_tokens: " + err[:90])
PY

echo
echo "== grab still uses the real magnet guid"
start_llm short
curl -s -o $RESP -b $COOKIE -X POST -H 'Content-Type: application/json' \
  "$BASE/api/select/sonarr/episode/$EP" -d '{"grab":true,"use_ai":true}' >/dev/null
check "grabbed" true "$(jq_field grabbed)"
python3 - "$SONARR_PORT" <<'PY'
import json, sys
line = open("/tmp/pickarr-llm-e2e-%s.grabs.jsonl" % sys.argv[1]).read().strip().splitlines()[-1]
b = json.loads(line)
ok = b.get("guid", "").startswith("magnet:?xt=urn:btih:") and b.get("episodeId") == 5150
print(("  PASS " if ok else "  FAIL ") + "Sonarr received the full magnet guid (%d chars)" % len(b.get("guid", "")))
PY

echo
echo "== server log (warnings/errors only)"
grep -aE "WARN|ERROR" /tmp/pickarr-llm-e2e-server.log | grep -v dream.logger | tail -8

echo
if [ "$FAIL" -eq 0 ]; then
  echo "LLM E2E RESULT: all shell checks passed (read the PASS/FAIL lines above)"
else
  echo "LLM E2E RESULT: $FAIL check(s) FAILED"
fi
exit $FAIL
