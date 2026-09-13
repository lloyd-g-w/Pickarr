#!/bin/bash
# End-to-end smoke test for library browsing and the "open in ..." links.
#
# Starts a fake Sonarr, a fake Radarr and the real Pickarr binary, then drives
# the Search page's flow through the HTTP API: search the library by name and
# by id, pick a series, list a season's episodes, pick a movie, and run a
# search + grab through the picked item. Asserts that the links are present in
# the search results, the selection result and the history entry.
#
# Ports 19450-19452 on loopback. Only the processes it starts are killed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PICKARR_PORT=19450
SONARR_PORT=19451
RADARR_PORT=19452
DATA=/tmp/pickarr-library-e2e-data
COOKIE=/tmp/pickarr-library-e2e-cookie
SEERR_URL=http://seerr.example:5055
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

python3 "$HERE/fake_library_arr.py" sonarr "$SONARR_PORT" & SONARR_PID=$!
python3 "$HERE/fake_library_arr.py" radarr "$RADARR_PORT" & RADARR_PID=$!
DATA_DIR="$DATA" PORT=$PICKARR_PORT PICKARR_USERNAME=admin PICKARR_PASSWORD=secret123 \
  "$REPO/_build/default/bin/main.exe" > /tmp/pickarr-library-e2e.log 2>&1 & PICKARR_PID=$!

cleanup() { kill $SONARR_PID $RADARR_PID $PICKARR_PID 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

sleep 3
API="http://127.0.0.1:$PICKARR_PORT"
curl -s -c "$COOKIE" -H "Content-Type: application/json" -H "Origin: $API" \
  -d '{"username":"admin","password":"secret123"}' "$API/login" -o /dev/null
CURL=(curl -s -b "$COOKIE")

jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

echo "== configuration"
CODE=$("${CURL[@]}" -o /tmp/pickarr-library-cfg.json -w "%{http_code}" \
  -X PUT -H "Content-Type: application/json" "$API/api/config" -d "$(cat <<JSON
{
  "instances": [
    {"id":"sonarr","name":"Sonarr","app":"sonarr","url":"http://127.0.0.1:$SONARR_PORT","api_key":"k","enabled":true},
    {"id":"radarr","name":"Radarr","app":"radarr","url":"http://127.0.0.1:$RADARR_PORT","api_key":"k","enabled":true}
  ],
  "llm": {"enabled": false},
  "seerr": {"url": "$SEERR_URL", "api_key": "sk"}
}
JSON
)")
check "config accepted" "$CODE" "200"

echo
echo "== search the library by name (Sonarr)"
"${CURL[@]}" "$API/api/library/sonarr/search?q=some%20show" > /tmp/pickarr-lib-series.json
check "one series matched" "$(jqp "len(d['results'])" < /tmp/pickarr-lib-series.json)" "1"
check "title" "$(jqp "d['results'][0]['title']" < /tmp/pickarr-lib-series.json)" "Some Show"
check "kind" "$(jqp "d['results'][0]['kind']" < /tmp/pickarr-lib-series.json)" "series"
check "app reported" "$(jqp "d['app']" < /tmp/pickarr-lib-series.json)" "sonarr"
# 4 + 2 aired episodes with 3 on disk; the specials are excluded.
check "missing count" "$(jqp "d['results'][0]['missing_count']" < /tmp/pickarr-lib-series.json)" "3"
check "season count" "$(jqp "d['results'][0]['season_count']" < /tmp/pickarr-lib-series.json)" "2"
check "sonarr link" "$(jqp "d['results'][0]['links']['arr']" < /tmp/pickarr-lib-series.json)" \
  "http://127.0.0.1:$SONARR_PORT/series/some-show"
check "seerr link (tv, by tmdb id)" "$(jqp "d['results'][0]['links']['seerr']" < /tmp/pickarr-lib-series.json)" \
  "$SEERR_URL/tv/1396"

echo
echo "== search by an alternate title, and by ids"
check "alternate title" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=aru" | jqp "d['results'][0]['title']")" "Some Show"
check "series id" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=12" | jqp "d['results'][0]['title']")" "Some Show"
check "tvdb id" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=7654321" | jqp "d['results'][0]['title']")" "Some Show"
check "imdb id" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=tt1234567" | jqp "d['results'][0]['title']")" "Some Show"
check "an unknown title matches nothing" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=nothing%20here" | jqp "len(d['results'])")" "0"
check "an empty query lists the library" \
  "$("${CURL[@]}" "$API/api/library/sonarr/search?q=" | jqp "len(d['results'])")" "2"

echo
echo "== search the library by name (Radarr)"
"${CURL[@]}" "$API/api/library/radarr/search?q=some%20movie" > /tmp/pickarr-lib-movie.json
check "one movie matched" "$(jqp "len(d['results'])" < /tmp/pickarr-lib-movie.json)" "1"
check "kind" "$(jqp "d['results'][0]['kind']" < /tmp/pickarr-lib-movie.json)" "movie"
check "has_file" "$(jqp "str(d['results'][0]['has_file'])" < /tmp/pickarr-lib-movie.json)" "False"
check "radarr link uses titleSlug" "$(jqp "d['results'][0]['links']['arr']" < /tmp/pickarr-lib-movie.json)" \
  "http://127.0.0.1:$RADARR_PORT/movie/some-movie-603"
check "seerr link (movie)" "$(jqp "d['results'][0]['links']['seerr']" < /tmp/pickarr-lib-movie.json)" \
  "$SEERR_URL/movie/603"
check "searching a movie by its original title" \
  "$("${CURL[@]}" "$API/api/library/radarr/search?q=quelconque" | jqp "d['results'][0]['title']")" "Some Movie"

echo
echo "== pick the series: its seasons"
"${CURL[@]}" "$API/api/library/sonarr/series/12" > /tmp/pickarr-lib-seasons.json
check "two seasons, specials dropped" "$(jqp "len(d['seasons'])" < /tmp/pickarr-lib-seasons.json)" "2"
# Season 1 has three episodes: one on disk, one missing and monitored, and
# one missing but unmonitored, which is not Pickarr's business.
check "season 1 missing (monitored only)" "$(jqp "d['seasons'][0]['missing_episodes']" < /tmp/pickarr-lib-seasons.json)" "1"
check "season 1 total" "$(jqp "d['seasons'][0]['total_episodes']" < /tmp/pickarr-lib-seasons.json)" "3"
check "the series carries its links" "$(jqp "d['series']['links']['arr']" < /tmp/pickarr-lib-seasons.json)" \
  "http://127.0.0.1:$SONARR_PORT/series/some-show"

echo
echo "== expand a season: its episodes"
"${CURL[@]}" "$API/api/library/sonarr/series/12/season/1" > /tmp/pickarr-lib-eps.json
check "three episodes in season 1" "$(jqp "len(d['episodes'])" < /tmp/pickarr-lib-eps.json)" "3"
check "ordered by episode number" "$(jqp "d['episodes'][0]['episode_number']" < /tmp/pickarr-lib-eps.json)" "1"
check "first episode id" "$(jqp "d['episodes'][0]['id']" < /tmp/pickarr-lib-eps.json)" "101"
check "on-disk flag" "$(jqp "str(d['episodes'][0]['has_file'])" < /tmp/pickarr-lib-eps.json)" "True"

echo
echo "== pick the movie: its card"
"${CURL[@]}" "$API/api/library/radarr/movie/77" > /tmp/pickarr-lib-moviecard.json
check "movie id" "$(jqp "d['movie']['media_id']" < /tmp/pickarr-lib-moviecard.json)" "77"
check "movie kind" "$(jqp "d['movie']['media_kind']" < /tmp/pickarr-lib-moviecard.json)" "movie"
check "movie card links" "$(jqp "d['movie']['links']['arr']" < /tmp/pickarr-lib-moviecard.json)" \
  "http://127.0.0.1:$RADARR_PORT/movie/some-movie-603"

echo
echo "== bad input"
check "unknown instance" \
  "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$API/api/library/nope/search?q=x")" "404"
# Sonarr answers 404 for an unknown id, which Pickarr reports as "not found"
# rather than as an instance failure.
check "unknown series" \
  "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$API/api/library/sonarr/series/9999")" "404"
check "non-numeric series id" \
  "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$API/api/library/sonarr/series/abc")" "400"
check "a movie route on a Sonarr instance finds no such media" \
  "$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$API/api/library/sonarr/movie/77")" "404"

echo
echo "== search and grab through the picked movie"
"${CURL[@]}" -X POST -H "Content-Type: application/json" \
  "$API/api/select/radarr/77" -d '{"grab":true}' > /tmp/pickarr-lib-select.json
check "a release was selected" \
  "$(jqp "bool(d['selected'])" < /tmp/pickarr-lib-select.json)" "True"
check "grabbed" "$(jqp "str(d['grabbed'])" < /tmp/pickarr-lib-select.json)" "True"
check "the selection result carries the links" \
  "$(jqp "d['media']['links']['arr']" < /tmp/pickarr-lib-select.json)" \
  "http://127.0.0.1:$RADARR_PORT/movie/some-movie-603"
check "and the Seerr link" \
  "$(jqp "d['media']['links']['seerr']" < /tmp/pickarr-lib-select.json)" "$SEERR_URL/movie/603"
GRABS=$(wc -l < "/tmp/pickarr-library-$RADARR_PORT.grabs.jsonl")
check "exactly one grab was posted" "$GRABS" "1"
check_contains "the grab carries the movie id" "$(cat /tmp/pickarr-library-$RADARR_PORT.grabs.jsonl)" '"movieId":77'

echo
echo "== search and grab one episode of the picked season"
"${CURL[@]}" -X POST -H "Content-Type: application/json" \
  "$API/api/select/sonarr/102" -d '{"grab":true}' > /tmp/pickarr-lib-ep-select.json
check "episode selection grabbed" "$(jqp "str(d['grabbed'])" < /tmp/pickarr-lib-ep-select.json)" "True"
check "an episode links to its series page" \
  "$(jqp "d['media']['links']['arr']" < /tmp/pickarr-lib-ep-select.json)" \
  "http://127.0.0.1:$SONARR_PORT/series/some-show"

echo
echo "== history keeps the links"
"${CURL[@]}" "$API/api/history?limit=5" > /tmp/pickarr-lib-history.json
check "two entries" "$(jqp "len(d)" < /tmp/pickarr-lib-history.json)" "2"
check "newest entry has links" \
  "$(jqp "d[0]['links']['arr']" < /tmp/pickarr-lib-history.json)" \
  "http://127.0.0.1:$SONARR_PORT/series/some-show"

echo
echo "== the library listing is cached, not re-fetched per keystroke"
BEFORE=$(grep -c "GET /api/v3/series$" "/tmp/pickarr-library-$SONARR_PORT.requests.log" || true)
for _ in 1 2 3; do "${CURL[@]}" -o /dev/null "$API/api/library/sonarr/search?q=some"; done
AFTER=$(grep -c "GET /api/v3/series$" "/tmp/pickarr-library-$SONARR_PORT.requests.log" || true)
check "three more searches, no extra listing" "$AFTER" "$BEFORE"

echo
if [ "$FAIL" = "0" ]; then
  echo "ALL LIBRARY E2E CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $FAIL
