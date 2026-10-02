#!/bin/bash
# End-to-end smoke test for the queue integration: the action endpoints run
# as queue jobs but answer exactly as before, identical concurrent requests
# share one job, webhooks queue their work, and the work emits events.
#
#   bash test/smoke/queue_integration_e2e.sh
#
# Ports 19650-19699. Starts the real binary, a fake Sonarr (fake_arr.py) and
# a slow fake Radarr (fake_slow_radarr.py, 2 s per release search).
#
# Events are read from GET /api/events when that route exists; with the
# stub Events module of the queue-integration branch they are read from the
# file named by PICKARR_STUB_EVENTS_LOG instead.
set -u

WT="$(cd "$(dirname "$0")/../.." && pwd)"
PK_PORT=19660
SONARR_PORT=19661
RADARR_PORT=19662
TMP=/tmp/qi-e2e
DATA=$TMP/data
COOKIE=$TMP/cookie
EVENTS_FILE=$TMP/events.jsonl
BASE=http://127.0.0.1:$PK_PORT
FAIL=0
PIDS=""

cd "$WT" || exit 1
rm -rf "$TMP"; mkdir -p "$DATA"
rm -f /tmp/grabbug-$SONARR_PORT.grabs.jsonl /tmp/grabbug-$SONARR_PORT.requests.log

cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null; done
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

field() { # field <file> <python expression on r>
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERROR"); sys.exit()
try:
    print(json.dumps(eval(sys.argv[2])))
except Exception as e:
    print("EXPR_ERROR", e)
PY
}

python3 test/smoke/fake_arr.py sonarr $SONARR_PORT & PIDS="$PIDS $!"
python3 test/smoke/fake_slow_radarr.py $RADARR_PORT 2 > $TMP/radarr.log 2>&1 & PIDS="$PIDS $!"
PICKARR_STUB_EVENTS_LOG=$EVENTS_FILE DATA_DIR=$DATA PORT=$PK_PORT HOST=127.0.0.1 \
  PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  ./_build/default/bin/main.exe > $TMP/server.log 2>&1 & PIDS="$PIDS $!"

for _ in $(seq 1 40); do
  sleep 0.25
  curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break
done

echo "== login and configuration"
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -c $COOKIE -H 'Content-Type: application/json' \
  -H "Origin: $BASE" -d '{"username":"admin","password":"secret123"}' "$BASE/login")
check "login 200" 200 "$code"
CURL=(curl -s -m 60 -b $COOKIE)

code=$("${CURL[@]}" -o $TMP/cfg.json -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
  "$BASE/api/config" -d "{
    \"instances\":[
      {\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"http://127.0.0.1:$SONARR_PORT\",\"api_key\":\"sonarr-secret-key\",\"enabled\":true},
      {\"id\":\"radarr\",\"name\":\"Radarr\",\"app\":\"radarr\",\"url\":\"http://127.0.0.1:$RADARR_PORT\",\"api_key\":\"radarr-secret-key\",\"enabled\":true}
    ],
    \"llm\":{\"enabled\":false},
    \"hard_rules\":{\"min_seeders\":0}}")
check "config PUT 200" 200 "$code"
code=$("${CURL[@]}" -o $TMP/test.json -w '%{http_code}' -X POST "$BASE/api/instances/sonarr/test")
check "instance test 200" 200 "$code"

EP=$(python3 -c "import json;print(json.load(open('test/arr/fixtures/sonarr_episode.json'))['id'])")

echo "== a search answers exactly as before (no grab)"
code=$("${CURL[@]}" -o $TMP/search.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -H 'X-Pickarr-Source: ui' "$BASE/api/select/sonarr/episode/$EP" -d '{"grab":false}')
check "search 200" 200 "$code"
check "search has candidates" true "$(field $TMP/search.json 'len(r["candidates"]) > 0')"
check "search did not grab" false "$(field $TMP/search.json 'r["grabbed"]')"
check "no POST /release" 0 "$(cat /tmp/grabbug-$SONARR_PORT.grabs.jsonl 2>/dev/null | wc -l | tr -d ' ')"

echo "== grab_release grabs the release the search showed"
RID=$(field $TMP/search.json 'r["selected"]["release"]["id"]' | tr -d '"')
code=$("${CURL[@]}" -o $TMP/grab.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/grab/sonarr/$EP" -d "{\"release_id\":\"$RID\"}")
check "grab_release 200" 200 "$code"
check "grab_release grabbed" true "$(field $TMP/grab.json 'r["grabbed"]')"
check "one POST /release" 1 "$(cat /tmp/grabbug-$SONARR_PORT.grabs.jsonl 2>/dev/null | wc -l | tr -d ' ')"

echo "== error statuses survive the queue"
code=$("${CURL[@]}" -o $TMP/e1.json -w '%{http_code}' -X POST "$BASE/api/select/nope/1")
check "unknown instance 404" 404 "$code"
check "unknown instance message" '"no instance \"nope\" is configured"' "$(field $TMP/e1.json 'r["error"]')"
code=$("${CURL[@]}" -o $TMP/e2.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/select/sonarr/episode/$EP" -d '{"grab":"maybe"}')
check "bad body 400" 400 "$code"
code=$("${CURL[@]}" -o $TMP/e3.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/grab/sonarr/$EP" -d '{"release_id":"does-not-exist"}')
check "unknown release 404" 404 "$code"
check "unknown release message has no status prefix" false \
  "$(field $TMP/e3.json 'r["error"].startswith("[")')"
code=$("${CURL[@]}" -o $TMP/e4.json -w '%{http_code}' -X POST "$BASE/api/grab/sonarr/season/12/x" \
  -H 'Content-Type: application/json' -d '{"release_id":"a"}')
check "bad season 400" 400 "$code"

echo "== identical concurrent searches share one job (slow Radarr, 2 s per search)"
before=$(curl -s -m 5 "http://127.0.0.1:$RADARR_PORT/__state" | python3 -c 'import json,sys;print(json.load(sys.stdin)["searches"])')
"${CURL[@]}" -o $TMP/c1.json -w '%{http_code}\n' -X POST "$BASE/api/select/radarr/movie/440" > $TMP/c1.code &
P1=$!
sleep 0.3
"${CURL[@]}" -o $TMP/c2.json -w '%{http_code}\n' -X POST "$BASE/api/select/radarr/movie/440" > $TMP/c2.code &
P2=$!
wait $P1 $P2
after=$(curl -s -m 5 "http://127.0.0.1:$RADARR_PORT/__state" | python3 -c 'import json,sys;print(json.load(sys.stdin)["searches"])')
check "first 200" 200 "$(cat $TMP/c1.code)"
check "second 200" 200 "$(cat $TMP/c2.code)"
check "one release search for both" 1 "$((after - before))"
check "same answer" "$(field $TMP/c1.json 'r["selected"]["release"]["id"]')" \
  "$(field $TMP/c2.json 'r["selected"]["release"]["id"]')"
check "media carries the open-in link" '"http://127.0.0.1:'$RADARR_PORT'/movie/come-and-see-1985"' \
  "$(field $TMP/c1.json 'r["media"]["links"]["arr"]')"

echo "== grab_best through the app route"
code=$("${CURL[@]}" -o $TMP/best.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/select/radarr/movie/440" -d '{"grab":true}')
check "grab_best 200" 200 "$code"
check "grab_best grabbed" true "$(field $TMP/best.json 'r["grabbed"]')"

echo "== the passes still answer their summaries"
code=$("${CURL[@]}" -o $TMP/auto.json -w '%{http_code}' -X POST "$BASE/api/automatic/run")
check "automatic run 200" 200 "$code"
check "automatic summary" true "$(field $TMP/auto.json '"results" in r and "dry_run" in r')"
code=$("${CURL[@]}" -o $TMP/seerr.json -w '%{http_code}' -X POST "$BASE/api/seerr/run")
check "seerr run 200" 200 "$code"
check "seerr summary" true "$(field $TMP/seerr.json '"results" in r')"

echo "== webhooks queue their selections"
before=$(curl -s -m 5 "http://127.0.0.1:$RADARR_PORT/__state" | python3 -c 'import json,sys;print(json.load(sys.stdin)["searches"])')
sed 's/"id": 77/"id": 440/' test/arr/fixtures/radarr_webhook_movieadded.json > $TMP/hook.json
code=$("${CURL[@]}" -o $TMP/hook-resp.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  "$BASE/api/webhook/radarr" --data @$TMP/hook.json)
check "webhook 200" 200 "$code"
check "webhook action select" '"select"' "$(field $TMP/hook-resp.json 'r["action"]')"
check "webhook queued one job" 1 "$(field $TMP/hook-resp.json 'len([j for j in r["job_ids"] if j])')"
for _ in $(seq 1 40); do
  sleep 0.25
  now=$(curl -s -m 5 "http://127.0.0.1:$RADARR_PORT/__state" | python3 -c 'import json,sys;print(json.load(sys.stdin)["searches"])')
  [ "$((now - before))" -ge 1 ] && break
done
check "webhook job searched" 1 "$((now - before))"
sleep 0.5

echo "== events"
code=$("${CURL[@]}" -o $TMP/events.json -w '%{http_code}' "$BASE/api/events?limit=1000")
if [ "$code" = 200 ]; then
  python3 -c "import json;[print(json.dumps(e)) for e in json.load(open('$TMP/events.json'))['events']]" > $TMP/all-events.jsonl
else
  cp "$EVENTS_FILE" $TMP/all-events.jsonl 2>/dev/null || : > $TMP/all-events.jsonl
fi
has_event() { # has_event <type> [python condition on e]
  python3 - "$TMP/all-events.jsonl" "$1" "${2:-True}" <<'PY'
import json, sys
path, typ, cond = sys.argv[1], sys.argv[2], sys.argv[3]
events = [json.loads(l) for l in open(path) if l.strip()]
print("true" if any(e["type"] == typ and eval(cond) for e in events) else "false")
PY
}
for t in auth.login config.updated instance.tested search.started search.done grab.sent \
         grab.accepted automatic.pass seerr.pass webhook.received; do
  check "event $t" true "$(has_event $t)"
done
check "search.done tagged with a job" true "$(has_event search.done 'e["job_id"] is not None')"
check "grab.accepted tagged with a job" true "$(has_event grab.accepted 'e["job_id"] is not None')"
check "search.done counts candidates" true "$(has_event search.done '"candidates" in e["data"]')"
check "config.updated lists sections" true \
  "$(has_event config.updated '"instances" in e["data"]["sections"]')"
check "no secret in any event" false \
  "$(grep -c 'secret-key' $TMP/all-events.jsonl | grep -qv '^0$' && echo true || echo false)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL QUEUE INTEGRATION CHECKS PASSED"
else
  echo "$FAIL QUEUE INTEGRATION CHECK(S) FAILED"
  grep -E "WARN|ERROR" $TMP/server.log | tail -20
fi
exit $FAIL
