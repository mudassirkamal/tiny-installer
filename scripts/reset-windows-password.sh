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
# NTFS often mounts read-only if Windows used fast-startup/hibernation (dirty
# volume). We clear the dirty flag (ntfsfix) and mount with remove_hiberfile,force.
say "${c_c}Looking for the Windows partition...${c_0}"
MNT=/mnt/win; mkdir -p "$MNT"
SAMDIR=""; WINPART=""
for part in $(lsblk -lnpo NAME,FSTYPE 2>/dev/null | awk '$2 ~ /ntfs/ {print $1}'); do
  umount "$MNT" 2>/dev/null || true
  ntfsfix -d "$part" >/dev/null 2>&1 || true      # clear the NTFS dirty flag
  if mount -t ntfs-3g -o rw,remove_hiberfile,force "$part" "$MNT" 2>/dev/null; then
    d=$(find "$MNT" -maxdepth 3 -ipath "*/Windows/System32/config" -type d 2>/dev/null | head -n1)
    if [ -n "$d" ] && [ -f "$d/SAM" ]; then SAMDIR="$d"; WINPART="$part"; break; fi
    umount "$MNT" 2>/dev/null || true
  fi
done
[ -n "$SAMDIR" ] || die "Could not find a Windows install (SAM) on any NTFS partition."
say "${c_g}Found Windows on $WINPART${c_0}"

# --- verify the volume is actually writable (else everything below is a no-op) ---
if ! ( touch "$MNT/.rwtest" 2>/dev/null && rm -f "$MNT/.rwtest" 2>/dev/null ); then
  umount "$MNT" 2>/dev/null || true
  die "Windows partition is read-only (fast-startup/hibernation left it dirty). Fix: in Windows run 'powercfg /h off' before shutting down, or reboot Windows fully once, then retry."
fi

# --- no --user: just list accounts ---
if [ -z "$USER" ]; then
  say ""; say "${c_c}Windows local accounts:${c_0}"
  chntpw -l "$SAMDIR/SAM" 2>/dev/null | sed 's/^/   /'
  umount "$MNT" 2>/dev/null || true
  say ""; say "Re-run with:  bash $0 --user <NAME> [--password NewPass123]"
  exit 0
fi

if [ -n "$PASSWORD" ]; then
  SYS32=$(dirname "$SAMDIR")   # <win>/Windows/System32 (correct case)

  # (A) UNIVERSAL, RELIABLE: a Group Policy machine startup script. Windows runs
  #     it as SYSTEM at the next boot and executes `net user` INSIDE Windows.
  #     This is file-based (gpt.ini/scripts.ini/.bat) — not an offline SAM edit —
  #     which is exactly why it works where chntpw does not. It's also the same
  #     mechanism the reinstall engine itself uses for post-install scripts.
  say "${c_c}Arming a boot-time password set (GPO startup script)...${c_0}"
  {
    printf '@echo off\r\n'
    printf 'net user "%s" "%s"\r\n' "$USER" "$PASSWORD"
    printf 'net user "%s" /active:yes\r\n' "$USER"
    printf 'del "%%~f0"\r\n'
  } > "$MNT/ti-resetpw.bat"
  GP="$SYS32/GroupPolicy"; SCR="$GP/Machine/Scripts"; mkdir -p "$SCR"
  # bump gpt.ini Version so the GPO client re-processes the startup scripts
  oldv=$(grep -Ei '^Version=' "$GP/gpt.ini" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
  newv=$(( ${oldv:-0} + 1 ))
  {
    printf '[General]\r\n'
    printf 'gPCFunctionalityVersion=2\r\n'
    printf 'gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]\r\n'
    printf 'Version=%s\r\n' "$newv"
  } > "$GP/gpt.ini"
  INI="$SCR/scripts.ini"
  grep -qi '\[Startup\]' "$INI" 2>/dev/null || printf '[Startup]\r\n' > "$INI"
  num=$(grep -Eoi '^[0-9]+CmdLine' "$INI" 2>/dev/null | grep -Eo '^[0-9]+' | sort -n | tail -1)
  if [ -z "$num" ]; then num=0; else num=$((num+1)); fi
  { printf '%sCmdLine=%%SystemDrive%%\\ti-resetpw.bat\r\n' "$num"; printf '%sParameters=\r\n' "$num"; } >> "$INI"
  say "${c_g}GPO startup script armed (runs on next boot).${c_0}"

  # (B) Fomze images also carry the TIResetWatch task -> drop its trigger file too
  mkdir -p "$MNT/ti-reset" 2>/dev/null && printf '%s' "$PASSWORD" > "$MNT/ti-reset/newpass.txt" 2>/dev/null || true
else
  # No new password: just clear it (log in blank), best-effort via chntpw
  say "${c_c}Clearing password for '$USER'...${c_0}"
  printf '%s' $'1\n2\nq\ny\n' | chntpw -u "$USER" "$SAMDIR/SAM" >/tmp/chntpw.log 2>&1 || true
  grep -qi "written\|hive" /tmp/chntpw.log && say "${c_g}Password cleared.${c_0}" || say "${c_y}chntpw did not confirm a write.${c_0}"
fi

sync; umount "$MNT" 2>/dev/null || true
printf '\n  %sDone.%s All data intact. Now: turn OFF Rescue System and reboot into Windows.\n' "$c_g" "$c_0"
if [ -n "$PASSWORD" ]; then
  printf '   Wait ~1-2 min for the boot script to run, then RDP in as %s%s%s with:  %s%s%s\n' "$c_c" "$USER" "$c_0" "$c_c" "$PASSWORD" "$c_0"
else
  printf '   VNC in, pick %s%s%s, leave password %sEMPTY%s, then set one:  %snet user %s NewPass123!%s\n' "$c_c" "$USER" "$c_0" "$c_c" "$c_0" "$c_c" "$USER" "$c_0"
fi
