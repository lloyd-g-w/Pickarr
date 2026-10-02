#!/bin/bash
# End-to-end smoke test of the queue the way the UI drives it: the real
# binary, a slow fake Radarr (fake_slow_radarr.py) and a fake Sonarr with
# seasons (fake_sonarr_seasons.py).  Every step makes the same requests
# static/app.js makes: POST /api/jobs {kind, params, source:"ui"} -> 202,
# then GET /api/jobs/:id until the job has finished.
#
#   bash test/smoke/queue_ui_e2e.sh
#
# Covers: movie search -> result shape renderSelectionResult expects; grab of
# the selected release (grab_release) reaching the fake; season and series
# searches; cancel of a queued job; a failed job (Radarr 500) with
# error/error_status and its retry; dedupe; HTTP statuses of rejected
# enqueues and of the synchronous endpoints; counts; events with job ids;
# a restart in the middle of the queue.  The finished jobs are saved as
# /tmp/queue-ui-e2e-*.json and drawn by the DOM shim at the end
# (QUEUE_UI_REAL_JOBS=... node test/smoke/fake_jobs_api.js).
#
# Ports 19800-19802.
set -u

WT="$(cd "$(dirname "$0")/../.." && pwd)"
PK_PORT=19800
RADARR_PORT=19801
SONARR_PORT=19802
TMP=/tmp/queue-ui-e2e
OUT=/tmp/queue-ui-e2e   # job captures: $OUT-<name>.json
DATA=$TMP/data
COOKIE=$TMP/cookie
BASE=http://127.0.0.1:$PK_PORT
RADARR=http://127.0.0.1:$RADARR_PORT
SONARR=http://127.0.0.1:$SONARR_PORT
SERIES_ID=12
FAIL=0
PIDS=""
PK_PID=""

cd "$WT" || exit 1
rm -rf "$TMP" "$OUT"-*.json
mkdir -p "$DATA"

cleanup() {
  for pid in $PIDS $PK_PID; do kill "$pid" 2>/dev/null; done
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

# field <file> <python expression on r>
field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERROR"); sys.exit()
try:
    v = eval(sys.argv[2])
    print(v if isinstance(v, str) else json.dumps(v))
except Exception as e:
    print("EXPR_ERROR", e)
PY
}

start_pickarr() {
  DATA_DIR=$DATA PORT=$PK_PORT HOST=127.0.0.1 PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
    ./_build/default/bin/main.exe >> $TMP/server.log 2>&1 &
  PK_PID=$!
  for _ in $(seq 1 40); do
    sleep 0.25
    curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && return 0
  done
  echo "  FAIL pickarr did not start"; FAIL=$((FAIL + 1))
}

login() {
  curl -s -m 10 -o /dev/null -w '%{http_code}' -c $COOKIE -H 'Content-Type: application/json' \
    -H "Origin: $BASE" -d '{"username":"admin","password":"secret123"}' "$BASE/login"
}

CURL=(curl -s -m 30 -b $COOKIE)

# enqueue <file> <json body> -> prints the HTTP status; body in <file>
enqueue() {
  "${CURL[@]}" -o "$1" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    "$BASE/api/jobs" -d "$2"
}

# wait_job <id> <file> [seconds] -> the finished job ({"job":...}) in <file>
wait_job() {
  local deadline=$((SECONDS + ${3:-60}))
  while [ $SECONDS -lt $deadline ]; do
    "${CURL[@]}" -o "$2" "$BASE/api/jobs/$1"
    case "$(field "$2" "r['job']['status']")" in
      succeeded|failed|cancelled) return 0 ;;
    esac
    sleep 0.3
  done
  echo "  FAIL job $1 did not finish within ${3:-60}s ($(field "$2" "r['job']['status']"))"
  FAIL=$((FAIL + 1))
}

# wait_status <id> <status> <file> [seconds]
wait_status() {
  local deadline=$((SECONDS + ${4:-30}))
  while [ $SECONDS -lt $deadline ]; do
    "${CURL[@]}" -o "$3" "$BASE/api/jobs/$1"
    [ "$(field "$3" "r['job']['status']")" = "$2" ] && return 0
    sleep 0.2
  done
  echo "  FAIL job $1 never became $2"; FAIL=$((FAIL + 1))
}

python3 test/smoke/fake_slow_radarr.py $RADARR_PORT 0.3 > $TMP/radarr.log 2>&1 & PIDS="$PIDS $!"
python3 test/smoke/fake_sonarr_seasons.py $SONARR_PORT > $TMP/sonarr.log 2>&1 & PIDS="$PIDS $!"
start_pickarr

echo "== login and configuration"
check "login 200" 200 "$(login)"
code=$("${CURL[@]}" -o $TMP/cfg.json -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
  "$BASE/api/config" -d "{
    \"instances\":[
      {\"id\":\"radarr\",\"name\":\"Radarr\",\"app\":\"radarr\",\"url\":\"$RADARR\",\"api_key\":\"k\",\"enabled\":true},
      {\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"$SONARR\",\"api_key\":\"k\",\"enabled\":true}],
    \"llm\":{\"enabled\":false},
    \"queue\":{\"workers\":2,\"per_instance\":1}}")
check "config PUT 200" 200 "$code"

echo "== movie search, as the Search button does"
code=$(enqueue $TMP/q1.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
check "POST /api/jobs 202" 202 "$code"
SEARCH_ID=$(field $TMP/q1.json "r['job']['id']")
check "new job is queued or running" true \
  "$(field $TMP/q1.json "r['job']['status'] in ('queued','running')")"
check "source ui" ui "$(field $TMP/q1.json "r['job']['source']")"
wait_job "$SEARCH_ID" $OUT-search-movie.json
J=$OUT-search-movie.json
check "search succeeded" succeeded "$(field $J "r['job']['status']")"
check "result has the renderSelectionResult keys" true \
  "$(field $J "all(k in r['job']['result'] for k in ('media','selected','candidates','rejected','explanation','method','grabbed'))")"
check "media carries links" true "$(field $J "'links' in r['job']['result']['media']")"
check "a release was selected" "Come.and.See.1985.1080p.BluRay.x264-GROUP" \
  "$(field $J "r['job']['result']['selected']['release']['title']")"
check "candidates are scored releases" true \
  "$(field $J "all('release' in c and 'score' in c for c in r['job']['result']['candidates'])")"
check "not grabbed by a search" false "$(field $J "r['job']['result']['grabbed']")"
check "error_status null on success" null "$(field $J "r['job']['error_status']")"
REL_ID=$(field $J "r['job']['result']['selected']['release']['id']")
REL_GUID=$(field $J "r['job']['result']['selected']['release']['guid']")
REL_INDEXER=$(field $J "r['job']['result']['selected']['release']['indexer_id']")

echo "== Grab selected -> grab_release with the selected release"
code=$(enqueue $TMP/q2.json "{\"kind\":\"grab_release\",\"params\":{\"instance_id\":\"radarr\",\"target\":{\"kind\":\"movie\",\"media_id\":440},\"release_id\":\"$REL_ID\",\"guid\":\"$REL_GUID\",\"indexer_id\":$REL_INDEXER,\"release_title\":\"Come.and.See.1985.1080p.BluRay.x264-GROUP\"},\"source\":\"ui\"}")
check "grab_release 202" 202 "$code"
GRAB_ID=$(field $TMP/q2.json "r['job']['id']")
check "label uses release_title" true \
  "$(field $TMP/q2.json "'Come.and.See' in r['job']['label']")"
wait_job "$GRAB_ID" $OUT-grab-release.json
J=$OUT-grab-release.json
check "grab succeeded" succeeded "$(field $J "r['job']['status']")"
check "grabbed:true" true "$(field $J "r['job']['result']['grabbed']")"
"${CURL[@]}" -o $TMP/radarr-state.json "$RADARR/__state"
check "the fake received exactly one grab" 1 "$(field $TMP/radarr-state.json "len(r['grabs'])")"
check "with the selected guid" "$REL_GUID" \
  "$(field $TMP/radarr-state.json "__import__('json').loads(r['grabs'][0])['guid']")"

echo "== season search"
code=$(enqueue $TMP/q3.json "{\"kind\":\"search\",\"params\":{\"instance_id\":\"sonarr\",\"target\":{\"kind\":\"season\",\"series_id\":$SERIES_ID,\"season_number\":2},\"use_ai\":false},\"source\":\"ui\"}")
check "season search 202" 202 "$code"
SEASON_ID=$(field $TMP/q3.json "r['job']['id']")
wait_job "$SEASON_ID" $OUT-search-season.json
J=$OUT-search-season.json
check "season search succeeded" succeeded "$(field $J "r['job']['status']")"
check "season result has candidates" true "$(field $J "'candidates' in r['job']['result']")"
check "media kind season" season "$(field $J "r['job']['result']['media']['media_kind']")"

echo "== series search"
code=$(enqueue $TMP/q4.json "{\"kind\":\"search\",\"params\":{\"instance_id\":\"sonarr\",\"target\":{\"kind\":\"series\",\"series_id\":$SERIES_ID},\"use_ai\":false},\"source\":\"ui\"}")
check "series search 202" 202 "$code"
SERIES_JOB=$(field $TMP/q4.json "r['job']['id']")
wait_job "$SERIES_JOB" $OUT-search-series.json
J=$OUT-search-series.json
check "series search succeeded" succeeded "$(field $J "r['job']['status']")"
check "series result has series and seasons" true \
  "$(field $J "'series' in r['job']['result'] and isinstance(r['job']['result']['seasons'], list)")"

echo "== rejected enqueues answer with their real status, without the [ddd] prefix"
code=$(enqueue $TMP/bad1.json '{"kind":"search","params":{"instance_id":"nope","target":{"kind":"movie","media_id":1}},"source":"ui"}')
check "unknown instance -> 404" 404 "$code"
check "message without prefix" true "$(field $TMP/bad1.json "not r['error'].startswith('[') and 'nope' in r['error']")"
code=$(enqueue $TMP/bad2.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":-1}},"source":"ui"}')
check "bad params -> 400" 400 "$code"
code=$(enqueue $TMP/bad3.json '{"kind":"frobnicate","params":{}}')
check "unknown kind -> 400" 400 "$code"

echo "== cancel a queued job (one worker, slow search)"
"${CURL[@]}" -o /dev/null -X PUT -H 'Content-Type: application/json' "$BASE/api/config" \
  -d '{"queue":{"workers":1,"per_instance":1}}'
"${CURL[@]}" -o /dev/null "$RADARR/__delay?seconds=3"
code=$(enqueue $TMP/c1.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
SLOW_ID=$(field $TMP/c1.json "r['job']['id']")
wait_status "$SLOW_ID" running $TMP/c1s.json
code=$(enqueue $TMP/c2.json "{\"kind\":\"search\",\"params\":{\"instance_id\":\"sonarr\",\"target\":{\"kind\":\"season\",\"series_id\":$SERIES_ID,\"season_number\":1},\"use_ai\":false},\"source\":\"ui\"}")
QUEUED_ID=$(field $TMP/c2.json "r['job']['id']")
check "second job waits (queued)" queued "$(field $TMP/c2.json "r['job']['status']")"
check "position 1" 1 "$(field $TMP/c2.json "r['job']['position']")"
code=$(enqueue $TMP/c3.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
check "duplicate enqueue -> 202" 202 "$code"
check "duplicate enqueue returns the same job" "$SLOW_ID" "$(field $TMP/c3.json "r['job']['id']")"
code=$("${CURL[@]}" -o $TMP/cancel.json -w '%{http_code}' -X POST "$BASE/api/jobs/$QUEUED_ID/cancel")
check "cancel 200" 200 "$code"
check "cancelled" cancelled "$(field $TMP/cancel.json "r['job']['status']")"
code=$("${CURL[@]}" -o $TMP/cancel2.json -w '%{http_code}' -X POST "$BASE/api/jobs/$QUEUED_ID/cancel")
check "cancelling again -> 409" 409 "$code"
cp $TMP/cancel.json $OUT-cancelled.json
wait_job "$SLOW_ID" $TMP/c1done.json
check "the slow search still finished" succeeded "$(field $TMP/c1done.json "r['job']['status']")"
"${CURL[@]}" -o $TMP/q2check.json "$BASE/api/jobs/$QUEUED_ID"
check "the cancelled job never ran" null "$(field $TMP/q2check.json "r['job']['started_at']")"

echo "== a failing search (Radarr 500) and its retry"
"${CURL[@]}" -o /dev/null "$RADARR/__delay?seconds=0"
"${CURL[@]}" -o /dev/null "$RADARR/__fail?status=500"
code=$(enqueue $TMP/f1.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
FAILED_ID=$(field $TMP/f1.json "r['job']['id']")
wait_job "$FAILED_ID" $OUT-failed.json
J=$OUT-failed.json
check "failed" failed "$(field $J "r['job']['status']")"
check "error_status 502" 502 "$(field $J "r['job']['error_status']")"
check "error has no [ddd] prefix" true \
  "$(field $J "not __import__('re').match(r'^\[\d{3}\] ', r['job']['error'])")"
check "error names the search" true "$(field $J "'release search failed' in r['job']['error']")"
code=$("${CURL[@]}" -o $TMP/sync.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/select/radarr/440" -d '{"use_ai":false}')
check "sync endpoint keeps answering 502" 502 "$code"
check "sync error without prefix" true "$(field $TMP/sync.json "not r['error'].startswith('[')")"
"${CURL[@]}" -o /dev/null "$RADARR/__fail?status=0"
code=$("${CURL[@]}" -o $TMP/retry.json -w '%{http_code}' -X POST "$BASE/api/jobs/$FAILED_ID/retry")
check "retry 202" 202 "$code"
RETRY_ID=$(field $TMP/retry.json "r['job']['id']")
check "retry_of" "$FAILED_ID" "$(field $TMP/retry.json "r['job']['retry_of']")"
check "attempt 2" 2 "$(field $TMP/retry.json "r['job']['attempt']")"
wait_job "$RETRY_ID" $TMP/retrydone.json
check "the retry succeeded" succeeded "$(field $TMP/retrydone.json "r['job']['status']")"
code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE/api/jobs/$RETRY_ID/retry")
check "retrying a succeeded job -> 409" 409 "$code"

echo "== list and counts"
"${CURL[@]}" -o $TMP/list.json "$BASE/api/jobs?limit=200"
check "counts present" true \
  "$(field $TMP/list.json "all(k in r['counts'] for k in ('queued','running','succeeded','failed','cancelled'))")"
check "succeeded count" true "$(field $TMP/list.json "r['counts']['succeeded'] >= 6")"
# the failed search, and the synchronous /api/select call (also a job)
check "failed count" 2 "$(field $TMP/list.json "r['counts']['failed']")"
check "cancelled count" 1 "$(field $TMP/list.json "r['counts']['cancelled']")"
check "newest first" true "$(field $TMP/list.json "[j['id'] for j in r['jobs']] == sorted([j['id'] for j in r['jobs']], reverse=True)")"
check "no result without include=result" true "$(field $TMP/list.json "all('result' not in j for j in r['jobs'])")"
"${CURL[@]}" -o $TMP/listf.json "$BASE/api/jobs?status=failed"
check "status filter" true \
  "$(field $TMP/listf.json "$FAILED_ID in [j['id'] for j in r['jobs']] and all(j['status']=='failed' for j in r['jobs']) and len(r['jobs'])==2")"

echo "== events"
"${CURL[@]}" -o $TMP/events.json "$BASE/api/events?since_id=0&limit=5000"
has_event() { # has_event <type> <job id>
  field $TMP/events.json "any(e['type']=='$1' and e.get('job_id')==$2 for e in r['events'])"
}
check "job.queued for the search" true "$(has_event job.queued "$SEARCH_ID")"
check "job.started for the search" true "$(has_event job.started "$SEARCH_ID")"
check "search.done for the search" true "$(has_event search.done "$SEARCH_ID")"
check "job.succeeded for the search" true "$(has_event job.succeeded "$SEARCH_ID")"
check "grab.accepted for the grab" true "$(has_event grab.accepted "$GRAB_ID")"
check "job.cancelled" true "$(has_event job.cancelled "$QUEUED_ID")"
check "job.failed with error_status" true \
  "$(field $TMP/events.json "any(e['type']=='job.failed' and e.get('job_id')==$FAILED_ID and e['data'].get('error_status')==502 and not e['message'].count('[502]') for e in r['events'])")"
LAST_EVENT=$(field $TMP/events.json "r['last_id']")
"${CURL[@]}" -o $TMP/events2.json "$BASE/api/events?since_id=$LAST_EVENT"
check "since_id returns only newer events" true \
  "$(field $TMP/events2.json "all(e['id'] > $LAST_EVENT for e in r['events'])")"

echo "== restart in the middle of the queue"
"${CURL[@]}" -o /dev/null "$RADARR/__delay?seconds=8"
code=$(enqueue $TMP/r1.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
RUNNING_ID=$(field $TMP/r1.json "r['job']['id']")
wait_status "$RUNNING_ID" running $TMP/r1s.json
code=$(enqueue $TMP/r2.json "{\"kind\":\"search\",\"params\":{\"instance_id\":\"sonarr\",\"target\":{\"kind\":\"season\",\"series_id\":$SERIES_ID,\"season_number\":2},\"use_ai\":false},\"source\":\"ui\"}")
WAITING_ID=$(field $TMP/r2.json "r['job']['id']")
check "second job queued behind the slow one" queued "$(field $TMP/r2.json "r['job']['status']")"
sleep 2   # jobs.json is written at most once a second
kill -9 "$PK_PID" 2>/dev/null; wait "$PK_PID" 2>/dev/null; PK_PID=""
"${CURL[@]}" -o /dev/null "$RADARR/__delay?seconds=0"
start_pickarr
check "login after restart" 200 "$(login)"
"${CURL[@]}" -o $TMP/after-running.json "$BASE/api/jobs/$RUNNING_ID"
check "running job marked failed" failed "$(field $TMP/after-running.json "r['job']['status']")"
check "interrupted by restart" "interrupted by restart" "$(field $TMP/after-running.json "r['job']['error']")"
wait_job "$WAITING_ID" $TMP/after-waiting.json
check "queued job resumed and ran" succeeded "$(field $TMP/after-waiting.json "r['job']['status']")"
"${CURL[@]}" -o $TMP/after-search.json "$BASE/api/jobs/$SEARCH_ID"
check "finished jobs keep their result across the restart" true \
  "$(field $TMP/after-search.json "'candidates' in r['job']['result']")"
"${CURL[@]}" -o $TMP/events3.json "$BASE/api/events?type=job.interrupted&limit=50"
check "job.interrupted event" true \
  "$(field $TMP/events3.json "any(e.get('job_id')==$RUNNING_ID for e in r['events'])")"
code=$(enqueue $TMP/r3.json '{"kind":"search","params":{"instance_id":"radarr","target":{"kind":"movie","media_id":440},"use_ai":false},"source":"ui"}')
check "ids continue after the restart" true "$(field $TMP/r3.json "r['job']['id'] > $WAITING_ID")"
wait_job "$(field $TMP/r3.json "r['job']['id']")" $TMP/r3done.json

echo "== the UI draws the real job JSON (DOM shim)"
REAL=$(ls $OUT-*.json | tr '\n' ',')
if QUEUE_UI_REAL_JOBS="$REAL" node test/smoke/fake_jobs_api.js > $TMP/shim.log 2>&1; then
  echo "  PASS real jobs rendered ($(grep -c '  PASS' $TMP/shim.log) checks)"
else
  echo "  FAIL real jobs rendered:"; grep -E 'FAIL' $TMP/shim.log | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

echo
if [ $FAIL -eq 0 ]; then echo "ALL QUEUE UI E2E CHECKS PASSED"; else echo "$FAIL QUEUE UI E2E CHECK(S) FAILED"; fi
exit $FAIL
