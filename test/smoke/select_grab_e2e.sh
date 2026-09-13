#!/bin/bash
# End-to-end smoke test for the Pickarr select/grab flow.
#
#   bash /tmp/grabbug-e2e.sh [grab-mode]
#
# Starts the real Pickarr binary plus a fake Sonarr and a fake Radarr, logs in
# with a session cookie, configures both instances and exercises every select
# route with and without grabbing.  Ports 19100-19199 belong to this worker.
set -u

WT="$(cd "$(dirname "$0")/../.." && pwd)"
PK_PORT=19100
SONARR_PORT=19101
RADARR_PORT=19102
LLM_PORT=19103
GRAB_MODE="${1:-echo}"
DATA=/tmp/grabbug-data
COOKIE=/tmp/grabbug-cookie
BASE=http://127.0.0.1:$PK_PORT
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

# notfound/conflict make the fake reject every grab, so "did it grab?" flips.
# In those modes a grab must instead report grabbed:false with a reason, and
# must never produce a 500.
case "$GRAB_MODE" in
  notfound | conflict) GRAB_SUCCEEDS=false ;;
  *) GRAB_SUCCEEDS=true ;;
esac

check_grabbed() { # check_grabbed <label>
  local grabbed error
  grabbed=$(field /tmp/grabbug-resp.json grabbed)
  error=$(field /tmp/grabbug-resp.json grab_error)
  if [ "$GRAB_SUCCEEDS" = true ]; then
    check "$1 grabbed" true "$grabbed"
  else
    check "$1 not grabbed" false "$grabbed"
    if [ "$error" = "null" ] || [ -z "$error" ]; then
      echo "  FAIL $1: a failed grab must report grab_error"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS $1 reports grab_error: $error"
    fi
  fi
}

rm -rf "$DATA"; mkdir -p "$DATA"; rm -f "$COOKIE"

python3 "$WT/test/smoke/fake_arr.py" sonarr $SONARR_PORT --grab-mode "$GRAB_MODE" & PIDS="$!"
python3 "$WT/test/smoke/fake_arr.py" radarr $RADARR_PORT --grab-mode "$GRAB_MODE" & PIDS="$PIDS $!"
DATA_DIR=$DATA PORT=$PK_PORT HOST=127.0.0.1 PICKARR_USERNAME=admin \
  PICKARR_PASSWORD=secret123 ./_build/default/bin/main.exe > /tmp/grabbug-server.log 2>&1 & PIDS="$PIDS $!"

for _ in $(seq 1 40); do
  sleep 0.25
  curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break
done

echo "== login"
code=$(curl -s -o /dev/null -w '%{http_code}' -c $COOKIE -H 'Content-Type: application/json' \
  -H "Origin: $BASE" -d '{"username":"admin","password":"secret123"}' "$BASE/login")
check "login 200" 200 "$code"

echo "== configure instances"
code=$(curl -s -o /tmp/grabbug-cfg.json -w '%{http_code}' -b $COOKIE -X PUT \
  -H 'Content-Type: application/json' "$BASE/api/config" -d "{
    \"instances\":[
      {\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"http://127.0.0.1:$SONARR_PORT\",\"api_key\":\"k\",\"enabled\":true},
      {\"id\":\"radarr\",\"name\":\"Radarr\",\"app\":\"radarr\",\"url\":\"http://127.0.0.1:$RADARR_PORT\",\"api_key\":\"k\",\"enabled\":true}
    ],
    \"llm\":{\"enabled\":false},
    \"hard_rules\":{\"min_seeders\":0}}")
check "config PUT 200" 200 "$code"

EP=$(python3 -c "import json;print(json.load(open('test/arr/fixtures/sonarr_episode.json'))['id'])")
MV=$(python3 -c "import json;print(json.load(open('test/arr/fixtures/radarr_movie.json'))['id'])")

show() { # show <file>
  python3 - "$1" <<'PY'
import json,sys
try:
    r=json.load(open(sys.argv[1]))
except Exception as e:
    print("    (unparseable response:", e, ")"); sys.exit()
if "error" in r and "candidates" not in r:
    print("    error:", r["error"]); sys.exit()
sel=r.get("selected")
print("    selected:", sel and sel["release"]["title"][:52])
print("    method:", r.get("method"), "grabbed:", r.get("grabbed"), "grab_error:", r.get("grab_error"))
print("    candidates:", len(r.get("candidates") or []), "rejected:", len(r.get("rejected") or []))
PY
}

field() { python3 -c "
import json,sys
try: r=json.load(open('$1'))
except Exception: print('PARSE_ERROR'); sys.exit()
print(json.dumps(r.get('$2')))"; }

post() { # post <label> <path> <body> [expected_code]
  local label="$1" path="$2" body="$3" want="${4:-200}"
  local out=/tmp/grabbug-resp.json
  local code
  if [ -n "$body" ]; then
    code=$(curl -s -o $out -w '%{http_code}' -b $COOKIE -X POST -H 'Content-Type: application/json' \
      "$BASE$path" -d "$body")
  else
    code=$(curl -s -o $out -w '%{http_code}' -b $COOKIE -X POST "$BASE$path")
  fi
  echo "-- $label  ($path)"
  check "http $want" "$want" "$code"
  show $out
  cp $out /tmp/grabbug-last-$label.json 2>/dev/null
}

grabs_for() { wc -l < "/tmp/grabbug-$1.grabs.jsonl" 2>/dev/null | tr -d ' '; }
last_grab() { tail -1 "/tmp/grabbug-$1.grabs.jsonl" 2>/dev/null; }

echo "== preview (no grab)"
post preview-sonarr "/api/select/sonarr/episode/$EP" '{"grab":false}'
check "not grabbed" false "$(field /tmp/grabbug-resp.json grabbed)"
check "no POST /release yet" 0 "$(grabs_for $SONARR_PORT)"

echo "== select & grab, app route (sonarr)"
post grab-sonarr "/api/select/sonarr/episode/$EP" '{"grab":true}'
check_grabbed "app route sonarr"
check "one POST /release" 1 "$(grabs_for $SONARR_PORT)"  # the call is made either way
echo "    grab body: $(last_grab $SONARR_PORT)"
python3 - "$(last_grab $SONARR_PORT)" "$EP" <<'PY'
import json,sys
try: b=json.loads(sys.argv[1])
except Exception: print("  FAIL grab body is not JSON"); sys.exit(1)
ok = isinstance(b.get("guid"),str) and b["guid"] and isinstance(b.get("indexerId"),int) and b.get("episodeId")==int(sys.argv[2])
print(("  PASS" if ok else "  FAIL")+" grab body has guid/indexerId/episodeId")
PY

echo "== select & grab, app route (radarr)"
post grab-radarr "/api/select/radarr/movie/$MV" '{"grab":true}'
check_grabbed "app route radarr"
echo "    grab body: $(last_grab $RADARR_PORT)"
python3 - "$(last_grab $RADARR_PORT)" "$MV" <<'PY'
import json,sys
try: b=json.loads(sys.argv[1])
except Exception: print("  FAIL grab body is not JSON"); sys.exit(1)
ok = isinstance(b.get("guid"),str) and b["guid"] and isinstance(b.get("indexerId"),int) and b.get("movieId")==int(sys.argv[2])
print(("  PASS" if ok else "  FAIL")+" grab body has guid/indexerId/movieId")
PY

echo "== select & grab, instance route (the one the UI uses)"
post grab-instance "/api/select/sonarr/$EP" '{"grab":true}'
check_grabbed "instance route"

echo "== grab via ?grab=true query form, empty body"
post grab-query "/api/select/sonarr/$EP?grab=true" ''
check_grabbed "?grab=true"

echo "== use_ai true with the LLM unreachable (must fall back and still grab)"
curl -s -o /dev/null -b $COOKIE -X PUT -H 'Content-Type: application/json' "$BASE/api/config" \
  -d "{\"llm\":{\"enabled\":true,\"base_url\":\"http://127.0.0.1:$LLM_PORT/v1\",\"api_key\":\"x\",\"model\":\"m\"}}"
post grab-llm-down "/api/select/sonarr/$EP" '{"grab":true,"use_ai":true}'
check_grabbed "with the LLM down"
python3 - <<'PY'
import json
r=json.load(open('/tmp/grabbug-resp.json'))
m=r.get('method') or {}
print(("  PASS" if m.get("kind")=="deterministic_fallback" else "  FAIL")+" method is deterministic_fallback ("+str(m)+")")
PY
curl -s -o /dev/null -b $COOKIE -X PUT -H 'Content-Type: application/json' "$BASE/api/config" \
  -d '{"llm":{"enabled":false}}'

echo "== bad input"
post bad-instance "/api/select/nope/5" '{"grab":true}' 404
post bad-media-id "/api/select/sonarr/abc" '{"grab":true}' 400
post bad-grab-type "/api/select/sonarr/$EP" '{"grab":"maybe"}' 400

echo "== per-candidate grab endpoint"
RID=$(python3 -c "
import json;r=json.load(open('/tmp/grabbug-last-preview-sonarr.json'));print(r['candidates'][0]['release']['id'])" 2>/dev/null)
if [ -n "${RID:-}" ]; then
  post grab-by-id "/api/grab/sonarr/$EP" "{\"release_id\":$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$RID")}"
  check_grabbed "grab by release id"
  post grab-by-id-unknown "/api/grab/sonarr/$EP" '{"release_id":"does-not-exist"}' 404
else
  echo "  SKIP (no candidate id available)"
fi

echo
echo "== server log (warnings/errors only)"
grep -aE "WARN|ERROR" /tmp/grabbug-server.log | grep -v dream.logger | tail -12

echo
if [ "$FAIL" -eq 0 ]; then echo "E2E RESULT: all checks passed (grab-mode=$GRAB_MODE)"; else echo "E2E RESULT: $FAIL check(s) FAILED (grab-mode=$GRAB_MODE)"; fi
exit $FAIL
