#!/bin/bash
# PunkNuke //LOLZ comic archive: adds the User Friendly archive (1997-2013)
# Usage: sudo bash setup-comics.sh
# Re-run safe: skips the download if the archive is already there.
set -e
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
DATA=/mnt/data/comics
CID=userfriendly
TITLE="User Friendly (1997-2013)"
URL="https://archive.org/download/user-friendly-comic/UserFriendlyComics.cbz"

mountpoint -q /mnt/data || { echo "[!] /mnt/data is not mounted - stopping"; exit 1; }
apt install -y unzip aria2 python3 >/dev/null

mkdir -p "$DATA/$CID" "$DATA/.incoming" /var/www/comics
chown -R "$RUN_USER:$RUN_USER" "$DATA"

if [ -z "$(find "$DATA/$CID" -type f \( -iname '*.gif' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print -quit)" ]; then
  echo "[*] Downloading User Friendly archive (about 184 MB)"
  rm -f "$DATA/.incoming/UserFriendlyComics.cbz.meta4"
  sudo -u "$RUN_USER" aria2c -c -x2 -s2 --auto-file-renaming=false -d "$DATA/.incoming" "$URL"
  echo "[*] Unpacking"
  sudo -u "$RUN_USER" unzip -q -o "$DATA/.incoming/UserFriendlyComics.cbz" -d "$DATA/$CID"
  rm -f "$DATA/.incoming/UserFriendlyComics.cbz" "$DATA/.incoming/UserFriendlyComics.cbz.aria2"
else
  echo "[=] Archive already unpacked, skipping download"
fi

echo "[*] Building comic index"
cat > /opt/punknuke/comics-index.py <<'PY_END'
#!/usr/bin/env python3
"""Builds index.json for each comic folder in /mnt/data/comics and collections.json listing them.
A collection's title comes from a title.txt in its folder, else the folder name."""
import json, os, re, sys
ROOT = "/mnt/data/comics"
EXT = (".gif", ".png", ".jpg", ".jpeg", ".webp")
def natural(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]
cols = []
for cid in sorted(os.listdir(ROOT)):
    d = os.path.join(ROOT, cid)
    if cid.startswith(".") or not os.path.isdir(d) or not re.fullmatch(r"[A-Za-z0-9_-]+", cid):
        continue
    files = []
    for base, dirs, names in os.walk(d):
        dirs[:] = [x for x in dirs if not x.startswith(".") and x != "__MACOSX"]
        for n in names:
            if n.lower().endswith(EXT) and not n.startswith("."):
                files.append(os.path.relpath(os.path.join(base, n), d))
    files.sort(key=natural)
    if not files:
        continue
    with open(os.path.join(d, "index.json"), "w") as f:
        json.dump(files, f)
    title = cid
    t = os.path.join(d, "title.txt")
    if os.path.exists(t):
        title = open(t).read().strip() or cid
    cols.append({"id": cid, "title": title, "count": len(files)})
with open(os.path.join(ROOT, "collections.json"), "w") as f:
    json.dump(cols, f)
for c in cols:
    print(f"  {c['title']}: {c['count']} images")
PY_END
echo "$TITLE" > "$DATA/$CID/title.txt"
sudo -u "$RUN_USER" python3 /opt/punknuke/comics-index.py
chown -R "$RUN_USER:$RUN_USER" "$DATA"
chmod -R a+rX "$DATA"

echo "[*] Installing comic reader page"
cat > /var/www/comics/index.html <<'HTML_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>PUNKNUKE // LOLZ</title>
<meta name="theme-color" content="#0b0d1c">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
:root{
  --void:#0b0d1c; --panel:#13162b; --line:#262a48;
  --amber:#ffa733; --pink:#ff3dbb; --cyan:#3ef0ff; --dim:#8a8fb0; --text:#e3e6f5;
  --mono:ui-monospace,"SF Mono",Menlo,Consolas,"Roboto Mono","Liberation Mono",monospace;
  --cond:"sans-serif-condensed","Roboto Condensed","Arial Narrow","Helvetica Neue",Arial,sans-serif;
}
*{box-sizing:border-box}
html{background:var(--void); -webkit-text-size-adjust:100%; text-size-adjust:100%}
html,body{overflow-x:hidden; max-width:100%}
body{margin:0; min-height:100vh; color:var(--text); font-family:var(--mono); font-size:15px; line-height:1.5;
  display:flex; flex-direction:column; padding-bottom:env(safe-area-inset-bottom,0)}
a{color:inherit}
:focus-visible{outline:2px solid var(--pink); outline-offset:3px}
header{display:flex; align-items:center; gap:12px; padding:12px 16px; border-bottom:1px solid var(--line)}
header a.home{color:var(--dim); text-decoration:none; font-size:13px}
header h1{margin:0; font-family:var(--cond); font-stretch:condensed; font-weight:800; font-size:1.5rem;
  line-height:1; color:var(--cyan); flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}

/* collection list */
.list{max-width:720px; width:100%; margin:0 auto; padding:24px 16px}
.list p{color:var(--dim); margin:0 0 16px}
.col{display:block; text-decoration:none; padding:14px; border-top:1px solid var(--line); border-left:3px solid transparent}
.col:last-child{border-bottom:1px solid var(--line)}
.col:hover,.col:focus-visible{border-left-color:var(--pink); background:var(--panel); outline:none}
.col b{display:block; font-weight:600}
.col span{color:var(--dim); font-size:13px}

/* reader */
.meta{display:flex; justify-content:space-between; align-items:center; gap:12px; padding:10px 16px; color:var(--dim); font-size:13px}
.meta b{color:var(--amber); font-weight:400}
.meta select{font:inherit; color:var(--text); background:var(--panel); border:1px solid var(--line); padding:6px 8px; border-radius:0}
.stage{flex:1; display:flex; align-items:center; justify-content:center; padding:8px; min-height:0; touch-action:pan-y pinch-zoom}
.stage img{max-width:100%; max-height:calc(100vh - 190px); height:auto; background:#fff; display:block}
.stage .msg{color:var(--dim); text-align:center; padding:40px 16px}
.hint{text-align:center; color:var(--dim); font-size:12px; padding:0 16px 6px}
nav.ctrl{position:sticky; bottom:0; display:grid; grid-template-columns:1fr 1fr 1.3fr 1fr 1fr; gap:6px;
  padding:10px 12px; background:var(--void); border-top:1px solid var(--line)}
nav.ctrl button{font:inherit; color:var(--text); background:var(--panel); border:1px solid var(--line);
  min-height:48px; border-radius:0; cursor:pointer; font-size:14px}
nav.ctrl button.rand{background:var(--cyan); color:var(--void); border-color:var(--cyan); font-weight:700}
nav.ctrl button:active{border-color:var(--amber)}
nav.ctrl button:disabled{opacity:.35}
[hidden]{display:none !important}
</style>
</head>
<body>
<header>
  <a class="home" href="/">&larr; Portal</a>
  <h1 id="title">//LOLZ</h1>
</header>

<section class="list" id="list" hidden>
  <p>Pre-collapse humor, preserved for the survivors.</p>
  <div id="cols"></div>
</section>

<div id="reader" hidden style="display:contents">
  <div class="meta">
    <span><b id="pos">–</b> / <span id="total">–</span> <span id="date"></span></span>
    <select id="year" aria-label="Jump to year" hidden></select>
  </div>
  <div class="stage" id="stage"><img id="img" alt=""></div>
  <div class="hint">Swipe or use the buttons. Turn your phone sideways for wide strips.</div>
  <nav class="ctrl">
    <button id="first" type="button" aria-label="First">|&lt;</button>
    <button id="prev" type="button">&lt; Prev</button>
    <button id="rand" type="button" class="rand">Random</button>
    <button id="next" type="button">Next &gt;</button>
    <button id="last" type="button" aria-label="Last">&gt;|</button>
  </nav>
</div>

<script>
const $ = id => document.getElementById(id);
const DATA = "/comics-data/";
const params = new URLSearchParams(location.search);
const cid = params.get("c");
const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
let files = [], idx = 0;

const store = {
  get(k){ try { return localStorage.getItem(k); } catch(e){ return null; } },
  set(k, v){ try { localStorage.setItem(k, v); } catch(e){} }
};
const enc = p => p.split("/").map(encodeURIComponent).join("/");
function dateOf(name){
  const m = name.match(/(19\d{2}|20\d{2})[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12]\d|3[01])/);
  return m ? {y:+m[1], m:+m[2], d:+m[3]} : null;
}
function msg(text){
  const s = $("stage"); s.replaceChildren();
  const d = document.createElement("div"); d.className = "msg"; d.textContent = text; s.append(d);
}

async function listCollections(){
  $("list").hidden = false;
  try{
    const cols = await (await fetch(DATA + "collections.json", {cache:"no-store"})).json();
    const box = $("cols");
    if (!cols.length){ box.textContent = "No collections loaded yet."; return; }
    cols.forEach(c => {
      const a = document.createElement("a"); a.className = "col"; a.href = "?c=" + encodeURIComponent(c.id);
      const b = document.createElement("b"); b.textContent = c.title;
      const s = document.createElement("span"); s.textContent = c.count.toLocaleString("en") + " images";
      a.append(b, s); box.append(a);
    });
  }catch(e){ $("cols").textContent = "The archive isn't reachable right now."; }
}

function show(i){
  if (!files.length) return;
  idx = Math.max(0, Math.min(files.length - 1, i));
  const f = files[idx];
  const img = $("img");
  if (!img.isConnected){ $("stage").replaceChildren(img); }
  img.src = DATA + encodeURIComponent(cid) + "/" + enc(f);
  img.alt = "Strip " + (idx + 1);
  $("pos").textContent = (idx + 1).toLocaleString("en");
  const d = dateOf(f);
  $("date").textContent = d ? " · " + d.d + " " + MONTHS.at(d.m - 1) + " " + d.y : "";
  if (d && !$("year").hidden) $("year").value = String(d.y);
  $("first").disabled = $("prev").disabled = idx === 0;
  $("last").disabled = $("next").disabled = idx === files.length - 1;
  store.set("lolz-" + cid, String(idx));
  history.replaceState(null, "", "?c=" + encodeURIComponent(cid) + "#" + (idx + 1));
  // preload neighbours
  [idx + 1, idx - 1].forEach(j => { if (files[j]){ const p = new Image(); p.src = DATA + encodeURIComponent(cid) + "/" + enc(files[j]); } });
  window.scrollTo(0, 0);
}

async function openCollection(){
  $("reader").hidden = false;
  try{
    const [cols, list] = await Promise.all([
      fetch(DATA + "collections.json", {cache:"no-store"}).then(r => r.json()),
      fetch(DATA + encodeURIComponent(cid) + "/index.json", {cache:"no-store"}).then(r => { if (!r.ok) throw 0; return r.json(); })
    ]);
    files = list;
    const c = cols.find(x => x.id === cid);
    $("title").textContent = c ? c.title : cid;
    document.title = "PUNKNUKE // " + (c ? c.title : cid);
    $("total").textContent = files.length.toLocaleString("en");
    // year jump menu, if the filenames carry dates
    const years = new Map();
    files.forEach((f, i) => { const d = dateOf(f); if (d && !years.has(d.y)) years.set(d.y, i); });
    if (years.size > 1){
      const sel = $("year");
      years.forEach((i, y) => { const o = document.createElement("option"); o.value = String(y); o.textContent = y; sel.append(o); });
      sel.hidden = false;
      sel.addEventListener("change", () => show(years.get(+sel.value)));
    }
    const fromHash = parseInt(location.hash.slice(1), 10);
    const saved = parseInt(store.get("lolz-" + cid) || "", 10);
    show(!isNaN(fromHash) ? fromHash - 1 : !isNaN(saved) ? saved : 0);
  }catch(e){ msg("This collection isn't reachable right now."); }
}

$("first").addEventListener("click", () => show(0));
$("prev").addEventListener("click", () => show(idx - 1));
$("next").addEventListener("click", () => show(idx + 1));
$("last").addEventListener("click", () => show(files.length - 1));
$("rand").addEventListener("click", () => show(Math.floor(Math.random() * files.length)));
document.addEventListener("keydown", e => {
  if (!files.length || e.target.tagName === "SELECT") return;
  if (e.key === "ArrowLeft") show(idx - 1);
  if (e.key === "ArrowRight") show(idx + 1);
  if (e.key === "r") show(Math.floor(Math.random() * files.length));
});
// swipe left/right (ignored while pinch-zooming)
let sx = null, sy = null;
$("stage").addEventListener("touchstart", e => { if (e.touches.length === 1){ sx = e.touches[0].clientX; sy = e.touches[0].clientY; } else sx = null; }, {passive:true});
$("stage").addEventListener("touchend", e => {
  if (sx === null || (window.visualViewport && visualViewport.scale > 1.05)) return;
  const dx = e.changedTouches[0].clientX - sx, dy = e.changedTouches[0].clientY - sy;
  if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) show(idx + (dx < 0 ? 1 : -1));
  sx = null;
}, {passive:true});
$("img").addEventListener("error", () => msg("This strip couldn't be loaded."));

if (cid && /^[A-Za-z0-9_-]+$/.test(cid)) openCollection(); else listCollections();
</script>
</body>
</html>
HTML_END

echo "[*] Adding /comics/ to nginx"
CONF=/etc/nginx/sites-available/portal
if ! grep -q 'location /comics-data/' "$CONF"; then
  cp "$CONF" "$CONF.bak"
  python3 - "$CONF" <<'PY_END'
import sys
p = sys.argv[1]; s = open(p).read()
block = """    location = /comics { return 301 /comics/; }
    location /comics/ {
        alias /var/www/comics/;
        index index.html;
    }
    location /comics-data/ {
        alias /mnt/data/comics/;
        expires 7d;
    }

    location /lib/ {"""
if "    location /lib/ {" not in s:
    sys.exit("could not find 'location /lib/' in nginx config")
open(p, "w").write(s.replace("    location /lib/ {", block, 1))
PY_END
fi
nginx -t
systemctl reload nginx

echo "[+] Done. Comics at http://portal.lan/comics/"
echo "    Add more: put a folder of images in $DATA/<name>/ (letters, digits, - or _),"
echo "    optionally a title.txt, then run: python3 /opt/punknuke/comics-index.py"
