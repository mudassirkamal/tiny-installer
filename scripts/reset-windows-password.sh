#!/usr/bin/env bash
#
# reset-windows-password.sh — reset a Windows local account password WITHOUT
# wiping any data. Run this from a RESCUE / LIVE Linux (e.g. Contabo Rescue
# System), NOT from a normal boot. It mounts the Windows disk and clears the
# chosen account's password so you can log in and set a new one.
#
#   bash reset-windows-password.sh                 # list Windows users
#   bash reset-windows-password.sh --user admin558 # clear that user's password
#   bash reset-windows-password.sh --user admin558 --enable   # also unlock/enable
#
# After it runs: boot back into Windows, open the Contabo VNC console, log in
# with an EMPTY password (console logon allows blank), then set a new password:
#     net user admin558 NewClientPass123!
#
set -euo pipefail

USER=""
DO_ENABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user)   USER="$2"; shift 2 ;;
    --enable) DO_ENABLE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
say(){ printf '%s\n' "  $*"; }
die(){ printf '%s\n' "  ${c_r}x $*${c_0}" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root (you are in rescue mode, so: sudo bash ... )."

# --- ensure tools ---
need="chntpw ntfs-3g"
miss=""
for t in chntpw mount.ntfs-3g; do command -v "$t" >/dev/null 2>&1 || miss="yes"; done
if [ -n "$miss" ]; then
  say "${c_c}Installing tools ($need)…${c_0}"
  if   command -v apt-get >/dev/null; then apt-get update -y >/dev/null 2>&1; apt-get install -y $need >/dev/null 2>&1
  elif command -v yum     >/dev/null; then yum install -y epel-release >/dev/null 2>&1; yum install -y chntpw ntfs-3g >/dev/null 2>&1
  elif command -v apk     >/dev/null; then apk add --no-cache chntpw ntfs-3g >/dev/null 2>&1
  fi
fi
command -v chntpw >/dev/null 2>&1 || die "chntpw could not be installed. Install it manually and re-run."

# --- find the Windows partition (the one holding the SAM) ---
say "${c_c}Looking for the Windows partition…${c_0}"
MNT=/mnt/win; mkdir -p "$MNT"
SAMDIR=""
for part in $(lsblk -lnpo NAME,FSTYPE | awk '$2 ~ /ntfs/ {print $1}'); do
  umount "$MNT" 2>/dev/null || true
  if mount -t ntfs-3g -o rw "$part" "$MNT" 2>/dev/null; then
    # Windows folder casing varies; find it case-insensitively
    d=$(find "$MNT" -maxdepth 3 -ipath "*/Windows/System32/config" -type d 2>/dev/null | head -n1)
    if [ -n "$d" ] && [ -f "$d/SAM" ]; then SAMDIR="$d"; WINPART="$part"; break; fi
    umount "$MNT" 2>/dev/null || true
  fi
done
[ -n "$SAMDIR" ] || die "Could not find a Windows install (SAM) on any NTFS partition."
say "${c_g}Found Windows on $WINPART${c_0}  (SAM: $SAMDIR/SAM)"

# --- list users if no --user given ---
if [ -z "$USER" ]; then
  say ""; say "${c_c}Windows local accounts:${c_0}"
  chntpw -l "$SAMDIR/SAM" | sed 's/^/   /'
  umount "$MNT" 2>/dev/null || true
  say ""; say "Re-run with:  bash $0 --user <NAME>"
  exit 0
fi

# --- clear (and optionally enable) the account ---
say "${c_c}Clearing password for '$USER'…${c_0}"
# chntpw user-edit menu: 1=clear password, 2=unlock/enable, q=quit, then y=write
if [ "$DO_ENABLE" = "1" ]; then SEQ=$'1\n2\nq\ny\n'; else SEQ=$'1\nq\ny\n'; fi
printf '%s' "$SEQ" | chntpw -u "$USER" "$SAMDIR/SAM" >/tmp/chntpw.log 2>&1 || true
grep -qi "written\|hive" /tmp/chntpw.log && say "${c_g}Done — password cleared.${c_0}" || { cat /tmp/chntpw.log; die "chntpw did not confirm a write. See log above."; }

sync; umount "$MNT" 2>/dev/null || true

cat <<EOF

  ${c_g}Password reset complete.${c_0} Nothing else was changed; all data is intact.

  Next:
   1. In the Contabo panel, turn OFF Rescue System and reboot into Windows.
   2. Open the Contabo ${c_c}VNC${c_0} console.
   3. At the login screen pick ${c_c}$USER${c_0}, leave the password ${c_c}EMPTY${c_0}, press Enter.
   4. Open Command Prompt and set a new password:
        ${c_c}net user $USER NewClientPass123!${c_0}
   5. Give that new password to your client. Done - no reinstall, no data loss.
EOF
