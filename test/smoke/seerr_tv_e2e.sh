#!/bin/bash
# End-to-end smoke test for Seerr TV requests: an approved request for one
# season must be resolved to the Sonarr series by TheTVDB id and satisfied by
# a single season pack, not by one grab per episode.
#
# Ports 19210-19212. Fakes: fake_seerr.py (FAKE_SEERR_MODE=tv) and
# fake_sonarr_seasons.py (series 12, tvdbId 7654321, season 2 fully missing).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PICKARR_PORT=19210
SEERR_PORT=19211
SONARR_PORT=19212
DATA=/tmp/seerr-tv-e2e-data
SEERR_STATE=/tmp/seerr-tv-e2e-seerr.json
COOKIE=/tmp/seerr-tv-e2e-cookie
SONARR_LOG=/tmp/seerr-tv-e2e-sonarr.log
PICKARR_LOG=/tmp/seerr-tv-e2e-pickarr.log
FAIL=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

rm -rf "$DATA" "$SEERR_STATE" "$COOKIE" "$SONARR_LOG"; mkdir -p "$DATA"

FAKE_SEERR_MODE=tv python3 "$HERE"/fake_seerr.py "$SEERR_PORT" "$SEERR_STATE" & SEERR_PID=$!
python3 "$HERE"/fake_sonarr_seasons.py "$SONARR_PORT" > "$SONARR_LOG" 2>&1 & SONARR_PID=$!
DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > "$PICKARR_LOG" 2>&1 & PICKARR_PID=$!

cleanup() { kill $SEERR_PID $SONARR_PID $PICKARR_PID 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

sleep 3
API="http://127.0.0.1:$PICKARR_PORT"
curl -s -c "$COOKIE" -H "Content-Type: application/json" -H "Origin: $API" \
  -d '{"username":"admin","password":"secret123"}' "$API/login" -o /dev/null
CURL=(curl -s -b "$COOKIE")

"${CURL[@]}" -X PUT -H "Content-Type: application/json" "$API/api/config" -d '{
  "instances":[
    {"id":"sonarr","name":"Sonarr","app":"sonarr","url":"http://127.0.0.1:'$SONARR_PORT'","api_key":"k","enabled":true}
  ],
  "llm":{"enabled":false},
  "seasons":{"prefer_packs":true,"min_missing_fraction":0.5,"fallback_to_episodes":true},
  "seerr":{"enabled":true,"url":"http://127.0.0.1:'$SEERR_PORT'","api_key":"seerr-key",
           "auto_approve":false,"process_approved":true,"grab":true,"max_requests_per_run":10}
}' -o /dev/null

echo "== test: the TV request is listed with its requested season"
"${CURL[@]}" "$API/api/seerr/requests?filter=processing" > /tmp/seerr-tv-e2e-list.json
LISTED=$(python3 -c "
import json; d=json.load(open('/tmp/seerr-tv-e2e-list.json'))
r=d['results'][0]; print(r['id'], r['type'], r['tvdb_id'], r['seasons'], r['title'])")
check "request 45 is a tv request for season 2" "$LISTED" "45 tv 7654321 [2] Some Show"

echo "== test: one pass fulfils it with a season pack"
"${CURL[@]}" -X POST "$API/api/seerr/run" > /tmp/seerr-tv-e2e-run.json
sleep 1

LOOKUP=$(grep -c "GET /api/v3/series?tvdbId=7654321" "$SONARR_LOG" || true)
if [ "$LOOKUP" -ge 1 ]; then pass "the series was resolved by TheTVDB id"; else fail "no /series?tvdbId= lookup"; fi

PACK_SEARCH=$(grep -c "GET /api/v3/release?seriesId=12&seasonNumber=2" "$SONARR_LOG" || true)
if [ "$PACK_SEARCH" -ge 1 ]; then pass "a season-pack search ran for season 2"; else fail "no season-pack search"; fi

EP_SEARCH=$(grep -c "GET /api/v3/release?episodeId=" "$SONARR_LOG" || true)
check "no per-episode search was needed" "$EP_SEARCH" "0"

echo "== test: exactly one grab, with a season-pack body"
GRABS=$(curl -s "http://127.0.0.1:$SONARR_PORT/__grabs")
echo "     grabs: $GRABS"
python3 - "$GRABS" <<'PY' || FAIL=1
import json, sys
grabs = json.loads(sys.argv[1])
assert len(grabs) == 1, f"expected exactly one grab (the pack), got {len(grabs)}: {grabs}"
g = grabs[0]
for key in ("guid", "indexerId", "seriesId"):
    assert key in g, f"grab body is missing {key}: {g}"
assert "episodeId" not in g, f"a season grab must not name an episode: {g}"
assert g["seriesId"] == 12, g
print("  PASS: the grab body is {guid, indexerId, seriesId}")
PY

echo "== test: the pass summary carries the per-season outcome"
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-tv-e2e-run.json'))
entries = [r for r in d['results'] if r.get('request_id') == 45 and 'seasons' in r]
assert entries, f"no fulfilment entry with per-season detail: {json.dumps(d)[:600]}"
seasons = entries[0]['seasons']
assert len(seasons) == 1, seasons
s = seasons[0]
assert s['season_number'] == 2 and s['kind'] == 'pack', s
assert s['grabbed'] is True, s
assert s['missing'] == 2 and s['total'] == 2, s
assert 'S02' in (s.get('selected') or ''), s
print("  PASS: summary reports season 2 as a grabbed pack:", s['selected'])
print("  PASS: items counted per season:", entries[0]['items'])
PY

echo "== test: the same detail is available through the poller status"
python3 - <(("${CURL[@]}" "$API/api/seerr/status")) <<'PY' || FAIL=1
import json, sys
s = json.load(open(sys.argv[1]))
results = s.get('last_results') or []
seasons = [x for r in results for x in (r.get('seasons') or [])]
assert seasons, f"poller status has no per-season detail: {json.dumps(results)[:400]}"
assert seasons[0]['kind'] == 'pack', seasons
print("  PASS: /api/seerr/status exposes the season outcome for the UI")
PY

echo
grep -a -i "seerr\|season" "$PICKARR_LOG" | grep -v -E "dream.logger|cohttp.client" | tail -10
echo
if [ $FAIL -eq 0 ]; then echo "ALL SEERR TV E2E CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $FAIL
