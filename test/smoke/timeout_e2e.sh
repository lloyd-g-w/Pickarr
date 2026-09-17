#!/bin/bash
# End-to-end smoke test for the release-search timeout.
#
# Reproduces the reported failure
#   "HTTP 502 - Radarr: release search failed for Come and See (1985):
#    connection error: timed out after 30s (.../api/v3/release?movieId=440)"
# and proves the two-timeout fix: a slow interactive search must survive the
# read timeout and only fail once network.arr_search_timeout_seconds is
# exceeded, with a message that says which setting to raise.
#
# Ports 19460-19461 on loopback. Only the processes it starts are killed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PICKARR_PORT=19460
RADARR_PORT=19461
DATA=/tmp/pickarr-timeout-e2e-data
COOKIE=/tmp/pickarr-timeout-e2e-cookie
FAIL=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
check_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1 (expected to contain '$3', got '$2')" ;;
  esac
}

rm -rf "$DATA" "$COOKIE"
mkdir -p "$DATA"

# Start with a 2s search: slower than nothing, faster than every timeout used.
python3 "$HERE/fake_slow_radarr.py" "$RADARR_PORT" 2 & RADARR_PID=$!
DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > /tmp/pickarr-timeout-e2e.log 2>&1 & PICKARR_PID=$!

cleanup() { kill $RADARR_PID $PICKARR_PID 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

sleep 3
API="http://127.0.0.1:$PICKARR_PORT"
curl -s -c "$COOKIE" -H "Content-Type: application/json" -H "Origin: $API" \
  -d '{"username":"admin","password":"secret123"}' "$API/login" -o /dev/null
CURL=(curl -s -b "$COOKIE")

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

configure() { # $1 = read timeout, $2 = search timeout
  "${CURL[@]}" -X PUT -H "Content-Type: application/json" "$API/api/config" -d "$(cat <<JSON
{
  "instances": [
    {"id":"radarr","name":"Radarr","app":"radarr","url":"http://127.0.0.1:$RADARR_PORT","api_key":"k","enabled":true}
  ],
  "llm": {"enabled": false},
  "network": {"arr_timeout_seconds": $1, "arr_search_timeout_seconds": $2}
}
JSON
)" -o /tmp/pickarr-timeout-cfg.json -w "%{http_code}"
}

echo "== configuration"
CODE=$(configure 5 10)
check "config PUT" "$CODE" "200"
check "read timeout stored" "$(jqp 'd["network"]["arr_timeout_seconds"]' < /tmp/pickarr-timeout-cfg.json)" "5"
check "search timeout stored" "$(jqp 'd["network"]["arr_search_timeout_seconds"]' < /tmp/pickarr-timeout-cfg.json)" "10"

# A value below the clamp must come back clamped, not stored as given.
configure 1 900 > /dev/null
CFG=$("${CURL[@]}" "$API/api/config")
check "too-small read timeout clamped to 5" "$(echo "$CFG" | jqp 'd["network"]["arr_timeout_seconds"]')" "5"
check "large search timeout kept" "$(echo "$CFG" | jqp 'd["network"]["arr_search_timeout_seconds"]')" "900"

echo "== a quick call is unaffected by the short read timeout"
TEST=$("${CURL[@]}" -X POST "$API/api/instances/radarr/test")
check "instance test ok" "$(echo "$TEST" | jqp 'd["ok"]')" "True"
check_contains "instance test names the app" "$TEST" "Radarr"

echo "== a 2s search succeeds under a 10s search timeout"
configure 5 10 > /dev/null
START=$(date +%s)
SEL=$("${CURL[@]}" -o /tmp/pickarr-timeout-sel.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/select/radarr/440" -d '{}')
ELAPSED=$(( $(date +%s) - START ))
check "select HTTP 200" "$SEL" "200"
check "one candidate" "$(jqp 'len(d["candidates"])' < /tmp/pickarr-timeout-sel.json)" "1"
check "selected the release" \
  "$(jqp 'd["selected"]["release"]["title"]' < /tmp/pickarr-timeout-sel.json)" \
  "Come.and.See.1985.1080p.BluRay.x264-GROUP"
if [ "$ELAPSED" -ge 2 ]; then
  pass "the search really waited ${ELAPSED}s, i.e. longer than a fast read"
else
  fail "expected the search to take at least 2s, took ${ELAPSED}s"
fi

echo "== the same search fails once it outlasts the search timeout"
# 8s of indexer wait against a 5s search timeout.
curl -s "http://127.0.0.1:$RADARR_PORT/__delay?seconds=8" -o /dev/null
configure 5 5 > /dev/null
START=$(date +%s)
CODE=$("${CURL[@]}" -o /tmp/pickarr-timeout-fail.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/select/radarr/440" -d '{}')
ELAPSED=$(( $(date +%s) - START ))
BODY=$(cat /tmp/pickarr-timeout-fail.json)
check "select HTTP 502" "$CODE" "502"
check_contains "error says it timed out" "$BODY" "timed out after 5s"
check_contains "error explains the wait" "$BODY" "waiting for the release search"
check_contains "error names the setting to raise" "$BODY" "network.arr_search_timeout_seconds"
check_contains "error keeps the failing url" "$BODY" "/api/v3/release?movieId=440"
if [ "$ELAPSED" -lt 8 ]; then
  pass "gave up after ${ELAPSED}s instead of waiting out the 8s search"
else
  fail "expected to give up before the 8s search finished, took ${ELAPSED}s"
fi

echo "== raising the search timeout fixes it without a restart"
configure 5 20 > /dev/null
CODE=$("${CURL[@]}" -o /tmp/pickarr-timeout-fixed.json -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" "$API/api/select/radarr/440" -d '{}')
check "select HTTP 200 after raising the timeout" "$CODE" "200"
check "one candidate again" "$(jqp 'len(d["candidates"])' < /tmp/pickarr-timeout-fixed.json)" "1"

STATE=$(curl -s "http://127.0.0.1:$RADARR_PORT/__state")
check "every attempt reached Radarr" "$(echo "$STATE" | jqp 'd["searches"]')" "3"
check "nothing was grabbed" "$(echo "$STATE" | jqp 'len(d["grabs"])')" "0"

echo
if [ "$FAIL" = "0" ]; then
  echo "ALL TIMEOUT E2E CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $FAIL
