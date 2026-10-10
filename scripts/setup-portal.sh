#!/bin/bash
# PunkNuke captive portal setup
# Usage: sudo bash setup-portal.sh [interface] [ssid]
#   e.g. sudo bash setup-portal.sh wlan1 NEON-NODE
set -e

AP_IF="${1:-wlan0}"
SSID="${2:-NEON-NODE}"
COUNTRY="DK"            # change to your 2-letter Wi-Fi country code if needed
AP_IP="10.42.0.1"
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"

[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
ip link show "$AP_IF" >/dev/null 2>&1 || { echo "Interface $AP_IF not found. Check with: nmcli device"; exit 1; }

if nmcli -t -f DEVICE,STATE device | grep -q "^$AP_IF:connected"; then
  echo "WARNING: $AP_IF is currently connected to a network."
  echo "Turning it into a hotspot will drop that connection (and your SSH session if it runs over $AP_IF)."
  read -rp "Continue? [y/N] " ok; [ "$ok" = "y" ] || exit 1
fi

echo "[*] Installing packages"
apt install -y dnsmasq nginx kiwix-tools tmux

echo "[*] Setting Wi-Fi country to $COUNTRY"
raspi-config nonint do_wifi_country "$COUNTRY"

echo "[*] Configuring dnsmasq (DHCP + catch-all DNS)"
cat > /etc/dnsmasq.d/portal.conf <<EOF
interface=$AP_IF
except-interface=lo
bind-dynamic
no-resolv
no-hosts
dhcp-authoritative
dhcp-range=10.42.0.50,10.42.0.250,255.255.255.0,12h
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP
dhcp-option=114,"http://portal.lan/"
address=/#/$AP_IP
EOF
# Stop dnsmasq from hijacking the Pi's own DNS
grep -q '^DNSMASQ_EXCEPT' /etc/default/dnsmasq 2>/dev/null || echo 'DNSMASQ_EXCEPT="lo"' >> /etc/default/dnsmasq

echo "[*] Configuring nginx (portal + redirect everything else)"
cat > /etc/nginx/sites-available/portal <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    return 302 http://portal.lan/;
}
server {
    listen 80;
    server_name portal.lan 10.42.0.1 punknuke.local;
    root /var/www/portal;
    index index.html;
    location / { try_files $uri $uri/ =404; }
    location /lib/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/portal /etc/nginx/sites-enabled/portal

echo "[*] Creating placeholder portal page"
mkdir -p /var/www/portal
if [ ! -f /var/www/portal/index.html ]; then
cat > /var/www/portal/index.html <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PUNKNUKE // NODE</title>
<style>
body{margin:0;background:#07070c;color:#0ff;font-family:monospace;padding:24px}
h1{color:#f0f;text-shadow:0 0 8px #f0f}
a{display:block;margin:12px 0;padding:14px;border:1px solid #0ff;color:#0ff;text-decoration:none}
a:hover{background:#0ff;color:#000}
</style></head><body>
<h1>&gt; PUNKNUKE_NODE</h1>
<p>OFFLINE ARCHIVE ONLINE. NO NET REQUIRED.</p>
<a href="/lib/">//ACCESS ARCHIVE</a>
<p>Popup window acting up? Open a browser and go to <b>http://portal.lan</b></p>
</body></html>
EOF
fi

echo "[*] Creating kiwix service (runs as $RUN_USER, localhost only)"
cat > /etc/systemd/system/kiwix.service <<EOF
[Unit]
Description=Kiwix offline library
After=network.target
RequiresMountsFor=/mnt/data

[Service]
User=$RUN_USER
ExecStart=/bin/sh -c 'exec /usr/bin/kiwix-serve --address=127.0.0.1 --port=8080 --urlRootLocation=/lib /mnt/data/zim/*.zim'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Auto-restart kiwix whenever a new ZIM lands in /mnt/data/zim
cat > /etc/systemd/system/kiwix-reload.service <<'EOF'
[Unit]
Description=Restart kiwix after library change
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart kiwix.service
EOF
cat > /etc/systemd/system/kiwix-reload.path <<'EOF'
[Path]
PathChanged=/mnt/data/zim
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
nginx -t
systemctl enable --now kiwix.service kiwix-reload.path nginx
systemctl restart nginx

echo "[*] Creating hotspot '$SSID' on $AP_IF"
nmcli con delete portal >/dev/null 2>&1 || true
nmcli con add type wifi ifname "$AP_IF" con-name portal autoconnect yes ssid "$SSID" \
  802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
  ipv4.method manual ipv4.addresses "$AP_IP/24" ipv6.method disabled \
  connection.autoconnect-priority 100

systemctl enable dnsmasq
systemctl restart dnsmasq
nmcli con up portal

echo "[+] Done. Connect a phone to '$SSID' - the portal should pop up."
