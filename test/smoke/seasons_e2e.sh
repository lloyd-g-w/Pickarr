#!/bin/bash
# End-to-end smoke test for the Pickarr "seasons" stream.
# Ports: fake Sonarr 19200, Pickarr 19201 (this worker's range).
set -u
cd "$(git rev-parse --show-toplevel)"

SONARR_PORT=19200
PICKARR_PORT=19201
DATA=/tmp/seasons-pk-data
COOKIE=/tmp/seasons-cookie

rm -rf "$DATA" "$COOKIE"; mkdir -p "$DATA"

python3 /tmp/seasons-fake-sonarr.py $SONARR_PORT > /tmp/seasons-fake-sonarr.log 2>&1 &
FAKE_PID=$!
DATA_DIR=$DATA PORT=$PICKARR_PORT PICKARR_USERNAME=a PICKARR_PASSWORD=secret123 \
  ./_build/default/bin/main.exe > /tmp/seasons-pickarr.log 2>&1 &
PK_PID=$!
cleanup() { kill $FAKE_PID $PK_PID 2>/dev/null; }
trap cleanup EXIT
sleep 2

api() { curl -s -b $COOKIE "$@"; }

curl -s -c $COOKIE -H "Content-Type: application/json" -H "Origin: http://localhost:$PICKARR_PORT" \
  -d '{"username":"a","password":"secret123"}' "localhost:$PICKARR_PORT/login" -o /dev/null

api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d "{\"instances\":[{\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"http://127.0.0.1:$SONARR_PORT\",\"api_key\":\"k\",\"enabled\":true}],
       \"llm\":{\"enabled\":false},
       \"hard_rules\":{\"min_seeders\":1},
       \"seasons\":{\"prefer_packs\":true,\"min_missing_fraction\":0.5,\"fallback_to_episodes\":true}}" -o /dev/null

echo "== 1. series overview =="
api "localhost:$PICKARR_PORT/api/series/sonarr/12" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('series:', d['series']['title'], '| kind:', d['series']['media_kind'], '| media_id:', d['series']['media_id'])
print('total/missing:', d['total_episodes'], d['missing_episodes'])
for s in d['seasons']:
    print(f\"  season {s['season_number']}: {s['missing_episodes']}/{s['total_episodes']} missing, ids={s['missing_episode_ids']}, on disk={s['existing_quality']}\")"

echo
echo "== 2. season 2 selection (pack expected; singles + wrong season rejected) =="
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/season/12/2" -d '{"grab":true}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
print('media kind:', r['media']['media_kind'], '| season:', r['media']['season_number'])
print('selected:', r['selected']['release']['title'] if r['selected'] else None)
print('full_season:', r['selected']['release']['full_season'] if r['selected'] else None)
print('grabbed:', r['grabbed'], '| error:', r['grab_error'])
print('candidates:', [c['release']['id'] for c in r['candidates']])
print('rejected:')
for x in r['rejected']:
    print('  ', x['release']['id'], [y['rule'] for y in x['reasons']], [y['message'] for y in x['reasons']])"

echo
echo "== 3. grab bodies seen by Sonarr =="
curl -s "localhost:$SONARR_PORT/__grabs" | python3 -m json.tool

echo
echo "== 4. whole series (season 2 -> pack, season 1 -> per episode) =="
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{"grab":false}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
print('series:', r['series']['title'], '| summary:', r['summary'])
for s in r['seasons']:
    o=s['outcome']
    print(f\"  season {s['season_number']}: {s['missing']}/{s['total']} -> {o['kind']}\")
    if o['kind']=='pack':
        print('     pack:', o['selection']['selected']['release']['title'])
    elif o['kind']=='episodes':
        for sel in o['selections']:
            print('     episode:', sel['media']['media_id'], '->', (sel['selected'] or {}).get('release',{}).get('title'))
    else:
        print('     reason:', o['reason'])"

echo
echo "== 5. restricted to season 1 only, with seasons:[1] =="
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{"seasons":[1]}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
print('seasons processed:', [(s['season_number'], s['outcome']['kind']) for s in r['seasons']])"

echo
echo "== 6a. a low threshold makes the barely-missing season 1 use a pack too =="
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"seasons":{"min_missing_fraction":0.1}}' -o /dev/null
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
print('seasons:', [(s['season_number'], s['outcome']['kind']) for s in r['seasons']])"

echo "== 6b. packs disabled: everything goes per episode =="
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"seasons":{"prefer_packs":false,"min_missing_fraction":0.5}}' -o /dev/null
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
print('seasons:', [(s['season_number'], s['outcome']['kind'], len(s['outcome'].get('selections',[]))) for s in r['seasons']])"

echo "== 6c. the stored fraction is clamped to 0..1 =="
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"seasons":{"prefer_packs":true,"min_missing_fraction":1.5}}' -o /dev/null
api "localhost:$PICKARR_PORT/api/config" | python3 -c "
import json,sys; print('seasons config:', json.load(sys.stdin)['seasons'])"

echo "== 6d. no pack available -> fallback to episodes =="
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"seasons":{"prefer_packs":true,"min_missing_fraction":0.5,"fallback_to_episodes":true},
       "hard_rules":{"blocked_title_patterns":["Some.Show.S02."]}}' -o /dev/null
api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{"seasons":[2]}' \
| python3 -c "
import json,sys
r=json.load(sys.stdin)
s=r['seasons'][0]; o=s['outcome']
print('season', s['season_number'], '->', o['kind'])
if o['kind']=='episodes':
    print('  episodes selected:', [(x['media']['media_id'], (x['selected'] or {}).get('release',{}).get('title')) for x in o['selections']])"
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"hard_rules":{"blocked_title_patterns":[]}}' -o /dev/null

echo
echo "== 7. per-instance routes and error handling =="
echo -n "instance season route: "; api -o /dev/null -w "%{http_code}\n" -X POST "localhost:$PICKARR_PORT/api/select/sonarr/season/12/2"
echo -n "unknown instance:     "; api -X POST "localhost:$PICKARR_PORT/api/select/nope/season/12/2"; echo
echo -n "bad season number:    "; api -X POST "localhost:$PICKARR_PORT/api/select/sonarr/season/12/x"; echo
echo -n "bad seasons body:     "; api -X POST -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/select/sonarr/series/12" -d '{"seasons":["x"]}'; echo
echo -n "episode route still works: "; api -o /dev/null -w "%{http_code}\n" -X POST "localhost:$PICKARR_PORT/api/select/sonarr/104"

echo
echo "== 8. automatic mode collapses a fully missing season into one pack =="
curl -s "localhost:$SONARR_PORT/__grabs" > /dev/null
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d "{\"instances\":[{\"id\":\"sonarr\",\"name\":\"Sonarr\",\"app\":\"sonarr\",\"url\":\"http://127.0.0.1:$SONARR_PORT\",\"api_key\":\"k\",\"enabled\":true,\"automatic\":true}],
       \"automatic\":{\"enabled\":true,\"grab\":true,\"search_missing\":true,\"max_items_per_run\":10},
       \"seasons\":{\"prefer_packs\":true,\"min_missing_fraction\":0.5,\"fallback_to_episodes\":true}}" -o /dev/null
api -X POST "localhost:$PICKARR_PORT/api/automatic/run" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('items processed:', len(d.get('results',[])))
for r in d.get('results',[]):
    print(' ', r.get('media'), '->', r.get('selected'), '| grabbed:', r.get('grabbed'), '| skipped:', r.get('skipped'), '| error:', r.get('error'))"
echo "grab bodies after the automatic pass:"
curl -s "localhost:$SONARR_PORT/__grabs" | python3 -c "
import json,sys
for g in json.load(sys.stdin): print(' ', json.dumps(g))"

echo
echo "== pickarr log (season lines) =="
grep -aE "season|pack" /tmp/seasons-pickarr.log | grep -av dream.logger | tail -20

echo
echo "== 9. UI assets served and the seasons config round-trips =="
curl -s "localhost:$PICKARR_PORT/static/app.js" -o /dev/null -w "app.js: %{http_code} %{size_download} bytes\n"
curl -s "localhost:$PICKARR_PORT/static/index.html" | grep -c "select-what\|seasons-form" | sed 's/^/index.html season markup hits: /'
api -X PUT -H "Content-Type: application/json" "localhost:$PICKARR_PORT/api/config" \
  -d '{"seasons":{"prefer_packs":true,"min_missing_fraction":0.34,"fallback_to_episodes":false}}' -o /dev/null
api "localhost:$PICKARR_PORT/api/config" | python3 -c "
import json,sys; print('stored seasons:', json.load(sys.stdin)['seasons'])"
