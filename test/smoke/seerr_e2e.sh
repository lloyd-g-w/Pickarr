#!/bin/bash
# End-to-end smoke test for the Pickarr Seerr integration.
# Ports 19300-19399 (this worker's range). Starts a fake Seerr, two fake Radarr
# instances ("Radarr" and "Radarr 4K") and Pickarr itself, then asserts on the
# calls the fakes recorded.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE" >/dev/null
PICKARR_PORT=19300
SEERR_PORT=19301
RADARR_PORT=19302
RADARR4K_PORT=19303
DATA=/tmp/seerr-e2e-data
SEERR_STATE=/tmp/seerr-e2e-seerr.json
RADARR_STATE=/tmp/seerr-e2e-radarr.json
RADARR4K_STATE=/tmp/seerr-e2e-radarr4k.json
COOKIE=/tmp/seerr-e2e-cookie
FAIL=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

rm -rf "$DATA" "$SEERR_STATE" "$RADARR_STATE" "$RADARR4K_STATE" "$COOKIE"
mkdir -p "$DATA"

python3 "$HERE"/fake_seerr.py "$SEERR_PORT" "$SEERR_STATE" & SEERR_PID=$!
python3 "$HERE"/fake_radarr_seerr.py "$RADARR_PORT" "$RADARR_STATE" "Radarr" "$REPO/test/arr/fixtures" & RADARR_PID=$!
python3 "$HERE"/fake_radarr_seerr.py "$RADARR4K_PORT" "$RADARR4K_STATE" "Radarr 4K" "$REPO/test/arr/fixtures" & RADARR4K_PID=$!
DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > /tmp/seerr-e2e-pickarr.log 2>&1 & PICKARR_PID=$!

cleanup() { kill $SEERR_PID $RADARR_PID $RADARR4K_PID $PICKARR_PID 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

sleep 3
API="http://127.0.0.1:$PICKARR_PORT"
curl -s -c "$COOKIE" -H "Content-Type: application/json" -H "Origin: $API" \
  -d '{"username":"admin","password":"secret123"}' "$API/login" -o /dev/null
CURL=(curl -s -b "$COOKIE")

configure() { # $1 = seerr json patch
  "${CURL[@]}" -X PUT -H "Content-Type: application/json" "$API/api/config" -d "$1" -o /dev/null
}

configure '{
  "instances":[
    {"id":"radarr","name":"Radarr","app":"radarr","url":"http://127.0.0.1:'$RADARR_PORT'","api_key":"k","enabled":true},
    {"id":"radarr-4k","name":"Radarr 4K","app":"radarr","url":"http://127.0.0.1:'$RADARR4K_PORT'","api_key":"k","enabled":true}
  ],
  "llm":{"enabled":false},
  "seerr":{"enabled":true,"url":"http://127.0.0.1:'$SEERR_PORT'","api_key":"seerr-key",
           "auto_approve":false,"process_approved":true,"grab":false,"max_requests_per_run":10}
}'

echo "== test: connection test reports the Seerr version"
VERSION=$("${CURL[@]}" -X POST "$API/api/seerr/test" | python3 -c "import json,sys;print(json.load(sys.stdin).get('version'))")
check "GET /status through POST /api/seerr/test" "$VERSION" "3.0.1"

echo "== test: the request list is exposed"
PENDING=$("${CURL[@]}" "$API/api/seerr/requests?filter=pending" | python3 -c "
import json,sys; d=json.load(sys.stdin); print(','.join(str(r['id']) for r in d['results']))")
check "pending request listed" "$PENDING" "43"
TITLE=$("${CURL[@]}" "$API/api/seerr/requests?filter=pending" | python3 -c "
import json,sys; d=json.load(sys.stdin); print(d['results'][0]['title'])")
check "title looked up from /movie/{tmdbId}" "$TITLE" "Some Movie"

echo "== test: dry run does not grab"
"${CURL[@]}" -X POST "$API/api/seerr/run" > /tmp/seerr-e2e-run1.json
GRABS=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['grabs']))")
check "no grab while seerr.grab is false" "$GRABS" "0"
SEARCHES=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['searches']))")
if [ "$SEARCHES" -ge 1 ]; then pass "the release search still ran (dry run)"; else fail "expected a release search, got $SEARCHES"; fi
# Seerr itself keeps AVAILABLE media out of filter=processing (mirrored by the
# fake), so request 40 must never be touched: no fulfilment entry and no
# search for its movie id. Pickarr's own guard for the same case is covered
# deterministically by the "skip reason" unit test.
TOUCHED_40=$(python3 -c "
import json; d=json.load(open('/tmp/seerr-e2e-run1.json'))
print(sum(1 for r in d['results'] if r.get('request_id') == 40))")
check "the already-available request is never processed" "$TOUCHED_40" "0"
SEARCH_70=$(python3 -c "
import json; s=json.load(open('$RADARR_STATE'))['searches'] + json.load(open('$RADARR4K_STATE'))['searches']
print(sum(1 for x in s if x == '70'))")
check "no release search for the available movie" "$SEARCH_70" "0"
APPROVED=$(python3 -c "import json;print(len(json.load(open('$SEERR_STATE'))['approved']))")
check "nothing approved while auto_approve is off" "$APPROVED" "0"

echo "== test: 4K request went to the 4K instance only"
# Two requests were fulfilled: #41 (normal) and #44 (4K). If the 4K routing
# were ignored, each instance would have been searched twice.
N_NORMAL=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['searches']))")
N_4K=$(python3 -c "import json;print(len(json.load(open('$RADARR4K_STATE'))['searches']))")
check "the normal instance handled exactly one request" "$N_NORMAL" "1"
check "the 4K instance handled exactly one request" "$N_4K" "1"
R4K=$(python3 -c "
import json; d=json.load(open('/tmp/seerr-e2e-run1.json'))
print(sum(1 for r in d['results'] if r.get('request_id') == 44 and r.get('instance') == 'Radarr 4K'
         or (r.get('request_id') == 44 and r.get('action') == 'fulfilled')))")
if [ "$R4K" -ge 1 ]; then pass "the 4K request was fulfilled"; else fail "the 4K request was not fulfilled"; fi

echo "== test: grabbing enabled + auto-approve"
rm -f "$RADARR_STATE" "$RADARR4K_STATE"
python3 - <<PY
import json
for p in ["$RADARR_STATE", "$RADARR4K_STATE"]:
    json.dump({"grabs": [], "searches": []}, open(p, "w"))
PY
configure '{"seerr":{"enabled":true,"url":"http://127.0.0.1:'$SEERR_PORT'","api_key":"********","auto_approve":true,"process_approved":true,"grab":true,"max_requests_per_run":10}}'
# The cooldown blocks a repeat of the same requests within one process, so the
# run is exercised through the per-request fulfil endpoint as well.
"${CURL[@]}" -X POST "$API/api/seerr/run" > /tmp/seerr-e2e-run2.json
APPROVED=$(python3 -c "import json;print(json.load(open('$SEERR_STATE'))['approved'])")
check "the pending request was approved in Seerr" "$APPROVED" "[43]"

echo "== test: explicit fulfil grabs"
"${CURL[@]}" -X POST "$API/api/seerr/requests/41/fulfil" > /dev/null
sleep 4
GRABS=$(python3 -c "
import json; d=json.load(open('$RADARR_STATE'))['grabs']; print(len(d))")
if [ "$GRABS" -ge 1 ]; then
  pass "the selected release was grabbed through Radarr"
  python3 -c "
import json; g=json.load(open('$RADARR_STATE'))['grabs'][0]
print('     grab body:', json.dumps(g))
assert 'guid' in g and 'indexerId' in g and 'movieId' in g, g"
else
  fail "expected a grab, got $GRABS"
fi

echo "== test: decline"
"${CURL[@]}" -X POST "$API/api/seerr/requests/40/decline" > /dev/null
DECLINED=$(python3 -c "import json;print(json.load(open('$SEERR_STATE'))['declined'])")
check "the request was declined in Seerr" "$DECLINED" "[40]"

echo "== test: poller status"
"${CURL[@]}" "$API/api/seerr/status" | python3 -c "
import json,sys; s=json.load(sys.stdin)
print('     enabled:', s['enabled'], 'configured:', s['configured'], 'runs:', s['runs'], 'last_error:', s['last_error'])
assert s['enabled'] and s['configured'], s
assert s['runs'] >= 2, s"

echo
grep -a -i "seerr" /tmp/seerr-e2e-pickarr.log | grep -v dream.logger | tail -12
echo
if [ $FAIL -eq 0 ]; then echo "ALL SEERR E2E CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $FAIL
