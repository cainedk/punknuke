#!/bin/bash
# PunkNuke: firewall redirect rules for the hotspot.
# Sends every DNS lookup and every plain-HTTP request from the hotspot to the Pi,
# even when a device uses a hard-coded DNS server or types a raw IP address.
# HTTPS (443) is sent to a closed port so it fails instantly instead of hanging.
# Only traffic arriving on the hotspot interface is touched.
# Usage: sudo bash setup-redirect.sh [interface]
set -e
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
AP_IF="${1:-wlan0}"

apt install -y nftables

cat > /etc/portal.nft <<NFT
table ip portal
delete table ip portal
table ip portal {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$AP_IF" udp dport 53 redirect to :53
    iifname "$AP_IF" tcp dport 53 redirect to :53
    iifname "$AP_IF" tcp dport 80 redirect to :80
    iifname "$AP_IF" tcp dport 443 redirect to :443
  }
}
NFT

cat > /etc/systemd/system/portal-nft.service <<'UNIT'
[Unit]
Description=Captive portal redirect rules
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/portal.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now portal-nft
systemctl restart portal-nft
nft list table ip portal
echo "[+] Redirect rules active on $AP_IF"
