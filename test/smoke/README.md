# Manual smoke tests

Not part of `dune test`: these drive the **real** binary against fake Sonarr,
Radarr and LLM servers, and check the browser UI with a DOM stub. They need
`python3` and `node`, and they use ports 19100-19108.

```bash
# build first, from the repository root
dune build

# select + grab against fake *arr instances; grab-mode chooses what
# POST /api/v3/release answers: echo | nulls | empty | text | notfound | conflict
bash test/smoke/select_grab_e2e.sh echo

# the Select page renders real payloads and awkward shapes without throwing
node test/smoke/render_selection.js /tmp/grabbug-last-preview-sonarr.json

# every element id app.js reaches for exists in index.html
node test/smoke/check_element_ids.js
```

`select_grab_e2e.sh` exits non-zero if any assertion fails. See
`docs/GRAB_BUG_NOTES.md` for what these scripts established.
