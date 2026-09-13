#!/bin/bash
# End-to-end smoke test for working a Seerr request like the Select page:
# resolve it, preview the ranked candidates, grab the winner, and grab a
# specific season pack by release id.
#
# Ports 19450-19459. Phase 1 uses fake_seerr.py (movie requests) with
# fake_radarr_seerr.py; phase 2 uses FAKE_SEERR_MODE=tv with
# fake_sonarr_seasons.py (series 12, tvdbId 7654321, season 2 fully missing).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PICKARR_PORT=19450
SEERR_PORT=19451
RADARR_PORT=19452
PICKARR_TV_PORT=19455
SEERR_TV_PORT=19456
SONARR_PORT=19457

DATA=/tmp/seerr-ux-data
DATA_TV=/tmp/seerr-ux-tv-data
SEERR_STATE=/tmp/seerr-ux-seerr.json
SEERR_TV_STATE=/tmp/seerr-ux-tv-seerr.json
RADARR_STATE=/tmp/seerr-ux-radarr.json
COOKIE=/tmp/seerr-ux-cookie
FAIL=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

rm -rf "$DATA" "$DATA_TV" "$SEERR_STATE" "$SEERR_TV_STATE" "$RADARR_STATE" "$COOKIE"
mkdir -p "$DATA" "$DATA_TV"

python3 "$HERE"/fake_seerr.py "$SEERR_PORT" "$SEERR_STATE" & SEERR_PID=$!
python3 "$HERE"/fake_radarr_seerr.py "$RADARR_PORT" "$RADARR_STATE" "Radarr" "$REPO/test/arr/fixtures" & RADARR_PID=$!
DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > /tmp/seerr-ux-pickarr.log 2>&1 & PICKARR_PID=$!

FAKE_SEERR_MODE=tv python3 "$HERE"/fake_seerr.py "$SEERR_TV_PORT" "$SEERR_TV_STATE" & SEERR_TV_PID=$!
python3 "$HERE"/fake_sonarr_seasons.py "$SONARR_PORT" > /tmp/seerr-ux-sonarr.log 2>&1 & SONARR_PID=$!
DATA_DIR="$DATA_TV" PORT=$PICKARR_TV_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > /tmp/seerr-ux-tv-pickarr.log 2>&1 & PICKARR_TV_PID=$!

cleanup() {
  kill $SEERR_PID $RADARR_PID $PICKARR_PID $SEERR_TV_PID $SONARR_PID $PICKARR_TV_PID 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

sleep 3
API="http://127.0.0.1:$PICKARR_PORT"
API_TV="http://127.0.0.1:$PICKARR_TV_PORT"
login() { # $1 = base url, $2 = cookie jar
  curl -s -c "$2" -H "Content-Type: application/json" -H "Origin: $1" \
    -d '{"username":"admin","password":"secret123"}' "$1/login" -o /dev/null
}
login "$API" "$COOKIE"
login "$API_TV" "$COOKIE.tv"
CURL=(curl -s -b "$COOKIE")
CURL_TV=(curl -s -b "$COOKIE.tv")

"${CURL[@]}" -X PUT -H "Content-Type: application/json" "$API/api/config" -d '{
  "instances":[
    {"id":"radarr","name":"Radarr","app":"radarr","url":"http://127.0.0.1:'$RADARR_PORT'","api_key":"k","enabled":true}
  ],
  "llm":{"enabled":false},
  "seerr":{"enabled":true,"url":"http://127.0.0.1:'$SEERR_PORT'","api_key":"seerr-key",
           "auto_approve":false,"process_approved":true,"grab":false,"max_requests_per_run":10}
}' -o /dev/null

"${CURL_TV[@]}" -X PUT -H "Content-Type: application/json" "$API_TV/api/config" -d '{
  "instances":[
    {"id":"sonarr","name":"Sonarr","app":"sonarr","url":"http://127.0.0.1:'$SONARR_PORT'","api_key":"k","enabled":true}
  ],
  "llm":{"enabled":false},
  "seasons":{"prefer_packs":true,"min_missing_fraction":0.5,"fallback_to_episodes":true},
  "seerr":{"enabled":true,"url":"http://127.0.0.1:'$SEERR_TV_PORT'","api_key":"seerr-key",
           "auto_approve":false,"process_approved":true,"grab":false,"max_requests_per_run":10}
}' -o /dev/null

echo "== test: a movie request resolves to a Radarr movie id"
"${CURL[@]}" -X POST "$API/api/seerr/requests/41/resolve" > /tmp/seerr-ux-resolve41.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-resolve41.json'))
assert d['request']['id'] == 41 and d['request']['title'] == 'Some Movie', d['request']
t = d['targets']
assert len(t) == 1, t
assert t[0]['kind'] == 'movie' and t[0]['media_id'] == 77, t
assert t[0]['instance_id'] == 'radarr', t
print('  PASS: target is movie id 77 on the Radarr instance')
PY
GRABS=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['grabs']))")
SEARCHES=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['searches']))")
check "resolve does not search" "$SEARCHES" "0"
check "resolve does not grab" "$GRABS" "0"

echo "== test: preview runs the pipeline without grabbing"
"${CURL[@]}" -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/41/select" \
  -d '{"grab":false,"use_ai":false,"instruction":"prefer smaller files for this one"}' \
  > /tmp/seerr-ux-preview.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-preview.json'))
assert d['kind'] == 'movie', d.get('kind')
assert d['grabbed'] == 0, d
s = d['selection']
assert s['candidates'], 'no candidates in the preview'
assert s['grabbed'] is False, s['grabbed']
assert s['selected'], 'nothing selected'
assert d['instance_id'] == 'radarr' and d['instance_name'] == 'Radarr', d
print('  PASS: preview selected', s['selected']['release']['title'])
print('  PASS: %d candidate(s), %d rejected' % (len(s['candidates']), len(s['rejected'])))
PY
SEARCHES=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['searches']))")
GRABS=$(python3 -c "import json;print(len(json.load(open('$RADARR_STATE'))['grabs']))")
check "preview searched the indexers" "$SEARCHES" "1"
check "preview did not POST /api/v3/release" "$GRABS" "0"

echo "== test: select & grab grabs the winner"
"${CURL[@]}" -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/41/select" \
  -d '{"grab":true,"use_ai":false}' > /tmp/seerr-ux-grab.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-grab.json'))
assert d['grabbed'] == 1, d['grabbed']
assert d['selection']['grabbed'] is True, d['selection']['grabbed']
print('  PASS: grabbed', d['selection']['selected']['release']['title'])
PY
python3 - <<PY || FAIL=1
import json
g = json.load(open('$RADARR_STATE'))['grabs']
assert len(g) == 1, g
for key in ('guid', 'indexerId', 'movieId'):
    assert key in g[0], g[0]
print('  PASS: grab body is', json.dumps(g[0]))
PY

echo "== test: a pending request refuses to be selected"
CODE=$("${CURL[@]}" -o /tmp/seerr-ux-pending.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/43/select" -d '{"grab":false}')
check "pending select is refused" "$CODE" "409"
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-pending.json'))
assert 'pending approval' in d['error'], d
print('  PASS:', d['error'])
PY
APPROVED=$(python3 -c "import json;print(json.load(open('$SEERR_STATE'))['approved'])")
check "the refused select approved nothing" "$APPROVED" "[]"

echo "== test: approve:true approves first, then selects"
CODE=$("${CURL[@]}" -o /tmp/seerr-ux-approve.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/43/select" \
  -d '{"grab":false,"approve":true}')
check "approve & select succeeds" "$CODE" "200"
APPROVED=$(python3 -c "import json;print(json.load(open('$SEERR_STATE'))['approved'])")
check "the request was approved in Seerr" "$APPROVED" "[43]"
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-approve.json'))
assert d['kind'] == 'movie', d.get('kind')
assert d['request']['status_label'] == 'approved', d['request']
assert d['selection']['candidates'], d
print('  PASS: approved then selected', d['selection']['selected']['release']['title'])
PY

echo "== test: bad input is rejected before anything runs"
CODE=$("${CURL[@]}" -o /tmp/seerr-ux-bad.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/41/select" \
  -d '{"season_number":"nonsense"}')
check "a bad season number is a 400" "$CODE" "400"
CODE=$("${CURL[@]}" -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/seerr/requests/41/select" \
  -d '{"instance_id":"nope"}')
check "an unknown instance is a 404" "$CODE" "404"
CODE=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "$API/api/seerr/requests/9999/resolve")
check "an unknown request is a 404" "$CODE" "404"

echo
echo "== test: a TV request resolves to a series with its seasons"
"${CURL_TV[@]}" -X POST "$API_TV/api/seerr/requests/45/resolve" > /tmp/seerr-ux-resolve45.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-resolve45.json'))
t = d['targets']
assert len(t) == 1 and t[0]['kind'] == 'series', t
assert t[0]['series_id'] == 12, t
seasons = t[0]['seasons']
assert len(seasons) == 1, seasons
s = seasons[0]
assert s['season_number'] == 2 and s['missing'] == 2 and s['total'] == 2, s
print('  PASS: series 12, season 2 (%d/%d missing)' % (s['missing'], s['total']))
PY

echo "== test: selecting one season picks a pack"
"${CURL_TV[@]}" -X POST -H "Content-Type: application/json" "$API_TV/api/seerr/requests/45/select" \
  -d '{"grab":false,"season_number":2}' > /tmp/seerr-ux-season.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-season.json'))
assert d['kind'] == 'season', d.get('kind')
s = d['selection']
assert s['media']['media_kind'] == 'season' and s['media']['season_number'] == 2, s['media']
titles = [c['release']['title'] for c in s['candidates']]
assert titles and all('.S02.' in t for t in titles), titles
reasons = [x['rule'] for r in s['rejected'] for x in r['reasons']]
assert 'not_season_pack' in reasons, reasons
assert s['selected'], 'no pack selected'
open('/tmp/seerr-ux-release-id.txt', 'w').write(s['selected']['release']['id'])
open('/tmp/seerr-ux-rejected-id.txt', 'w').write(
    next(r['release']['id'] for r in s['rejected']
         if any(x['rule'] == 'not_season_pack' for x in r['reasons'])))
print('  PASS: pack selected:', s['selected']['release']['title'])
print('  PASS: non-packs rejected with not_season_pack')
PY
EP_SEARCH=$(grep -c "GET /api/v3/release?episodeId=" /tmp/seerr-ux-sonarr.log || true)
check "no per-episode search was needed" "$EP_SEARCH" "0"

echo "== test: a specific pack is grabbed through the season grab route"
RELEASE_ID=$(cat /tmp/seerr-ux-release-id.txt)
CODE=$("${CURL_TV[@]}" -o /tmp/seerr-ux-packgrab.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API_TV/api/grab/sonarr/season/12/2" \
  -d "{\"release_id\":\"$RELEASE_ID\"}")
check "the season grab route answers 200" "$CODE" "200"
python3 - <<PY || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-packgrab.json'))
assert d['grabbed'] is True, d.get('grab_error')
assert d['selected']['release']['id'] == "$RELEASE_ID", d['selected']['release']['id']
g = json.loads('''$(curl -s http://127.0.0.1:$SONARR_PORT/__grabs)''')
assert len(g) == 1, g
for key in ('guid', 'indexerId', 'seriesId'):
    assert key in g[0], g[0]
assert 'episodeId' not in g[0], g[0]
print('  PASS: grab body is', json.dumps(g[0]))
PY

echo "== test: a non-pack release cannot be grabbed as a pack"
REJECTED_ID=$(cat /tmp/seerr-ux-rejected-id.txt)
CODE=$("${CURL_TV[@]}" -o /tmp/seerr-ux-packreject.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API_TV/api/grab/sonarr/season/12/2" \
  -d "{\"release_id\":\"$REJECTED_ID\"}")
check "a hard-rejected release is refused" "$CODE" "409"
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-packreject.json'))
assert 'season pack' in d['error'], d
print('  PASS:', d['error'])
PY
GRABS_AFTER=$(curl -s "http://127.0.0.1:$SONARR_PORT/__grabs" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
check "the refused grab sent nothing to Sonarr" "$GRABS_AFTER" "1"

echo "== test: selecting the whole request covers every requested season"
"${CURL_TV[@]}" -X POST -H "Content-Type: application/json" "$API_TV/api/seerr/requests/45/select" \
  -d '{"grab":false}' > /tmp/seerr-ux-series.json
python3 - <<'PY' || FAIL=1
import json
d = json.load(open('/tmp/seerr-ux-series.json'))
assert d['kind'] == 'series', d.get('kind')
summary = d['series']['summary']
assert summary['seasons'] == 1 and summary['selected'] == 1, summary
assert summary['grabbed'] == 0, summary
print('  PASS: whole-request selection summary', json.dumps(summary))
PY

echo
if [ $FAIL -eq 0 ]; then echo "ALL SEERR UX E2E CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $FAIL
