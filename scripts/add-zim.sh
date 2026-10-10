#!/bin/bash
# Find, download and add a ZIM library by keyword, and keep it in download-content.sh.
# Usage:   bash add-zim.sh <keyword> [kiwix folder ...]
# Example: bash add-zim.sh factbook
#          bash add-zim.sh wikem other zimit
# Run as your normal user (not sudo). Safe to re-run: resumes partial downloads.
set -e

KW="$1"; shift || true
[ -n "$KW" ] || { echo "Usage: bash add-zim.sh <keyword> [folder ...]"; exit 1; }
FOLDERS="${*:-zimit other}"
BASE="https://download.kiwix.org/zim"
DEST="/mnt/data/zim"
TMP="/mnt/data/zim-incoming"
LIST_SCRIPT="$(dirname "$(readlink -f "$0")")/download-content.sh"
[ -f "$LIST_SCRIPT" ] || LIST_SCRIPT="$HOME/download-content.sh"

mountpoint -q /mnt/data || { echo "[!] /mnt/data is not mounted - stopping"; exit 1; }
mkdir -p "$DEST" "$TMP"

f=""; folder=""
for d in $FOLDERS; do
  all=$(curl -sL "$BASE/$d/" | grep -oi "href=\"[^\"/]*${KW}[^\"/]*\.zim\"" | sed 's/^href="//I;s/"$//' | sort -u || true)
  [ -n "$all" ] || continue
  en=$(echo "$all" | grep '_en_' || true)      # prefer the English edition
  [ -n "$en" ] && all="$en"
  echo "[i] Matches in $d/:"; echo "$all" | sed 's/^/      /'
  f=$(echo "$all" | tail -1); folder="$d"
  break
done
[ -n "$f" ] || { echo "[!] Nothing matching '$KW' in: $FOLDERS. Search library.kiwix.org for the right name or folder."; exit 1; }

if [ -f "$DEST/$f" ]; then
  echo "[=] Already have $f"
else
  echo "[>] Downloading $folder/$f"
  rm -f "$TMP/$f.meta4"
  aria2c -c -x2 -s2 --max-download-limit=15M --auto-file-renaming=false --summary-interval=60 -d "$TMP" "$BASE/$folder/$f"
  mv "$TMP/$f" "$DEST/"
  rm -f "$TMP/$f.meta4"
  echo "[+] Added $f to the library (Kiwix picks it up automatically)"
fi

# Remember it, so download-content.sh fetches newer versions later
prefix=$(echo "$f" | sed -E 's/[0-9]{4}-[0-9]{2}\.zim$//')
if [ -f "$LIST_SCRIPT" ] && ! grep -qF "\"$folder|$prefix\"" "$LIST_SCRIPT"; then
  sed -i "0,/^)\$/s//  \"$folder|$prefix\"\n)/" "$LIST_SCRIPT"
  echo "[+] Added \"$folder|$prefix\" to $LIST_SCRIPT"
fi
