#!/bin/bash
# PunkNuke: install or update the visitor portal page, logo, icons and the //TOOLS page.
# Usage: sudo bash install-web.sh
set -e
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
SRC="$(dirname "$(readlink -f "$0")")/../web/portal"
[ -f "$SRC/index.html" ] || { echo "[!] Can't find $SRC/index.html"; exit 1; }
mkdir -p /var/www/portal
cp -r "$SRC"/. /var/www/portal/
chmod -R a+rX /var/www/portal
echo "[+] Portal installed in /var/www/portal (no restart needed)"
