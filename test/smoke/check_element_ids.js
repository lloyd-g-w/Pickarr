const fs = require("fs");
const root = require("path").join(__dirname, "..", "..");
process.chdir(root);
const js = fs.readFileSync("static/app.js", "utf8");
const html = fs.readFileSync("static/index.html", "utf8");
const ids = new Set();
for (const m of js.matchAll(/\$\("#([A-Za-z0-9_-]+)"\)/g)) ids.add(m[1]);
for (const m of js.matchAll(/getElementById\("([A-Za-z0-9_-]+)"\)/g)) ids.add(m[1]);
for (const m of js.matchAll(/\$\$\("#([A-Za-z0-9_-]+)/g)) ids.add(m[1]);
const htmlIds = new Set([...html.matchAll(/id="([A-Za-z0-9_-]+)"/g)].map((m) => m[1]));
const created = new Set([...js.matchAll(/id:\s*"([A-Za-z0-9_-]+)"/g)].map((m) => m[1]));
const missing = [...ids].filter((i) => !htmlIds.has(i) && !created.has(i));
console.log("ids referenced in app.js:", ids.size);
console.log("ids present in index.html:", htmlIds.size);
console.log("MISSING (referenced but never in html or created by js):", missing.length ? missing : "none");
// also: duplicate ids in html
const seen = {}, dupes = [];
for (const m of html.matchAll(/id="([A-Za-z0-9_-]+)"/g)) { if (seen[m[1]]) dupes.push(m[1]); seen[m[1]] = 1; }
console.log("duplicate ids in index.html:", dupes.length ? dupes : "none");
