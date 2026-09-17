#!/bin/bash
# End-to-end smoke test for every path a grab can take.
#
#   bash test/smoke/grab_paths_e2e.sh
#
# Runs the real Pickarr binary against a scriptable fake Sonarr/Radarr
# (fake_grab_arr.py) once per scenario and asserts on what the fake received.
# Ports 19500-19520 belong to this test.  See docs/GRAB_BUG_NOTES.md.
set -u

WT="$(cd "$(dirname "$0")/../.." && pwd)"
PK_PORT=19500
ARR_PORT=19501
DATA=/tmp/grabpaths-data
COOKIE=/tmp/grabpaths-cookie
BASE=http://127.0.0.1:$PK_PORT
FAIL=0
PIDS=""

cd "$WT" || exit 1

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

check_contains() { # check_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) echo "  PASS $1" ;;
    *)
      echo "  FAIL $1: [$3] does not contain [$2]"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

field() { # field <file> <key>
  python3 -c "
import json,sys
try: r=json.load(open('$1'))
except Exception: print('PARSE_ERROR'); sys.exit()
v=r.get('$2')
print(v if isinstance(v,str) else json.dumps(v))"
}

notes() { python3 -c "
import json
r=json.load(open('/tmp/grabpaths-resp.json'))
print(' | '.join(r.get('grab_notes') or []))"; }

grabs() { wc -l < "/tmp/grabpaths-$ARR_PORT.grabs.jsonl" 2>/dev/null | tr -d ' '; }
searches() { cat "/tmp/grabpaths-$ARR_PORT.searches" 2>/dev/null || echo 0; }
last_grab() { tail -1 "/tmp/grabpaths-$ARR_PORT.grabs.jsonl" 2>/dev/null; }
first_grab() { head -1 "/tmp/grabpaths-$ARR_PORT.grabs.jsonl" 2>/dev/null; }

EP=$(python3 -c "import json;print(json.load(open('test/arr/fixtures/sonarr_episode.json'))['id'])")
MV=$(python3 -c "import json;print(json.load(open('test/arr/fixtures/radarr_movie.json'))['id'])")

# start_case <app> <scenario> [extra fake args...]
start_case() {
  local app="$1" scenario="$2"
  shift 2
  cleanup
  PIDS=""
  rm -rf "$DATA"; mkdir -p "$DATA"; rm -f "$COOKIE"
  python3 "$WT/test/smoke/fake_grab_arr.py" "$app" $ARR_PORT --scenario "$scenario" "$@" &
  PIDS="$!"
  DATA_DIR=$DATA PORT=$PK_PORT HOST=127.0.0.1 PICKARR_USERNAME=admin \
    PICKARR_PASSWORD=secret123 ./_build/default/bin/main.exe > /tmp/grabpaths-server.log 2>&1 &
  PIDS="$PIDS $!"
  for _ in $(seq 1 40); do
    sleep 0.25
    curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break
  done
  curl -s -o /dev/null -c $COOKIE -H 'Content-Type: application/json' -H "Origin: $BASE" \
    -d '{"username":"admin","password":"secret123"}' "$BASE/login"
  curl -s -o /dev/null -b $COOKIE -X PUT -H 'Content-Type: application/json' "$BASE/api/config" \
    -d "{\"instances\":[{\"id\":\"$app\",\"name\":\"$app\",\"app\":\"$app\",\"url\":\"http://127.0.0.1:$ARR_PORT\",\"api_key\":\"k\",\"enabled\":true}],
         \"llm\":{\"enabled\":false},\"hard_rules\":{\"min_seeders\":0}}"
}

post() { # post <path> <body> [expected code]
  local path="$1" body="$2" want="${3:-200}" code
  code=$(curl -s -o /tmp/grabpaths-resp.json -w '%{http_code}' -b $COOKIE -X POST \
    -H 'Content-Type: application/json' "$BASE$path" -d "$body")
  check "http $want ($path)" "$want" "$code"
}

media_id_for() { [ "$1" = sonarr ] && echo "$EP" || echo "$MV"; }

# The id of the release Pickarr ranked first, as the UI would send it.
top_release() { python3 -c "
import json
r=json.load(open('/tmp/grabpaths-resp.json'))
c=r['candidates'][0]['release']
print(json.dumps({'release_id':c['id'],'guid':c['guid'],'indexer_id':c['indexer_id']}))"; }

echo "################ (a) direct grab, nothing else needed"
start_case sonarr ok --queue downloading
post "/api/select/sonarr/$EP" '{"grab":false}'
check "search ran once" 1 "$(searches)"
check "no grab yet" 0 "$(grabs)"
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "grabbed" true "$(field /tmp/grabpaths-resp.json grabbed)"
check "exactly one POST /release" 1 "$(grabs)"
# The whole point of the search cache: grabbing must not search again.
check "no second search" 1 "$(searches)"
check_contains "notes say it was direct" "grabbed directly" "$(notes)"
check_contains "queue confirmed" "qBittorrent" "$(notes)"
check_contains "grab body has the guid" '"guid"' "$(last_grab)"
check_contains "grab body has the episode id" "\"episodeId\":$EP" "$(last_grab)"

echo "################ (b) cache miss -> search again -> grab"
start_case sonarr cachemiss_then_ok
post "/api/select/sonarr/$EP" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "grabbed after the retry" true "$(field /tmp/grabpaths-resp.json grabbed)"
check "two POST /release (first 404, then ok)" 2 "$(grabs)"
check "searched again to refill the cache" 2 "$(searches)"
check_contains "notes explain the retry" "searched again" "$(notes)"

echo "################ (c) cache miss and the release is gone"
start_case sonarr cachemiss_drop
post "/api/select/sonarr/$EP" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "not grabbed" false "$(field /tmp/grabpaths-resp.json grabbed)"
check_contains "error kept from Sonarr" "cache" "$(field /tmp/grabpaths-resp.json grab_error)"
check_contains "notes say the release is gone" "no longer offers it" "$(notes)"
check "only one POST: no pointless retry" 1 "$(grabs)"

echo "################ (d) Sonarr cannot map the release -> shouldOverride retry"
start_case sonarr mapping_override
post "/api/select/sonarr/$EP" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "grabbed via the override" true "$(field /tmp/grabpaths-resp.json grabbed)"
check "two POST /release" 2 "$(grabs)"
check_contains "notes mention the override" "shouldOverride" "$(notes)"
OVERRIDE=$(last_grab)
check_contains "override flag" '"shouldOverride":true' "$OVERRIDE"
check_contains "override seriesId" '"seriesId":' "$OVERRIDE"
check_contains "override episodeIds" "\"episodeIds\":[$EP]" "$OVERRIDE"
check_contains "override quality" '"quality":{' "$OVERRIDE"
check_contains "override languages" '"languages":[' "$OVERRIDE"
check_contains "first attempt had no override" '"guid"' "$(first_grab)"

echo "################ (e) Radarr cannot map the movie -> shouldOverride retry"
start_case radarr mapping_override
post "/api/select/radarr/$MV" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/radarr/$MV" "$TARGET"
check "grabbed via the override" true "$(field /tmp/grabpaths-resp.json grabbed)"
OVERRIDE=$(last_grab)
check_contains "override flag" '"shouldOverride":true' "$OVERRIDE"
check_contains "override movieId" "\"movieId\":$MV" "$OVERRIDE"
check_contains "override quality" '"quality":{' "$OVERRIDE"
check_contains "override languages" '"languages":[' "$OVERRIDE"
check_contains "no episodeIds for radarr" "" "$OVERRIDE"
case "$OVERRIDE" in
  *episodeIds*)
    echo "  FAIL radarr override must not send episodeIds"
    FAIL=$((FAIL + 1))
    ;;
  *) echo "  PASS radarr override sends no episodeIds" ;;
esac

echo "################ (f) a release with indexerId 0 is refused before any POST"
start_case sonarr ok --indexer-zero
post "/api/select/sonarr/$EP" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "not grabbed" false "$(field /tmp/grabpaths-resp.json grabbed)"
check_contains "explains why" "indexerId" "$(field /tmp/grabpaths-resp.json grab_error)"
check "nothing was sent to Sonarr" 0 "$(grabs)"
check_contains "notes say it was not sent" "not sent" "$(notes)"

echo "################ (g) the queue reports a problem after a successful grab"
start_case radarr ok --queue warning
post "/api/select/radarr/$MV" '{"grab":true}'
check "grabbed" true "$(field /tmp/grabpaths-resp.json grabbed)"
check_contains "queue warning surfaced" "queue warning" "$(notes)"
check_contains "download client reason kept" "qBittorrent rejected" "$(notes)"

echo "################ (h) a 409 from the indexer is not retried"
start_case radarr permanent
post "/api/select/radarr/$MV" '{"grab":true}'
check "not grabbed" false "$(field /tmp/grabpaths-resp.json grabbed)"
check_contains "message kept" "Unable to add release" "$(field /tmp/grabpaths-resp.json grab_error)"
check "exactly one POST" 1 "$(grabs)"

echo "################ (i) a hard-rejected release can still not be grabbed"
start_case sonarr ok
post "/api/select/sonarr/$EP" '{"grab":false}'
REJECTED=$(python3 -c "
import json
r=json.load(open('/tmp/grabpaths-resp.json'))
rej=r.get('rejected') or []
print(json.dumps({'release_id':rej[0]['release']['id']}) if rej else '')")
if [ -n "$REJECTED" ]; then
  post "/api/grab/sonarr/$EP" "$REJECTED" 409
  check "nothing sent to Sonarr" 0 "$(grabs)"
else
  echo "  SKIP no rejected release in the fixture"
fi

echo "################ (k) a flaky indexer drops the release from the next search"
# The regression this work started from: Sonarr/Radarr still hold the release
# in their 30-minute cache and would grab it, but a second search no longer
# lists it.  Pickarr must grab what the user saw instead of re-searching.
start_case sonarr search_drops
post "/api/select/sonarr/$EP" '{"grab":false}'
TARGET=$(top_release)
post "/api/grab/sonarr/$EP" "$TARGET"
check "grabbed despite the flaky indexer" true "$(field /tmp/grabpaths-resp.json grabbed)"
check "one POST /release" 1 "$(grabs)"
check "no second search happened at all" 1 "$(searches)"

echo "################ (j) grabbing an id nobody offers is a clean 404"
start_case sonarr ok
post "/api/select/sonarr/$EP" '{"grab":false}'
post "/api/grab/sonarr/$EP" '{"release_id":"nope-does-not-exist"}' 404
check_contains "error tells the user what to do" "search again" "$(field /tmp/grabpaths-resp.json error)"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "ALL GRAB PATH CHECKS PASSED"
else
  echo "$FAIL GRAB PATH CHECK(S) FAILED"
fi
exit $FAIL
