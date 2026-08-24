#!/usr/bin/env bash
#
# reset-windows-password.sh - reset a Windows local account password WITHOUT
# wiping data. Run from a RESCUE / LIVE Linux (e.g. Contabo Rescue System).
#
#   bash reset-windows-password.sh                              # list users
#   bash reset-windows-password.sh --user admin558              # clear password (login blank via VNC)
#   bash reset-windows-password.sh --user admin558 --password NewPass123   # set it automatically
#
# --password mode: clears the password, then arms a one-time auto-logon +
# RunOnce that sets your password on the next Windows boot. You just RDP in.
# No VNC needed. Nothing is left behind (the helper self-deletes).
#
set -uo pipefail   # NOTE: no -e, so a package hiccup can't silently abort us

USER=""
PASSWORD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user)     USER="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --enable)   shift ;;                 # kept for compatibility (always enabled now)
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_0=$'\e[0m'
say(){ printf '%s\n' "  $*"; }
die(){ printf '%s\n' "  ${c_r}x $*${c_0}" >&2; umount /mnt/win 2>/dev/null || true; exit 1; }

[ "$(id -u)" = "0" ] || die "Run as root (in rescue mode you already are)."

# --- install tools (tolerant: never abort on a failed package) ---
say "${c_c}Installing tools...${c_0}"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y  >/dev/null 2>&1 || true
  apt-get install -y chntpw ntfs-3g >/dev/null 2>&1 || true
  [ -n "$PASSWORD" ] && apt-get install -y libhivex-bin libwin-hivex-perl >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y epel-release >/dev/null 2>&1 || true
  yum install -y chntpw ntfs-3g hivex >/dev/null 2>&1 || true
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache chntpw ntfs-3g hivex >/dev/null 2>&1 || true
fi
command -v chntpw >/dev/null 2>&1 || die "Could not install chntpw. Try: apt-get install -y chntpw ntfs-3g"

HAVE_HIVEX=0
command -v hivexregedit >/dev/null 2>&1 && HAVE_HIVEX=1

# --- find the Windows partition (the one holding the SAM) ---
say "${c_c}Looking for the Windows partition...${c_0}"
MNT=/mnt/win; mkdir -p "$MNT"
SAMDIR=""; WINPART=""
for part in $(lsblk -lnpo NAME,FSTYPE 2>/dev/null | awk '$2 ~ /ntfs/ {print $1}'); do
  umount "$MNT" 2>/dev/null || true
  if mount -t ntfs-3g -o rw "$part" "$MNT" 2>/dev/null; then
    d=$(find "$MNT" -maxdepth 3 -ipath "*/Windows/System32/config" -type d 2>/dev/null | head -n1)
    if [ -n "$d" ] && [ -f "$d/SAM" ]; then SAMDIR="$d"; WINPART="$part"; break; fi
    umount "$MNT" 2>/dev/null || true
  fi
done
[ -n "$SAMDIR" ] || die "Could not find a Windows install (SAM) on any NTFS partition."
say "${c_g}Found Windows on $WINPART${c_0}"

# --- no --user: just list accounts ---
if [ -z "$USER" ]; then
  say ""; say "${c_c}Windows local accounts:${c_0}"
  chntpw -l "$SAMDIR/SAM" 2>/dev/null | sed 's/^/   /'
  umount "$MNT" 2>/dev/null || true
  say ""; say "Re-run with:  bash $0 --user <NAME> [--password NewPass123]"
  exit 0
fi

# --- always clear + enable the account (works with just chntpw) ---
say "${c_c}Clearing password for '$USER'...${c_0}"
printf '%s' $'1\n2\nq\ny\n' | chntpw -u "$USER" "$SAMDIR/SAM" >/tmp/chntpw.log 2>&1 || true
grep -qi "written\|hive" /tmp/chntpw.log || { cat /tmp/chntpw.log; die "chntpw did not confirm a write."; }
say "${c_g}Password cleared + account enabled.${c_0}"

# --- one-command mode: arm auto set-password (needs hivexregedit) ---
if [ -n "$PASSWORD" ] && [ "$HAVE_HIVEX" = "1" ]; then
  SOFTWARE="$SAMDIR/SOFTWARE"
  if [ -f "$SOFTWARE" ]; then
    say "${c_c}Arming auto set-password on next boot...${c_0}"
    printf '@echo off\r\nnet user "%s" "%s" >"%%SystemDrive%%\\resetpw.log" 2>&1\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v AutoAdminLogon /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DefaultUserName /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v DefaultPassword /f\r\nreg delete "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" /v ForceAutoLogon /f\r\ndel "%%~f0"\r\n' "$USER" "$PASSWORD" > "$MNT/resetpw.cmd"
    cat > /tmp/win.reg <<REG
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="$USER"
"DefaultPassword"=""
"ForceAutoLogon"="1"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"AAResetPwd"="cmd.exe /c \"%SystemDrive%\\resetpw.cmd\""
REG
    if hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$SOFTWARE" < /tmp/win.reg 2>/tmp/hive.log; then
      sync; umount "$MNT" 2>/dev/null || true
      printf '\n  %sArmed.%s All data intact. Now:\n' "$c_g" "$c_0"
      printf '   1. Contabo panel: turn OFF Rescue System and reboot into Windows.\n'
      printf '   2. Wait ~2-3 minutes (it auto-logs in once and sets the password itself).\n'
      printf '   3. RDP in as %s%s%s with the new password:  %s%s%s\n' "$c_c" "$USER" "$c_0" "$c_c" "$PASSWORD" "$c_0"
      printf '  No VNC needed. The helper file deletes itself after running.\n'
      exit 0
    else
      say "${c_y}Could not arm auto set-password (hive write failed); falling back to VNC method.${c_0}"
      cat /tmp/hive.log 2>/dev/null | sed 's/^/     /'
      rm -f "$MNT/resetpw.cmd" 2>/dev/null || true
    fi
  else
    say "${c_y}SOFTWARE hive not found; falling back to VNC method.${c_0}"
  fi
elif [ -n "$PASSWORD" ] && [ "$HAVE_HIVEX" = "0" ]; then
  say "${c_y}'hivexregedit' not available, so auto set-password is off; use the VNC method below.${c_0}"
fi

# --- clear-only fallback: log in blank via VNC, then set a password ---
sync; umount "$MNT" 2>/dev/null || true
printf '\n  %sDone.%s All data intact. Next:\n' "$c_g" "$c_0"
printf '   1. Contabo panel: turn OFF Rescue System, reboot into Windows.\n'
printf '   2. Open the Contabo %sVNC%s console, pick %s%s%s, leave password %sEMPTY%s, Enter.\n' "$c_c" "$c_0" "$c_c" "$USER" "$c_0" "$c_c" "$c_0"
printf '   3. Command Prompt:  %snet user %s NewClientPass123!%s\n' "$c_c" "$USER" "$c_0"
