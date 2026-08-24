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
PASSWORD=""
DO_ENABLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user)     USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --enable)   DO_ENABLE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
say(){ printf '%s\n' "  $*"; }
die(){ printf '%s\n' "  ${c_r}x $*${c_0}" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root (you are in rescue mode, so: sudo bash ... )."

# --- ensure tools ---
# hivexregedit is only needed for the one-command --password mode
need="chntpw ntfs-3g libhivex-bin libwin-hivex-perl"
say "${c_c}Installing tools…${c_0}"
if   command -v apt-get >/dev/null; then apt-get update -y >/dev/null 2>&1; apt-get install -y $need >/dev/null 2>&1
elif command -v yum     >/dev/null; then yum install -y epel-release >/dev/null 2>&1; yum install -y chntpw ntfs-3g hivex >/dev/null 2>&1
elif command -v apk     >/dev/null; then apk add --no-cache chntpw ntfs-3g hivex >/dev/null 2>&1
fi
command -v chntpw >/dev/null 2>&1 || die "chntpw could not be installed. Install it manually and re-run."
if [ -n "$PASSWORD" ] && ! command -v hivexregedit >/dev/null 2>&1; then
  die "Need 'hivexregedit' for --password mode. Install: apt-get install -y libwin-hivex-perl"
fi

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

# --- always clear the current password (+enable) so the account is usable ---
say "${c_c}Clearing password for '$USER'…${c_0}"
# chntpw user-edit menu: 1=clear password, 2=unlock/enable, q=quit, then y=write
printf '%s' $'1\n2\nq\ny\n' | chntpw -u "$USER" "$SAMDIR/SAM" >/tmp/chntpw.log 2>&1 || true
grep -qi "written\|hive" /tmp/chntpw.log || { cat /tmp/chntpw.log; die "chntpw did not confirm a write. See log above."; }
say "${c_g}Password cleared + account enabled.${c_0}"

if [ -z "$PASSWORD" ]; then
  # ---- clear-only mode: log in blank via VNC, then set a password ----
  sync; umount "$MNT" 2>/dev/null || true
  cat <<EOF

  ${c_g}Done.${c_0} All data intact. Next:
   1. Contabo panel: turn OFF Rescue System, reboot into Windows.
   2. Open the Contabo ${c_c}VNC${c_0} console, pick ${c_c}$USER${c_0}, leave password ${c_c}EMPTY${c_0}, Enter.
   3. Command Prompt:  ${c_c}net user $USER NewClientPass123!${c_0}
   (Tip: run with --password to skip VNC and set it automatically.)
EOF
  exit 0
fi

# ---- one-command mode: set the password automatically on next boot ----
# Mechanism: temporary auto-logon (blank) + a RunOnce batch that sets the real
# password and removes auto-logon. You just RDP in afterward. No VNC needed.
say "${c_c}Arming auto set-password on next boot…${c_0}"
WINROOT="$MNT"
SOFTWARE="$SAMDIR/SOFTWARE"
[ -f "$SOFTWARE" ] || die "SOFTWARE hive not found next to SAM."

# 1) drop a self-deleting batch file at the root of the Windows drive (C:\)
printf '@echo off\r\nnet user "%s" "%s" >"%%SystemDrive%%\\resetpw.log" 2>&1\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v AutoAdminLogon /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DefaultUserName /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DefaultPassword /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v ForceAutoLogon /f\r\ndel "%%~f0"\r\n' "$USER" "$PASSWORD" > "$WINROOT/resetpw.cmd"

# 2) set auto-logon (blank) + RunOnce to call the batch, via hivexregedit merge
cat > /tmp/win.reg <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="__USER__"
"DefaultPassword"=""
"ForceAutoLogon"="1"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"AAResetPwd"="cmd.exe /c \"%SystemDrive%\\resetpw.cmd\""
REG
sed -i "s/__USER__/$USER/" /tmp/win.reg
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$SOFTWARE" < /tmp/win.reg \
  || die "Failed to write auto-logon settings into the SOFTWARE hive."

sync; umount "$MNT" 2>/dev/null || true
cat <<EOF

  ${c_g}Armed.${c_0} All data intact. Now:
   1. Contabo panel: turn OFF Rescue System and reboot into Windows.
   2. Wait ~2-3 minutes (it auto-logs in once and sets the password by itself).
   3. RDP in as ${c_c}$USER${c_0} with the new password:  ${c_c}$PASSWORD${c_0}
  No VNC needed. The helper file deletes itself after running.
EOF
