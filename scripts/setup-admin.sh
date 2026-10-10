#!/bin/bash
# PunkNuke admin dashboard setup
# Usage: sudo bash setup-admin.sh
# Installs: a small stats API (localhost only), the admin page at /admin/,
# and a password on it. Re-run any time to change the password or update files.
set -e
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }

# ---------- password ----------
read -rp "Admin username [admin]: " AU; AU=${AU:-admin}
while :; do
  read -rsp "Admin password: " P1; echo
  read -rsp "Repeat password: " P2; echo
  [ -n "$P1" ] && [ "$P1" = "$P2" ] && break
  echo "Passwords empty or don't match, try again."
done
printf '%s:%s\n' "$AU" "$(openssl passwd -apr1 "$P1")" > /etc/nginx/punknuke.htpasswd
chown root:www-data /etc/nginx/punknuke.htpasswd
chmod 640 /etc/nginx/punknuke.htpasswd

mkdir -p /opt/punknuke /var/www/admin

# ---------- stats API ----------
cat > /opt/punknuke/stats.py <<'PY_END'
#!/usr/bin/env python3
"""PunkNuke admin stats API. Listens on localhost only; nginx serves it at /admin/api/."""
import json, os, re, shutil, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IFACE = "wlan0"
LEASES = "/var/lib/misc/dnsmasq.leases"
DATA = "/mnt/data"
SERVICES = ["dnsmasq", "nginx", "kiwix", "portal-nft", "punknuke-stats", "punknuke-public", "punknuke-kiosk"]
_prev = {}

def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return ""

def cpu():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    idle, total = v[3] + v[4], sum(v)
    p = _prev.get("cpu"); _prev["cpu"] = (idle, total)
    pct = 0.0
    if p and total > p[1]:
        pct = 100.0 * (1 - (idle - p[0]) / (total - p[1]))
    try:
        temp = int(open("/sys/class/thermal/thermal_zone0/temp").read()) / 1000
    except Exception:
        temp = None
    return {"pct": round(max(0.0, pct), 1), "temp": temp}

def mem():
    m = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":", 1)
        m[k] = int(v.split()[0]) * 1024
    return {"total": m["MemTotal"], "avail": m["MemAvailable"]}

def disk(path):
    if path != "/" and not os.path.ismount(path):
        return None
    u = shutil.disk_usage(path)
    return {"total": u.total, "used": u.used}

def power():
    t = re.search(r"0x([0-9a-fA-F]+)", run(["vcgencmd", "get_throttled"]))
    v = re.search(r"=([\d.]+)V", run(["vcgencmd", "pmic_read_adc", "EXT5V_V"]))
    return {"throttled": int(t.group(1), 16) if t else 0,
            "volts": round(float(v.group(1)), 2) if v else None}

def net():
    base = f"/sys/class/net/{IFACE}/statistics/"
    try:
        rx = int(open(base + "rx_bytes").read()); tx = int(open(base + "tx_bytes").read())
    except Exception:
        return {"rx_rate": 0, "tx_rate": 0}
    now = time.time(); p = _prev.get("net"); _prev["net"] = (now, rx, tx)
    if not p or now <= p[0]:
        return {"rx_rate": 0, "tx_rate": 0}
    dt = now - p[0]
    return {"rx_rate": max(0, (rx - p[1]) / dt), "tx_rate": max(0, (tx - p[2]) / dt)}

def clients():
    leases = {}
    try:
        for line in open(LEASES):
            p = line.split()
            if len(p) >= 4:
                leases[p[1].lower()] = {"ip": p[2], "name": "" if p[3] == "*" else p[3]}
    except OSError:
        pass
    out, cur = [], None
    for line in run(["iw", "dev", IFACE, "station", "dump"]).splitlines():
        m = re.match(r"Station ([0-9a-fA-F:]{17})", line)
        if m:
            mac = m.group(1).lower()
            cur = {"mac": mac, "ip": "?", "name": "", **leases.get(mac, {})}
            out.append(cur)
            continue
        if cur is None:
            continue
        k, _, v = line.strip().partition(":")
        v = v.strip()
        try:
            if k == "signal": cur["signal"] = int(v.split()[0])
            elif k == "connected time": cur["connected"] = int(v.split()[0])
            elif k == "rx bytes": cur["rx"] = int(v)
            elif k == "tx bytes": cur["tx"] = int(v)
        except (ValueError, IndexError):
            pass
    return out

def services():
    out = run(["systemctl", "is-active", *SERVICES]).split()
    return {s: (out[i] if i < len(out) else "unknown") for i, s in enumerate(SERVICES)}

def library():
    count, dl = 0, []
    if os.path.ismount(DATA):
        try:
            count = sum(1 for f in os.listdir(os.path.join(DATA, "zim")) if f.endswith(".zim"))
        except OSError:
            pass
        try:
            dl = sorted(f for f in os.listdir(os.path.join(DATA, "zim-incoming")) if f.endswith(".zim"))
        except OSError:
            pass
    return {"count": count, "downloading": dl}

def stats():
    return {
        "uptime": float(open("/proc/uptime").read().split()[0]),
        "load": list(os.getloadavg()),
        "cpu": cpu(), "mem": mem(),
        "disks": {"system": disk("/"), "data": disk(DATA)},
        "power": power(), "net": net(), "clients": clients(),
        "services": services(), "library": library(),
    }

class Handler(BaseHTTPRequestHandler):
    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/stats"):
            self.send(200, stats())
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/power" or self.headers.get("X-Admin") != "1":
            return self.send(403, {"error": "forbidden"})
        n = int(self.headers.get("Content-Length") or 0)
        try:
            action = json.loads(self.rfile.read(n) or b"{}").get("action")
        except ValueError:
            action = None
        cmd = {"shutdown": "poweroff", "reboot": "reboot"}.get(action)
        if not cmd:
            return self.send(400, {"error": "unknown action"})
        subprocess.Popen(["sh", "-c", f"sleep 2; systemctl {cmd}"])
        self.send(200, {"ok": True, "action": action})

    def log_message(self, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", 8090), Handler).serve_forever()
PY_END

cat > /etc/systemd/system/punknuke-stats.service <<'UNIT_END'
[Unit]
Description=PunkNuke admin stats API
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/punknuke/stats.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_END

# ---------- admin page ----------
cat > /var/www/admin/index.html <<'HTML_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>PunkNuke admin</title>
<meta name="theme-color" content="#0b0d1c">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
:root{--void:#0b0d1c;--panel:#13162b;--line:#262a48;--amber:#ffa733;--pink:#ff3dbb;--cyan:#3ef0ff;--ok:#5dffb0;--dim:#8a8fb0;--text:#e3e6f5;
--mono:ui-monospace,"SF Mono",Menlo,Consolas,"Roboto Mono","Liberation Mono",monospace;
--cond:"sans-serif-condensed","Roboto Condensed","Arial Narrow","Helvetica Neue",Arial,sans-serif}
*{box-sizing:border-box}
html,body{margin:0;background:var(--void);color:var(--text);font-family:var(--mono);font-size:14px;line-height:1.45;overflow-x:hidden;-webkit-text-size-adjust:100%}
.wrap{max-width:1200px;margin:0 auto;padding:16px 16px 40px}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap;border-bottom:1px solid var(--line);padding-bottom:12px}
h1{margin:0;font-family:var(--cond);font-stretch:condensed;font-weight:900;font-size:clamp(2rem,7vw,3.2rem);line-height:.9;text-transform:uppercase}
.brand{display:flex;align-items:center;gap:12px}
.brand img{width:56px;height:56px;flex:none}
.tagline{color:var(--cyan);font-size:12px;margin-top:4px}
.meta{color:var(--dim);font-size:12px;text-align:right}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--dim);margin-right:6px;vertical-align:middle}
.dot.ok{background:var(--ok);box-shadow:0 0 6px var(--ok)}
.dot.bad{background:var(--pink);box-shadow:0 0 6px var(--pink)}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));margin-top:16px}
.tile{background:var(--panel);border:1px solid var(--line);border-top:2px solid var(--amber);padding:14px;min-width:0}
.tile.warn{border-top-color:var(--pink)}
.tile h2{margin:0 0 8px;font-size:12px;font-weight:400;color:var(--dim)}
.big{font-family:var(--cond);font-stretch:condensed;font-weight:800;font-size:2.6rem;line-height:1}
.tile.warn .big{color:var(--pink)}
.sub{color:var(--dim);font-size:12px;margin-top:6px;overflow-wrap:anywhere}
.bar{height:6px;background:var(--line);margin-top:10px}
.bar i{display:block;height:100%;width:0;background:var(--amber);transition:width .4s}
.tile.warn .bar i{background:var(--pink)}
svg.spark{display:block;width:100%;height:40px;margin-top:10px}
section{margin-top:26px}
section h3{font-family:var(--cond);font-stretch:condensed;font-weight:800;font-size:1.6rem;margin:0 0 10px;color:var(--cyan)}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip{border:1px solid var(--line);padding:8px 12px;background:var(--panel)}
.scroll{overflow-x:auto;border:1px solid var(--line)}
table{width:100%;border-collapse:collapse;min-width:620px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--dim);font-weight:400;font-size:12px;background:var(--panel)}
.num{text-align:right}
td.empty{color:var(--dim)}
.actions{display:flex;gap:10px;flex-wrap:wrap}
button{font:inherit;padding:14px 20px;min-height:48px;border:1px solid var(--amber);background:transparent;color:var(--amber);cursor:pointer}
button.danger{border-color:var(--pink);color:var(--pink)}
button:active{background:var(--amber);color:var(--void)}
button.danger:active{background:var(--pink)}
button:disabled{opacity:.4;cursor:not-allowed}
:focus-visible{outline:2px solid var(--pink);outline-offset:3px}
#notice{margin-top:10px;color:var(--pink);min-height:1.4em}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
</head>
<body>
<div class="wrap">
<header>
  <div class="brand"><img src="/icon-192.png" alt="" width="56" height="56"><div><h1>PunkNuke</h1><div class="tagline">Node admin</div></div></div>
  <div class="meta"><div><span class="dot" id="linkdot"></span><span id="link">Connecting…</span></div><div id="uptime"></div></div>
</header>

<div class="grid">
  <div class="tile" id="cpu"><h2>CPU</h2><div class="big" id="cpu-v">–</div><div class="sub" id="cpu-s"></div>
    <svg class="spark" viewBox="0 0 120 40" preserveAspectRatio="none" aria-hidden="true"><polyline id="cpu-line" fill="none" stroke="#ffb547" stroke-width="1.5" vector-effect="non-scaling-stroke" points=""/></svg></div>
  <div class="tile" id="mem"><h2>Memory</h2><div class="big" id="mem-v">–</div><div class="sub" id="mem-s"></div><div class="bar"><i id="mem-bar"></i></div></div>
  <div class="tile" id="data"><h2>Library drive</h2><div class="big" id="data-v">–</div><div class="sub" id="data-s"></div><div class="bar"><i id="data-bar"></i></div></div>
  <div class="tile" id="sys"><h2>System drive</h2><div class="big" id="sys-v">–</div><div class="sub" id="sys-s"></div><div class="bar"><i id="sys-bar"></i></div></div>
  <div class="tile" id="pwr"><h2>Power input</h2><div class="big" id="pwr-v">–</div><div class="sub" id="pwr-s"></div></div>
  <div class="tile" id="cli"><h2>Connected devices</h2><div class="big" id="cli-v">–</div><div class="sub" id="cli-s"></div></div>
</div>

<section><h3>Devices on the hotspot</h3>
  <div class="scroll"><table>
    <thead><tr><th>Name</th><th>IP</th><th>MAC</th><th class="num">Signal</th><th class="num">Connected</th><th class="num">Down / up</th></tr></thead>
    <tbody id="clients"></tbody>
  </table></div>
</section>

<section><h3>Services</h3><div class="chips" id="services"></div></section>

<section><h3>Library</h3><div class="sub" id="lib"></div></section>

<section><h3>Power control</h3>
  <div class="actions"><button id="reboot" type="button">Reboot node</button><button id="shutdown" type="button" class="danger">Shut down node</button></div>
  <div id="notice" aria-live="polite"></div>
</section>
</div>

<script>
const $ = id => document.getElementById(id);
const hist = [];
let busy = false, powering = false;
const LABELS = {"dnsmasq":"DHCP + DNS","nginx":"Web server","kiwix":"Library server","portal-nft":"Redirect rules","punknuke-stats":"Admin stats","punknuke-public":"Screen stats","punknuke-kiosk":"Back screen"};

function bytes(n){
  if (n == null) return "–";
  const u = ["B","KB","MB","GB","TB"]; let i = 0;
  while (n >= 1024 && i < u.length - 1){ n /= 1024; i++; }
  return n.toFixed(n < 10 && i ? 1 : 0) + " " + u[i];
}
function dur(s){
  s = Math.floor(s);
  const d = Math.floor(s/86400), h = Math.floor(s%86400/3600), m = Math.floor(s%3600/60);
  return d ? d+"d "+h+"h" : h ? h+"h "+m+"m" : m+"m "+(s%60)+"s";
}
function tile(id, value, sub, pct, warn){
  $(id+"-v").textContent = value;
  $(id+"-s").textContent = sub;
  const bar = $(id+"-bar");
  if (bar && pct != null) bar.style.width = Math.max(0, Math.min(100, pct)) + "%";
  $(id).classList.toggle("warn", !!warn);
}
function disk(id, d){
  if (!d){ tile(id, "Offline", "Drive not mounted", 0, true); return; }
  const pct = d.used / d.total * 100;
  tile(id, pct.toFixed(0)+"%", bytes(d.total - d.used)+" free of "+bytes(d.total), pct, pct > 90);
}
function powerState(t, v){
  if (t & 0x1) return ["Undervoltage right now", true];
  if (v != null && v < 4.8) return ["Input voltage low, check the powerbank", true];
  if (t & 0xC) return ["Throttling from heat", true];
  if (t & 0x10000) return ["Undervoltage happened since boot", false];
  return ["Power OK", false];
}
function render(s){
  hist.push(s.cpu.pct); if (hist.length > 60) hist.shift();
  $("cpu-line").setAttribute("points", hist.map((v,i) => (i*2).toFixed(1)+","+(40 - v*0.4).toFixed(1)).join(" "));
  const temp = s.cpu.temp != null ? s.cpu.temp.toFixed(0)+"°C. " : "";
  tile("cpu", s.cpu.pct.toFixed(0)+"%", temp+"Load "+s.load.map(x => x.toFixed(2)).join(" "), null, s.cpu.pct > 90 || (s.cpu.temp || 0) > 80);

  const used = s.mem.total - s.mem.avail, mp = used / s.mem.total * 100;
  tile("mem", mp.toFixed(0)+"%", bytes(used)+" of "+bytes(s.mem.total)+" used", mp, mp > 90);

  disk("data", s.disks.data);
  disk("sys", s.disks.system);

  const [msg, bad] = powerState(s.power.throttled || 0, s.power.volts);
  tile("pwr", s.power.volts != null ? s.power.volts.toFixed(2)+" V" : "–", msg, null, bad);

  tile("cli", String(s.clients.length), "Hotspot traffic: "+bytes(s.net.tx_rate)+"/s out, "+bytes(s.net.rx_rate)+"/s in", null, false);

  const tb = $("clients"); tb.replaceChildren();
  if (!s.clients.length){
    const tr = document.createElement("tr"), td = document.createElement("td");
    td.colSpan = 6; td.className = "empty"; td.textContent = "No devices connected.";
    tr.append(td); tb.append(tr);
  }
  s.clients.sort((a,b) => (b.connected||0) - (a.connected||0)).forEach(c => {
    const tr = document.createElement("tr");
    [c.name || "Unknown device", c.ip || "?", c.mac,
     c.signal != null ? c.signal+" dBm" : "–",
     c.connected != null ? dur(c.connected) : "–",
     bytes(c.tx)+" / "+bytes(c.rx)].forEach((v,i) => {
      const td = document.createElement("td"); td.textContent = v;
      if (i >= 3) td.className = "num";
      tr.append(td);
    });
    tb.append(tr);
  });

  const sv = $("services"); sv.replaceChildren();
  for (const [k,v] of Object.entries(s.services)){
    const c = document.createElement("div"), d = document.createElement("span");
    c.className = "chip"; d.className = "dot " + (v === "active" ? "ok" : "bad");
    c.append(d, (LABELS[k] || k) + (v === "active" ? "" : " ("+v+")"));
    sv.append(c);
  }

  let lib = s.library.count + " libraries loaded.";
  if (s.library.downloading.length) lib += " Downloading: " + s.library.downloading.join(", ");
  $("lib").textContent = lib;
  $("uptime").textContent = "Up " + dur(s.uptime);
}
async function poll(){
  if (busy || powering) return;
  busy = true;
  try{
    const r = await fetch("api/stats", {cache:"no-store"});
    if (!r.ok) throw new Error(r.status);
    render(await r.json());
    $("link").textContent = "Live"; $("linkdot").className = "dot ok";
  }catch(e){
    $("link").textContent = "No contact with node"; $("linkdot").className = "dot bad";
  }finally{ busy = false; }
}
function lock(on){ document.querySelectorAll("button").forEach(b => b.disabled = on); }
async function power(action, label){
  if (!confirm(label + "? Everyone connected will lose the portal.")) return;
  try{
    const r = await fetch("api/power", {method:"POST", headers:{"Content-Type":"application/json","X-Admin":"1"}, body:JSON.stringify({action})});
    if (!r.ok) throw new Error(r.status);
    powering = true; lock(true);
    $("link").textContent = "Offline"; $("linkdot").className = "dot bad";
    if (action === "shutdown"){
      $("notice").textContent = "Shutting down. Wait for the green LED to stop blinking before cutting power.";
    } else {
      $("notice").textContent = "Rebooting. Reconnect the tablet to the hotspot, then this page comes back in about a minute.";
      setTimeout(() => { powering = false; lock(false); $("notice").textContent = ""; }, 60000);
    }
  }catch(e){
    $("notice").textContent = "Command failed. The node did not accept it.";
  }
}
$("reboot").addEventListener("click", () => power("reboot", "Reboot the node"));
$("shutdown").addEventListener("click", () => power("shutdown", "Shut down the node"));
poll(); setInterval(poll, 2000);
</script>
</body>
</html>
HTML_END

# ---------- nginx ----------
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

systemctl daemon-reload
systemctl enable --now punknuke-stats
systemctl restart punknuke-stats
nginx -t
systemctl reload nginx

echo "[+] Admin ready at http://portal.lan/admin/  (user: $AU)"
