#!/bin/bash
# PunkNuke content downloader - grabs the newest version of each ZIM.
# Run as your normal user (not sudo). Safe to re-run: it skips files you
# already have and resumes interrupted downloads.
# Background run that survives logging out:
#   nohup bash download-content.sh > ~/download.log 2>&1 &

mountpoint -q /mnt/data || { echo "[!] /mnt/data is not mounted - stopping"; exit 1; }

BASE="https://download.kiwix.org/zim"
DEST="/mnt/data/zim"
TMP="/mnt/data/zim-incoming"   # partial files live here so kiwix never sees them
mkdir -p "$DEST" "$TMP"

# folder|filename-prefix  (small + essential first, huge ones last)
LIST=(
  "other|zimgit-post-disaster_en_"
  "other|zimgit-medicine_en_"
  "other|zimgit-water_en_"
  "other|zimgit-food-preparation_en_"
  "other|zimgit-knots_en_"
  "other|mdwiki_en_all_maxi_"
  "ifixit|ifixit_en_all_"
  "stack_exchange|electronics.stackexchange.com_en_all_"
  "stack_exchange|raspberrypi.stackexchange.com_en_all_"
  "stack_exchange|arduino.stackexchange.com_en_all_"
  "stack_exchange|unix.stackexchange.com_en_all_"
  "stack_exchange|askubuntu.com_en_all_"
  "stack_exchange|superuser.com_en_all_"
  "stack_exchange|ham.stackexchange.com_en_all_"
  "stack_exchange|security.stackexchange.com_en_all_"
  "stack_exchange|outdoors.stackexchange.com_en_all_"
  "stack_exchange|sustainability.stackexchange.com_en_all_"
  "stack_exchange|diy.stackexchange.com_en_all_"
  "stack_exchange|cooking.stackexchange.com_en_all_"
  "freecodecamp|freecodecamp_en_all_"
  "wikivoyage|wikivoyage_en_all_maxi_"
  "wiktionary|wiktionary_en_all_nopic_"
  "wikibooks|wikibooks_en_all_maxi_"
  "wikipedia|wikipedia_en_all_maxi_"
)

for entry in "${LIST[@]}"; do
  folder="${entry%%|*}"; prefix="${entry##*|}"
  f=$(curl -sL "$BASE/$folder/" | grep -o "${prefix}[^\"]*\.zim" | sort -u | tail -1)
  if [ -z "$f" ]; then echo "[!] Not found on server: $prefix  (skipping)"; continue; fi
  if [ -f "$DEST/$f" ]; then echo "[=] Already have $f"; continue; fi
  rm -f "$TMP/$f.meta4"   # a stale mirror list blocks resuming
  echo "[>] Downloading $f"
  if aria2c -c -x2 -s2 --max-download-limit=15M --auto-file-renaming=false --summary-interval=60 -d "$TMP" "$BASE/$folder/$f"; then
    mv "$TMP/$f" "$DEST/"
    echo "[+] Added $f to library"
  else
    echo "[!] Failed: $f  (re-run the script to resume)"
  fi
done

echo "[+] All done."
df -h /mnt/data
