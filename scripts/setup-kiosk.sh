#!/bin/bash
# PunkNuke touchscreen kiosk setup
# Usage: sudo bash setup-kiosk.sh
# Installs: display stats API, display page at /kiosk/, QR codes,
# and a full-screen Chromium display on the HDMI screen that starts at boot.
# Display only: the page ignores touch.
set -e
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
KUSER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"

echo "[*] Installing packages"
apt update
apt install -y cage python3-qrcode fonts-dejavu-core fonts-dejavu-extra
apt install -y chromium || apt install -y chromium-browser
CHROME="$(command -v chromium || command -v chromium-browser)"
[ -n "$CHROME" ] || { echo "Chromium not found after install"; exit 1; }
usermod -aG video,render,input "$KUSER"

mkdir -p /opt/punknuke /var/www/kiosk /var/lib/punknuke

echo "[*] Removing the old game service if present"
systemctl disable --now punknuke-game 2>/dev/null || true
rm -f /etc/systemd/system/punknuke-game.service /opt/punknuke/game.py

echo "[*] Writing display stats API"
cat > /opt/punknuke/public.py <<'PY_END'
#!/usr/bin/env python3
"""PunkNuke display stats API. Localhost only; nginx serves it at /api/public.
Returns only counts (no IPs or MACs), so it is safe to expose to everyone."""
import json, os, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IFACE = "wlan0"
LEASES = "/var/lib/misc/dnsmasq.leases"
ZIM = "/mnt/data/zim"
_cache = {"t": 0, "v": None}

def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return ""

def public():
    if time.time() - _cache["t"] < 3 and _cache["v"]:
        return _cache["v"]
    connected = sum(1 for l in run(["iw", "dev", IFACE, "station", "dump"]).splitlines() if l.startswith("Station "))
    try:
        today = sum(1 for l in open(LEASES) if l.strip())
    except OSError:
        today = 0
    try:
        libraries = sum(1 for f in os.listdir(ZIM) if f.endswith(".zim"))
    except OSError:
        libraries = 0
    ssid = run(["nmcli", "-g", "802-11-wireless.ssid", "con", "show", "portal"]).strip()
    v = {"connected": connected, "today": today, "libraries": libraries, "ssid": ssid}
    _cache.update(t=time.time(), v=v)
    return v

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/public"):
            code, obj = 200, public()
        else:
            code, obj = 404, {"error": "not found"}
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
PY_END

cat > /etc/systemd/system/punknuke-public.service <<'UNIT_END'
[Unit]
Description=PunkNuke display stats API
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/punknuke/public.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_END

echo "[*] Writing kiosk page"
cat > /var/www/kiosk/index.html <<'HTML_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>PunkNuke display</title>
<style>
:root{
  --void:#0b0d1c; --panel:rgba(11,13,28,.78); --line:#262a48;
  --amber:#ffa733; --pink:#ff3dbb; --cyan:#3ef0ff; --dim:#8a8fb0; --text:#e3e6f5;
  --mono:"DejaVu Sans Mono",ui-monospace,Menlo,Consolas,monospace;
  --cond:"DejaVu Sans Condensed","Roboto Condensed","Arial Narrow",Arial,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0; height:100%; overflow:hidden; background:var(--void); color:var(--text);
  font-family:var(--mono); cursor:none; user-select:none; -webkit-user-select:none; touch-action:none}
/* display only: nothing on the page reacts to touch */
body *{pointer-events:none}
canvas{position:fixed; inset:0; width:100%; height:100%; z-index:0}
.vignette{position:fixed; inset:0; z-index:1;
  background:radial-gradient(ellipse at 30% 50%, transparent 30%, rgba(5,6,14,.85) 100%)}
.scan{position:fixed; inset:0; z-index:3;
  background:repeating-linear-gradient(to bottom,rgba(255,255,255,.03) 0 1px,transparent 1px 3px)}
main{position:relative; z-index:2; height:100%; padding:3vh 3vw;
  display:grid; grid-template-columns:44% 1fr; grid-template-rows:1fr auto; gap:2.5vh 3vw}

.brand{display:flex; align-items:center; justify-content:center; min-height:0; position:relative}
.brand::before{content:""; position:absolute; width:70%; aspect-ratio:1; border-radius:50%;
  background:radial-gradient(circle, rgba(62,240,255,.22), rgba(255,61,187,.12) 45%, transparent 70%);
  animation:glow 5s ease-in-out infinite}
.brand img{position:relative; max-height:78vh; max-width:100%; height:auto;
  -webkit-mask-image:radial-gradient(ellipse at center, #000 58%, transparent 74%);
  mask-image:radial-gradient(ellipse at center, #000 58%, transparent 74%)}

.join{align-self:center; background:var(--panel); border:1px solid var(--line); border-left:3px solid var(--cyan);
  padding:3.5vh 2.5vw}
.join h1{margin:0; font-family:var(--cond); font-weight:800; font-size:8vh; line-height:1}
.join p{margin:1.2vh 0 3.5vh; color:var(--dim); font-size:2.7vh}
.qrs{display:flex; gap:2.5vw}
.qr{flex:1; text-align:center; min-width:0}
.qr .code{background:#fff; padding:1.2vh; border:3px solid var(--cyan); aspect-ratio:1; max-height:36vh; margin:0 auto}
.qr:nth-child(2) .code{border-color:var(--pink)}
.qr img{width:100%; height:100%; display:block}
.qr span{display:block; margin-top:1.4vh; font-size:2.6vh}
.qr small{display:block; color:var(--dim); font-size:2.2vh; margin-top:.4vh}

.status{grid-column:1 / -1; display:flex; align-items:center; gap:4vw; background:var(--panel);
  border-top:1px solid var(--line); padding:1.6vh 2vw; font-size:2.8vh; color:var(--dim)}
.status b{font-family:var(--cond); font-weight:800; font-size:4.4vh; color:var(--cyan); margin-right:.8vw}
.status .live{color:var(--text)}
.status .live::before{content:""; display:inline-block; width:1.4vh; height:1.4vh; border-radius:50%;
  background:var(--pink); box-shadow:0 0 1.2vh var(--pink); margin-right:1vw; vertical-align:middle;
  animation:blink 2s ease-in-out infinite}
.status .clock{margin-left:auto; color:var(--amber)}

@keyframes glow{50%{transform:scale(1.08); opacity:.65}}
@keyframes blink{50%{opacity:.3}}
</style>
</head>
<body>
<canvas id="bg"></canvas>
<div class="vignette"></div>
<main>
  <div class="brand"><img src="/logo.jpg" alt="Punk Nuke"></div>
  <section class="join">
    <h1>Join the node</h1>
    <p>Offline survival archive. No mobile data needed.</p>
    <div class="qrs">
      <div class="qr"><div class="code"><img src="qr-wifi.svg" alt=""></div><span>1. Scan to join Wi-Fi</span><small id="ssid">NEON-NODE</small></div>
      <div class="qr"><div class="code"><img src="qr-portal.svg" alt=""></div><span>2. Scan to open archive</span><small>portal.lan</small></div>
    </div>
  </section>
  <div class="status">
    <span class="live">Node online</span>
    <span><b id="st-now">–</b>connected now</span>
    <span><b id="st-today">–</b>survivors today</span>
    <span><b id="st-libs">–</b>libraries</span>
    <span class="clock" id="clock"></span>
  </div>
</main>
<div class="scan"></div>

<script>
/* ---------- live stats ---------- */
const $ = id => document.getElementById(id);
async function stats(){
  try{
    const j = await (await fetch("/api/public", {cache:"no-store"})).json();
    $("st-now").textContent = j.connected; $("st-today").textContent = j.today; $("st-libs").textContent = j.libraries;
    if (j.ssid) $("ssid").textContent = j.ssid;
  }catch(e){}
}
function clock(){ $("clock").textContent = new Date().toLocaleTimeString([], {hour:"2-digit", minute:"2-digit"}); }
stats(); clock(); setInterval(stats, 5000); setInterval(clock, 10000);
document.addEventListener("contextmenu", e => e.preventDefault());
document.addEventListener("touchstart", e => e.preventDefault(), {passive:false});

/* ---------- animated circuit background ---------- */
const cv = $("bg"), ctx = cv.getContext("2d");
const COLORS = ["#3ef0ff", "#ff3dbb", "#ffa733"];
const GRID = 22, FPS = 30;
let W, H, traces = [], pulses = [], board;

function buildTraces(){
  W = cv.width = innerWidth; H = cv.height = innerHeight;
  traces = [];
  const dirs = [[1,0],[1,1],[0,1],[-1,1],[-1,0],[-1,-1],[0,-1],[1,-1]];
  const count = Math.round(W * H / 9000);
  for (let n = 0; n < count; n++){
    let x = Math.round(Math.random() * W / GRID) * GRID, y = Math.round(Math.random() * H / GRID) * GRID;
    let d = [0, 2, 4, 6][Math.floor(Math.random() * 4)];
    const pts = [[x, y]];
    const segs = 3 + Math.floor(Math.random() * 5);
    for (let s = 0; s < segs; s++){
      const len = (2 + Math.floor(Math.random() * 9)) * GRID;
      const [dx, dy] = dirs[d], k = dx && dy ? Math.SQRT1_2 : 1;
      x += dx * len * k; y += dy * len * k;
      pts.push([x, y]);
      d = (d + (Math.random() < .5 ? 1 : 7)) % 8;
    }
    const lens = [0];
    for (let i = 1; i < pts.length; i++) lens.push(lens[i-1] + Math.hypot(pts[i][0]-pts[i-1][0], pts[i][1]-pts[i-1][1]));
    traces.push({pts, lens, total: lens[lens.length - 1]});
  }
  // draw the static board once
  board = document.createElement("canvas"); board.width = W; board.height = H;
  const b = board.getContext("2d");
  b.lineWidth = 1.5; b.lineCap = "round"; b.lineJoin = "round";
  for (const t of traces){
    b.strokeStyle = "rgba(80,90,160,.22)";
    b.beginPath(); t.pts.forEach(([x,y], i) => i ? b.lineTo(x,y) : b.moveTo(x,y)); b.stroke();
    const [ex, ey] = t.pts[t.pts.length - 1], [sx, sy] = t.pts[0];
    b.fillStyle = "rgba(80,90,160,.4)";
    b.beginPath(); b.arc(ex, ey, 3, 0, 7); b.fill();
    b.strokeStyle = "rgba(80,90,160,.35)";
    b.beginPath(); b.arc(sx, sy, 3.5, 0, 7); b.stroke();
  }
}
function pointAt(t, d){
  d = Math.max(0, Math.min(t.total, d));
  let i = 1; while (i < t.lens.length - 1 && t.lens[i] < d) i++;
  const f = (d - t.lens[i-1]) / ((t.lens[i] - t.lens[i-1]) || 1);
  const a = t.pts[i-1], b = t.pts[i];
  return [a[0] + (b[0]-a[0]) * f, a[1] + (b[1]-a[1]) * f, i];
}
function strokeSub(t, d0, d1){
  const s = pointAt(t, d0), e = pointAt(t, d1);
  ctx.beginPath(); ctx.moveTo(s[0], s[1]);
  for (let i = s[2]; i < e[2]; i++) ctx.lineTo(t.pts[i][0], t.pts[i][1]);
  ctx.lineTo(e[0], e[1]); ctx.stroke();
}
function spawn(){
  const t = traces[Math.floor(Math.random() * traces.length)];
  pulses.push({t, d:0, speed: 90 + Math.random() * 140, tail: 50 + Math.random() * 70,
    color: COLORS[Math.floor(Math.random() * COLORS.length)]});
}
let last = 0, acc = 0;
function frame(now){
  requestAnimationFrame(frame);
  const dt = Math.min(.1, (now - last) / 1000); last = now; acc += dt;
  if (acc < 1 / FPS) return;
  const step = acc; acc = 0;
  ctx.globalCompositeOperation = "source-over";
  ctx.drawImage(board, 0, 0);
  if (pulses.length < 14 && Math.random() < .25) spawn();
  ctx.globalCompositeOperation = "lighter";
  ctx.lineCap = "round"; ctx.lineJoin = "round";
  pulses = pulses.filter(p => p.d - p.tail < p.t.total);
  for (const p of pulses){
    p.d += p.speed * step;
    const head = Math.min(p.d, p.t.total);
    for (let k = 0; k < 6; k++){
      const a = head - p.tail * (k + 1) / 6, b = head - p.tail * k / 6;
      if (b <= 0) break;
      ctx.globalAlpha = (1 - k / 6) * .9;
      ctx.strokeStyle = p.color;
      ctx.lineWidth = 6; ctx.globalAlpha *= .25; strokeSub(p.t, Math.max(0, a), b);
      ctx.lineWidth = 2; ctx.globalAlpha = (1 - k / 6) * .9; strokeSub(p.t, Math.max(0, a), b);
    }
    if (p.d <= p.t.total){
      const [x, y] = pointAt(p.t, head);
      ctx.globalAlpha = 1; ctx.fillStyle = "#fff";
      ctx.beginPath(); ctx.arc(x, y, 2.2, 0, 7); ctx.fill();
      ctx.globalAlpha = .35; ctx.fillStyle = p.color;
      ctx.beginPath(); ctx.arc(x, y, 7, 0, 7); ctx.fill();
    }
  }
  ctx.globalAlpha = 1;
}
buildTraces();
addEventListener("resize", buildTraces);
requestAnimationFrame(frame);
</script>
</body>
</html>
HTML_END

echo "[*] Generating QR codes"
SSID="$(nmcli -g 802-11-wireless.ssid con show portal 2>/dev/null || true)"
SSID="${SSID:-NEON-NODE}"
SSID="$SSID" python3 - <<'QR_END'
import os, re, qrcode, qrcode.image.svg
ssid = os.environ["SSID"]
esc = re.sub(r'([\\;,:"])', r'\\\1', ssid)
for name, data in [("wifi", f"WIFI:T:nopass;S:{esc};;"), ("portal", "http://portal.lan/")]:
    qrcode.make(data, image_factory=qrcode.image.svg.SvgPathImage, box_size=10, border=1).save(f"/var/www/kiosk/qr-{name}.svg")
QR_END

echo "[*] Updating nginx config"
[ -f /etc/nginx/punknuke.htpasswd ] || echo "  (note: admin password not set yet - run setup-admin.sh if you want /admin/)"
cp /etc/nginx/sites-available/portal /etc/nginx/sites-available/portal.bak 2>/dev/null || true
cat > /etc/nginx/sites-available/portal <<'NGINX_END'
server {
    listen 80 default_server;
    server_name _;
    return 302 http://portal.lan/;
}
server {
    listen 80;
    server_name portal.lan 10.42.0.1 punknuke.local 127.0.0.1 localhost;
    root /var/www/portal;
    index index.html;

    location / { try_files $uri $uri/ @home; }
    location @home { return 302 http://portal.lan/; }

    location = /comics { return 301 /comics/; }
    location /comics/ {
        alias /var/www/comics/;
        index index.html;
    }
    location /comics-data/ {
        alias /mnt/data/comics/;
        expires 7d;
    }

    location /lib/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location = /admin { return 301 /admin/; }
    location /admin/ {
        auth_basic "PunkNuke admin";
        auth_basic_user_file /etc/nginx/punknuke.htpasswd;
        alias /var/www/admin/;
        index index.html;
        add_header Cache-Control "no-store";
    }
    location /admin/api/ {
        auth_basic "PunkNuke admin";
        auth_basic_user_file /etc/nginx/punknuke.htpasswd;
        proxy_pass http://127.0.0.1:8090/;
    }

    location /kiosk/ {
        alias /var/www/kiosk/;
        index index.html;
        add_header Cache-Control "no-store";
    }
    location = /api/public {
        proxy_pass http://127.0.0.1:8091/public;
    }
}
NGINX_END
nginx -t

echo "[*] Creating kiosk service (cage + Chromium on the HDMI screen)"
cat > /etc/systemd/system/punknuke-kiosk.service <<UNIT_END
[Unit]
Description=PunkNuke display (kiosk browser on HDMI)
After=systemd-user-sessions.service plymouth-quit-wait.service nginx.service punknuke-public.service
Wants=dbus.socket systemd-logind.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=$KUSER
PAMName=login
UtmpIdentifier=tty1
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
ExecStart=/usr/bin/cage -d -- $CHROME --kiosk --ozone-platform=wayland --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble --disable-translate --disable-features=Translate --overscroll-history-navigation=0 --disable-pinch --password-store=basic --check-for-update-interval=31536000 --incognito http://127.0.0.1/kiosk/
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT_END

# Show the new services on the admin page, if it is installed
if [ -f /opt/punknuke/stats.py ]; then
  sed -i 's/^SERVICES = .*/SERVICES = ["dnsmasq", "nginx", "kiwix", "portal-nft", "punknuke-stats", "punknuke-public", "punknuke-kiosk"]/' /opt/punknuke/stats.py
  systemctl restart punknuke-stats || true
fi
if [ -f /var/www/admin/index.html ]; then
  sed -i 's/,"punknuke-game":"Game + scores","punknuke-kiosk":"Touchscreen"}/}/' /var/www/admin/index.html
  grep -q '"punknuke-public"' /var/www/admin/index.html || \
    sed -i 's/"punknuke-stats":"Admin stats"}/"punknuke-stats":"Admin stats","punknuke-public":"Screen stats","punknuke-kiosk":"Back screen"}/' /var/www/admin/index.html
fi
rm -f /var/lib/punknuke/scores.json

systemctl daemon-reload
systemctl disable getty@tty1.service >/dev/null 2>&1 || true
systemctl enable --now punknuke-public
systemctl reload nginx
systemctl enable punknuke-kiosk
systemctl restart punknuke-kiosk

echo "[+] Done. The screen should show the display within a few seconds."
echo "    Preview from another device: http://PunkNuke.local/kiosk/"
