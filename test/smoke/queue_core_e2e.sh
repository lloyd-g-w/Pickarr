#!/bin/bash
# End-to-end smoke test for the job queue and the event log.
#
# Starts the real binary with PICKARR_TEST_JOBS=1, which registers the hidden
# "test_sleep" job kind ({ms, fail?, raise?, instance_id?, dedupe?}), then
# drives /api/jobs (enqueue, positions, counts, dedupe, cancel queued and
# running, retry, clear, validation errors), /api/events (since_id polling and
# filters), and finally restarts the binary on the same data dir to check the
# restart semantics (running -> failed "interrupted by restart", queued ->
# queued again and run, ids continue).
#
# Ports 19600-19601 on loopback. Only the processes it starts are killed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PICKARR_PORT=19600
DATA=/tmp/pickarr-queue-core-e2e-data
COOKIE=/tmp/pickarr-queue-core-e2e-cookie
LOG=/tmp/pickarr-queue-core-e2e.log
FAIL=0
PICKARR_PID=""

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

rm -rf "$DATA" "$COOKIE"
mkdir -p "$DATA"

start_pickarr() {
  DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
    PICKARR_TEST_JOBS=1 QUEUE_WORKERS=1 \
    "$REPO/_build/default/bin/main.exe" >> "$LOG" 2>&1 & PICKARR_PID=$!
  for _ in $(seq 1 50); do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$PICKARR_PORT/health" && break
    sleep 0.1
  done
  curl -s -m 5 -c "$COOKIE" -H "Content-Type: application/json" -H "Origin: $API" \
    -d '{"username":"admin","password":"secret123"}' "$API/login" -o /dev/null
}
stop_pickarr() {
  if [ -n "$PICKARR_PID" ]; then kill "$PICKARR_PID" 2>/dev/null; wait "$PICKARR_PID" 2>/dev/null; fi
  PICKARR_PID=""
}
cleanup() { stop_pickarr; }
trap cleanup EXIT

API="http://127.0.0.1:$PICKARR_PORT"
: > "$LOG"
start_pickarr
CURL=(curl -s -m 10 -b "$COOKIE")

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
enqueue() { # $1 = params JSON -> job id
  "${CURL[@]}" -X POST -H "Content-Type: application/json" "$API/api/jobs" \
    -d "{\"kind\":\"test_sleep\",\"source\":\"ui\",\"params\":$1}" | jqp 'd["job"]["id"]'
}
job_field() { "${CURL[@]}" "$API/api/jobs/$1" | jqp "d['job']['$2']"; }
wait_status() { # $1 id, $2 wanted status, $3 tries (0.1s each)
  for _ in $(seq 1 "${3:-100}"); do
    s=$(job_field "$1" status)
    [ "$s" = "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

echo "== enqueue and positions (QUEUE_WORKERS=1)"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  "$API/api/jobs" -d '{"kind":"test_sleep","params":{"ms":1500}}')
check "POST /api/jobs answers 202" "$code" "202"
LONG=$("${CURL[@]}" "$API/api/jobs?limit=1" | jqp 'd["jobs"][0]["id"]')
A=$(enqueue '{"ms":50}')
B=$(enqueue '{"ms":50}')
C=$(enqueue '{"ms":50}')
sleep 0.3
check "long job is running" "$(job_field "$LONG" status)" "running"
check "A is queued at position 1" "$(job_field "$A" position)" "1"
check "B at position 2" "$(job_field "$B" position)" "2"
check "C at position 3" "$(job_field "$C" position)" "3"
check "label from params" "$(job_field "$A" label)" "Test sleep · 50 ms"
check "source kept" "$(job_field "$A" source)" "ui"
COUNTS=$("${CURL[@]}" "$API/api/jobs?status=queued,running" | jqp 'str(d["counts"]["queued"])+"/"+str(d["counts"]["running"])+"/"+str(len(d["jobs"]))')
check "counts queued/running and filtered list" "$COUNTS" "3/1/4"
check "result omitted from list" "$("${CURL[@]}" "$API/api/jobs?limit=1" | jqp '"result" in d["jobs"][0]')" "False"
check "result included on request" "$("${CURL[@]}" "$API/api/jobs?limit=1&include=result" | jqp '"result" in d["jobs"][0]')" "True"

echo "== dedupe"
D1=$(enqueue '{"ms":50,"dedupe":"same"}')
D2=$(enqueue '{"ms":50,"dedupe":"same"}')
check "same dedupe key returns the queued job" "$D2" "$D1"

echo "== cancel a queued job"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "$API/api/jobs/$B/cancel")
check "cancel queued answers 200" "$code" "200"
check "B cancelled" "$(job_field "$B" status)" "cancelled"
check "C moved up to position 2" "$(job_field "$C" position)" "2"

echo "== run to completion"
wait_status "$C" succeeded 100 && pass "C succeeded" || fail "C did not succeed"
check "A succeeded" "$(job_field "$A" status)" "succeeded"
check "result of A" "$("${CURL[@]}" "$API/api/jobs/$A" | jqp 'd["job"]["result"]["slept_ms"]')" "50"
check "duration recorded" "$("${CURL[@]}" "$API/api/jobs/$A" | jqp 'd["job"]["duration_ms"] >= 40')" "True"
check "B never ran" "$(job_field "$B" started_at)" "None"

echo "== cancel a running job"
R=$(enqueue '{"ms":60000}')
wait_status "$R" running 50 && pass "R running" || fail "R never started"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "$API/api/jobs/$R/cancel")
check "cancel running answers 200" "$code" "200"
check "R cancelled" "$(job_field "$R" status)" "cancelled"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "$API/api/jobs/$R/cancel")
check "cancel finished answers 409" "$code" "409"
NEXT=$(enqueue '{"ms":10}')
wait_status "$NEXT" succeeded 50 && pass "worker slot freed after cancel" || fail "queue stuck after cancel"

echo "== failures and retry"
F=$(enqueue '{"ms":10,"fail":true}')
X=$(enqueue '{"ms":10,"raise":true}')
wait_status "$F" failed 50 && pass "F failed" || fail "F did not fail"
wait_status "$X" failed 50 && pass "raising runner -> failed" || fail "X did not fail"
check "error text" "$(job_field "$F" error)" "test failure requested"
RETRY=$("${CURL[@]}" -X POST "$API/api/jobs/$F/retry")
check "retry attempt" "$(echo "$RETRY" | jqp 'd["job"]["attempt"]')" "2"
check "retry_of" "$(echo "$RETRY" | jqp 'd["job"]["retry_of"]')" "$F"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST "$API/api/jobs/$A/retry")
check "retry of a succeeded job answers 409" "$code" "409"

echo "== validation"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" "$API/api/jobs" -d '{"kind":"nope","params":{}}')
check "unknown kind answers 400" "$code" "400"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" "$API/api/jobs" -d '{"kind":"test_sleep","params":{"ms":"soon"}}')
check "invalid params answer 400" "$code" "400"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" "$API/api/jobs" -d '{"params":{}}')
check "missing kind answers 400" "$code" "400"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "$API/api/jobs/999999")
check "unknown job answers 404" "$code" "404"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "$API/api/jobs?status=bogus")
check "unknown status filter answers 400" "$code" "400"
code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$API/api/jobs")
check "jobs need authentication" "$code" "401"

echo "== events"
EV=$("${CURL[@]}" "$API/api/events?type=job.&job_id=$A")
check "job events for A" "$(echo "$EV" | jqp '",".join(e["type"] for e in d["events"])')" "job.queued,job.started,job.progress,job.succeeded"
LAST=$(echo "$EV" | jqp 'd["last_id"]')
FIRST_A=$(echo "$EV" | jqp 'd["events"][0]["id"]')
SINCE=$("${CURL[@]}" "$API/api/events?since_id=$FIRST_A&job_id=$A")
check "since_id excludes older events" "$(echo "$SINCE" | jqp 'len(d["events"])')" "3"
check "since_id ascending" "$(echo "$SINCE" | jqp 'd["events"][0]["id"] < d["events"][1]["id"]')" "True"
check "error level filter" "$("${CURL[@]}" "$API/api/events?level=error&type=job." | jqp 'all(e["level"]=="error" for e in d["events"]) and len(d["events"])>=2')" "True"
check "text filter" "$("${CURL[@]}" "$API/api/events?q=TEST%20FAILURE" | jqp 'len(d["events"])>=1')" "True"
check "limit" "$("${CURL[@]}" "$API/api/events?limit=2" | jqp 'len(d["events"])')" "2"
NOW_LAST=$("${CURL[@]}" "$API/api/events?limit=1" | jqp 'd["last_id"]')
EMPTY=$("${CURL[@]}" "$API/api/events?since_id=$NOW_LAST" | jqp 'len(d["events"])')
check "polling at the head returns nothing new" "$EMPTY" "0"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "$API/api/events?level=loud")
check "bad level answers 400" "$code" "400"
check "events.jsonl written" "$( [ -s "$DATA/events.jsonl" ] && echo yes)" "yes"
[ "$LAST" -gt 0 ] 2>/dev/null && pass "last_id is set" || fail "last_id missing"

echo "== clear finished"
CLEARED=$("${CURL[@]}" -X DELETE "$API/api/jobs?status=finished" | jqp 'd["cleared"]')
[ "${CLEARED:-0}" -ge 5 ] && pass "cleared $CLEARED finished jobs" || fail "clear returned '$CLEARED'"
check "finished jobs gone" "$("${CURL[@]}" "$API/api/jobs" | jqp 'd["counts"]["succeeded"]+d["counts"]["failed"]+d["counts"]["cancelled"]')" "0"
code=$("${CURL[@]}" -o /dev/null -w "%{http_code}" -X DELETE "$API/api/jobs?status=queued")
check "clearing active jobs is refused" "$code" "400"

echo "== restart semantics"
RUN=$(enqueue '{"ms":60000}')
Q1=$(enqueue '{"ms":20}')
Q2=$(enqueue '{"ms":20}')
wait_status "$RUN" running 50 && pass "job running before restart" || fail "job not running"
sleep 1.5   # let the debounced jobs.json write happen
stop_pickarr
start_pickarr
check "running job -> failed" "$(job_field "$RUN" status)" "failed"
check "interrupted message" "$(job_field "$RUN" error)" "interrupted by restart"
wait_status "$Q2" succeeded 100 && pass "queued jobs ran after the restart" || fail "queued job not re-run"
check "first queued too" "$(job_field "$Q1" status)" "succeeded"
NEW=$(enqueue '{"ms":10}')
[ "$NEW" -gt "$Q2" ] 2>/dev/null && pass "job ids continue ($NEW > $Q2)" || fail "job id $NEW not after $Q2"
check "job.interrupted event" "$("${CURL[@]}" "$API/api/events?type=job.interrupted" | jqp 'd["events"][-1]["job_id"]')" "$RUN"
NEW_EV=$("${CURL[@]}" "$API/api/events?limit=1" | jqp 'd["last_id"]')
[ "$NEW_EV" -gt "$LAST" ] 2>/dev/null && pass "event ids continue after restart" || fail "event ids reset ($NEW_EV <= $LAST)"

echo
if [ "$FAIL" = 0 ]; then echo "ALL QUEUE CORE E2E CHECKS PASSED"; else echo "SOME CHECKS FAILED (log: $LOG)"; exit 1; fi
