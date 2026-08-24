#!/usr/bin/env bash
#
# capture-image.sh — capture a prepared disk into a compressed raw image
# for FAST (dd-based) deployments.
#
# Run this from a RESCUE / LIVE Linux environment (NOT from inside Windows),
# after you have installed + customized + sysprepped Windows and shut it down.
# It reads the boot disk block-by-block, compresses it, and (optionally)
# uploads it to your file host.
#
#   bash capture-image.sh                         # writes ./image.img.gz
#   bash capture-image.sh --disk /dev/sda         # pick the disk explicitly
#   bash capture-image.sh --out ws2022.img.gz     # choose output name
#   bash capture-image.sh --upload "https://user:pass@host/upload/ws2022.img.gz"
#
set -euo pipefail

DISK=""
OUT="image.img.gz"
UPLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)   DISK="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --upload) UPLOAD="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# auto-detect the boot disk if not given
if [ -z "$DISK" ]; then
  DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
fi
[ -b "$DISK" ] || { echo "Disk $DISK not found. Pass --disk /dev/sdX"; exit 1; }

echo "About to read $DISK and compress it to $OUT."
echo "Make sure Windows was sysprepped (generalized) and is powered off."
read -rp "Type YES to continue: " ans
[ "$ans" = "YES" ] || { echo "Aborted."; exit 1; }

command -v pigz >/dev/null 2>&1 && GZ="pigz" || GZ="gzip"   # pigz = multi-core, faster
echo "Reading $DISK → $OUT (using $GZ)…"
dd if="$DISK" bs=4M status=progress | $GZ -c > "$OUT"
sync
echo "Done. Image: $OUT ($(du -h "$OUT" | cut -f1))"

if [ -n "$UPLOAD" ]; then
  echo "Uploading to $UPLOAD …"
  curl -f -T "$OUT" "$UPLOAD"
  echo "Uploaded."
fi

cat <<EOF

Next steps:
  1. Host $OUT somewhere with a DIRECT download link (S3, R2, a web server…).
  2. In your panel host, add it to data/images.json, e.g.:
       [{ "id":"ws2022-fast", "type":"windows",
          "label":"Windows Server 2022 (Fast)",
          "imageUrl":"https://your-host/$OUT", "sizeGb":11 }]
  3. Restart the panel. The new "Fast" option appears in the OS dropdown and
     deploys by dd in ~8-12 min.
EOF
