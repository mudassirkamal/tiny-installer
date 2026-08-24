#!/usr/bin/env bash
#
# TinyInstaller Panel — deployment runner (setup.sh)
# ---------------------------------------------------------------------------
#  ⚠  DESTRUCTIVE: this reinstalls the operating system on THIS machine.
#     The target disk is wiped. Only run it on a server you own or are
#     authorized to manage. There is no undo.
#
#  Usage:   bash setup.sh <DEPLOYMENT_TOKEN>
#
#  It fetches the deployment config for <DEPLOYMENT_TOKEN> from the panel,
#  then either:
#    • linux  → hands off to the open-source reinstall engine (netboot), or
#    • windows/custom → downloads the image and dd's it onto the boot disk.
# ---------------------------------------------------------------------------
set -u

API_BASE="__API_BASE__"           # injected by the panel when serving this file
TOKEN="${1:-}"
SELF_CONFIRM_WORD="REINSTALL"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
say()  { printf '%s\n' "  $*"; }
info() { printf '%s\n' "  ${c_cyn}»${c_rst} $*"; }
ok()   { printf '%s\n' "  ${c_grn}✓${c_rst} $*"; }
warn() { printf '%s\n' "  ${c_ylw}!${c_rst} $*"; }
die()  { printf '%s\n' "  ${c_red}✗ $*${c_rst}" >&2; report "error" "$*" "failed"; exit 1; }

banner() {
  printf '%s\n' "${c_cyn}"
  cat <<'EOF'
   _____ _            ___           _        _ _
  |_   _(_)_ _ _  _  |_ _|_ _  ___| |_ __ _| | |___ _ _
    | | | | ' \ || |  | || ' \(_-<|  _/ _` | | / -_) '_|
    |_| |_|_||_\_, | |___|_||_/__/ \__\__,_|_|_\___|_|
              |__/            deployment runner
EOF
  printf '%s\n' "${c_rst}"
}

# --- tiny JSON value extractor (falls back when jq is absent) ---------------
have() { command -v "$1" >/dev/null 2>&1; }
jget() { # jget <json> <key>
  if have jq; then printf '%s' "$1" | jq -r ".${2} // empty"; return; fi
  printf '%s' "$1" | grep -o "\"${2}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'
}
jbool() { local v; v=$(jget "$1" "$2"); [ "$v" = "true" ] && echo 1 || echo 0; }
jnum() {
  if have jq; then printf '%s' "$1" | jq -r ".${2} // empty"; return; fi
  printf '%s' "$1" | grep -o "\"${2}\"[[:space:]]*:[[:space:]]*[0-9]*" | head -n1 | grep -o '[0-9]*$'
}

fetch() { # fetch <url>  -> stdout
  if have curl; then curl -fsSL "$1"; elif have wget; then wget -qO- "$1"; else die "need curl or wget"; fi
}
report() { # report <stage> <message> [status]   (best-effort, non-fatal)
  [ -n "$TOKEN" ] || return 0
  local payload
  payload=$(printf '{"stage":"%s","message":"%s","status":"%s"}' "$1" "${2//\"/\'}" "${3:-}")
  if have curl; then curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
      -d "$payload" "$API_BASE/api/deploy/$TOKEN/log" >/dev/null 2>&1 || true
  fi
}
get_public_ip() { # print this server's public IP, best-effort
  local ip u
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ip.sb; do
    if have curl; then ip=$(curl -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]')
    elif have wget; then ip=$(wget -qO- -T 6 "$u" 2>/dev/null | tr -d '[:space:]'); fi
    printf '%s' "$ip" | grep -Eq '^[0-9a-fA-F.:]+$' && { echo "$ip"; return; }
  done
}
report_ip() { # report_ip <ip>
  [ -n "$TOKEN" ] && [ -n "$1" ] && have curl || return 0
  curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    -d "$(printf '{"ip":"%s","stage":"network","message":"Public IP detected"}' "$1")" \
    "$API_BASE/api/deploy/$TOKEN/log" >/dev/null 2>&1 || true
}

# --- preflight --------------------------------------------------------------
banner
[ -n "$TOKEN" ] || die "No deployment token. Usage: bash setup.sh <token>"
[ "$(id -u)" = "0" ] || die "Must run as root (try: sudo bash setup.sh $TOKEN)"

info "Fetching deployment config from panel…"
CFG="$(fetch "$API_BASE/api/deploy/$TOKEN")" || die "Could not reach panel."
[ -n "$CFG" ] || die "Empty config — is the token valid?"

OS_TYPE=$(jget "$CFG" os_type)
OS_IMAGE=$(jget "$CFG" os_image)
METHOD=$(jget "$CFG" method)
IMAGE_URL=$(jget "$CFG" image_url)
REMOTE_PORT=$(jnum "$CFG" remote_port)
USERNAME=$(jget "$CFG" username)
PASSWORD=$(jget "$CFG" password)
MODE=$(jget "$CFG" mode)
FORCE=$(jbool "$CFG" force)
INSTALL_GRUB=$(jbool "$CFG" install_grub)
RESCUE_ENV=$(jbool "$CFG" rescue_env)
CONVERT_GPT=$(jbool "$CFG" convert_gpt)
DISTRO=$(jget "$CFG" distro)
DISTRO_VERSION=$(jget "$CFG" distro_version)
DESKTOP=$(jget "$CFG" desktop)
IMAGE_NAME=$(jget "$CFG" image_name)
ISO_URL=$(jget "$CFG" iso_url)

ok "Token accepted."
PUBLIC_IP=$(get_public_ip)
if [ -n "$PUBLIC_IP" ]; then info "Public IP: ${c_grn}$PUBLIC_IP${c_rst}"; report_ip "$PUBLIC_IP"; fi
say ""
say "  ${c_dim}Deployment plan${c_rst}"
say "  ────────────────────────────────────────────"
printf  "   %-16s %s\n" "OS image:"   "$OS_IMAGE ($OS_TYPE)"
printf  "   %-16s %s\n" "Method:"     "$METHOD"
[ -n "$IMAGE_URL" ] && printf "   %-16s %s\n" "Image URL:" "$IMAGE_URL"
printf  "   %-16s %s\n" "Remote port:" "$REMOTE_PORT"
printf  "   %-16s %s\n" "Username:"    "$USERNAME"
printf  "   %-16s %s\n" "Mode:"        "$MODE"
printf  "   %-16s %s\n" "Options:"     "grub=$INSTALL_GRUB gpt=$CONVERT_GPT rescue=$RESCUE_ENV force=$FORCE"
say "  ────────────────────────────────────────────"
say ""

# --- target disk detection --------------------------------------------------
detect_disk() {
  local d
  d=$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1; exit}')
  [ -n "$d" ] && { echo "/dev/$d"; return; }
  for c in /dev/vda /dev/sda /dev/nvme0n1 /dev/xvda; do [ -b "$c" ] && { echo "$c"; return; }; done
}
DISK=$(detect_disk)
[ -n "$DISK" ] || die "Could not detect a target disk."
warn "Target disk: ${c_red}$DISK${c_rst} — ALL DATA ON IT WILL BE ERASED."

# --- confirmation -----------------------------------------------------------
if [ "$FORCE" != "1" ]; then
  say ""
  warn "This will irreversibly wipe $DISK and reinstall the OS."
  printf "  Type ${c_red}%s${c_rst} to proceed: " "$SELF_CONFIRM_WORD"
  read -r ANS
  [ "$ANS" = "$SELF_CONFIRM_WORD" ] || die "Aborted by operator."
else
  warn "Force mode: skipping confirmation and port checks."
fi

report "start" "Deployment started for $OS_IMAGE on $DISK" "running"
ok "Starting deployment…"

# --- dependency check -------------------------------------------------------
ensure_tools() {
  for t in "$@"; do have "$t" || MISSING="$MISSING $t"; done
  if [ -n "${MISSING:-}" ]; then
    info "Installing tools:$MISSING"
    if have apt-get; then apt-get update -y >/dev/null 2>&1; apt-get install -y $MISSING >/dev/null 2>&1
    elif have yum; then yum install -y $MISSING >/dev/null 2>&1
    elif have apk; then apk add --no-cache $MISSING >/dev/null 2>&1; fi
  fi
}

# The reinstall engine (bin456789/reinstall): reinstalls Linux *and* Windows on a
# running server. Downloaded fresh each run so upstream fixes apply.
REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
fetch_engine() {
  ensure_tools curl
  info "Downloading reinstall engine…"
  report "download" "Fetching reinstall engine" "running"
  curl -fsSL -o /tmp/reinstall.sh "$REINSTALL_URL" \
    || wget -qO /tmp/reinstall.sh "$REINSTALL_URL" \
    || die "Failed to download reinstall engine."
  ok "Engine ready."
}

# ===========================================================================
#  PATH A — Linux (Debian/Ubuntu/Alpine/Rocky/…) via the reinstall engine
# ===========================================================================
deploy_reinstall_linux() {
  [ -n "$DISTRO" ] || DISTRO="${OS_IMAGE%%-*}"
  [ -n "$DISTRO_VERSION" ] || DISTRO_VERSION="${OS_IMAGE#*-}"
  fetch_engine
  report "reinstall" "Installing $DISTRO $DISTRO_VERSION" "running"
  local args=("$DISTRO")
  [ -n "$DISTRO_VERSION" ] && args+=("$DISTRO_VERSION")
  args+=(--password "$PASSWORD" --ssh-port "$REMOTE_PORT")
  info "Invoking: reinstall.sh ${args[*]}"
  bash /tmp/reinstall.sh "${args[@]}" || die "Reinstall engine reported an error."
  if [ -n "$DESKTOP" ]; then
    info "Desktop '$DESKTOP' requested — it will be installed on first boot via init script."
  fi
  ok "Linux install staged. The server will reboot into the installer."
  print_connect "SSH"
  report "reboot" "Rebooting into installer" "running"
  finish_and_reboot
}

# ===========================================================================
#  PATH B — Windows (Server / LTSC / desktop) via the reinstall engine.
#  Installs from a Microsoft ISO with VirtIO drivers + unattended setup
#  (admin password + RDP). This is the real Windows-on-Linux-VPS path.
# ===========================================================================
deploy_reinstall_windows() {
  [ -n "$IMAGE_NAME" ] || die "No Windows edition (image name) configured for this image."
  fetch_engine
  report "reinstall" "Installing Windows: $IMAGE_NAME" "running"
  local args=(windows --image-name "$IMAGE_NAME" --password "$PASSWORD" --rdp-port "$REMOTE_PORT")
  [ -n "$ISO_URL" ]  && args+=(--iso "$ISO_URL")
  [ -n "$USERNAME" ] && args+=(--username "$USERNAME")
  info "Invoking: reinstall.sh windows --image-name \"$IMAGE_NAME\" --rdp-port $REMOTE_PORT …"
  [ -z "$ISO_URL" ] && warn "No ISO URL set — the engine will try to resolve one; provide an Image URL if it fails."
  bash /tmp/reinstall.sh "${args[@]}" || die "Reinstall engine reported an error."
  ok "Windows install staged. The server will reboot and install Windows unattended."
  info "First boot can take 10–25 min while Windows sets up and enables RDP."
  print_connect "Remote Desktop (RDP)"
  report "reboot" "Rebooting to install Windows" "running"
  finish_and_reboot
}

# ===========================================================================
#  PATH B — Windows / custom raw image, written with dd
# ===========================================================================
deploy_dd_image() {
  [ -n "$IMAGE_URL" ] || die "This image requires a direct .img/.gz/.zip/.iso URL (none provided)."
  ensure_tools curl gzip
  info "Streaming image to $DISK (this can take a while)…"
  report "download" "Writing image to $DISK" "running"

  # Choose a decompressor based on the URL/extension and stream straight to dd.
  case "$IMAGE_URL" in
    *.gz)        curl -fL "$IMAGE_URL" | gunzip -c | dd of="$DISK" bs=4M conv=fsync status=progress ;;
    *.xz)        ensure_tools xz; curl -fL "$IMAGE_URL" | xz -dc | dd of="$DISK" bs=4M conv=fsync status=progress ;;
    *.zip)       ensure_tools funzip; curl -fL "$IMAGE_URL" | funzip | dd of="$DISK" bs=4M conv=fsync status=progress ;;
    *.img|*.iso|*.raw) curl -fL "$IMAGE_URL" | dd of="$DISK" bs=4M conv=fsync status=progress ;;
    *)           curl -fL "$IMAGE_URL" | dd of="$DISK" bs=4M conv=fsync status=progress ;;
  esac || die "Image write failed."
  sync
  ok "Image written to $DISK."

  if [ "$CONVERT_GPT" = "1" ]; then
    info "Ensuring GPT partition table on UEFI…"
    have sgdisk && sgdisk -g "$DISK" >/dev/null 2>&1 || warn "sgdisk not available; skipped MBR→GPT."
  fi
  if [ "$INSTALL_GRUB" = "1" ]; then
    info "Installing GRUB as primary bootloader…"
    ensure_tools grub2-install
    if have grub-install; then grub-install "$DISK" >/dev/null 2>&1 || warn "grub-install returned non-zero."
    elif have grub2-install; then grub2-install "$DISK" >/dev/null 2>&1 || warn "grub2-install returned non-zero."
    else warn "GRUB not found; relying on image's own bootloader."; fi
  fi

  ok "Windows/custom image deployed."
  inject_firstboot
  print_connect "Remote Desktop (RDP)"
  report "done" "Image deployed; first-boot agent will set the password and report back" "running"
  finish_and_reboot
}

# Write the first-boot config onto the just-dd'd Windows disk so the baked-in
# agent can set a random password + RDP port and report them to the panel.
inject_firstboot() {
  ensure_tools ntfs-3g
  local mnt=/mnt/tiwin; mkdir -p "$mnt"
  local part
  for part in $(lsblk -lnpo NAME,FSTYPE 2>/dev/null | awk '$2 ~ /ntfs/ {print $1}'); do
    umount "$mnt" 2>/dev/null || true
    ntfsfix -d "$part" >/dev/null 2>&1 || true
    if mount -t ntfs-3g -o rw,remove_hiberfile,force "$part" "$mnt" 2>/dev/null; then
      if find "$mnt" -maxdepth 2 -ipath "*/Windows/System32" -type d 2>/dev/null | grep -q .; then
        printf '{"panel":"%s","token":"%s","port":%s,"user":"%s"}' \
          "$API_BASE" "$TOKEN" "${REMOTE_PORT:-22}" "${USERNAME:-administrator}" > "$mnt/ti-firstboot.json"
        sync; umount "$mnt" 2>/dev/null || true
        ok "First-boot agent armed (it will set the password + report on first boot)."
        return 0
      fi
      umount "$mnt" 2>/dev/null || true
    fi
  done
  warn "Could not find the Windows partition to arm the first-boot agent."
}

print_connect() { # print_connect <protocol label>
  say ""
  say "  ${c_dim}After install, connect via $1:${c_rst}"
  printf "   %-12s %s\n" "Host:" "${PUBLIC_IP:-<this server public IP>}"
  printf "   %-12s %s\n" "Port:" "$REMOTE_PORT"
  printf "   %-12s %s\n" "User:" "$USERNAME"
  printf "   %-12s %s\n" "Pass:" "$PASSWORD"
}

finish_and_reboot() {
  say ""
  ok "${c_grn}Deployment complete.${c_rst} Rebooting in 10s (Ctrl-C to cancel)…"
  report "reboot" "Rebooting now" "completed"
  sleep 10
  ( sleep 2; reboot -f 2>/dev/null || reboot ) &
  exit 0
}

# --- dispatch ---------------------------------------------------------------
# A per-deploy raw image URL (.img/.gz/.raw) always means "dd this image".
# Otherwise use the reinstall engine for the OS type.
case "$METHOD" in
  dd)
    deploy_dd_image ;;
  reinstall)
    case "$OS_TYPE" in
      windows) deploy_reinstall_windows ;;
      linux)   deploy_reinstall_linux ;;
      custom)  deploy_dd_image ;;
      *)       die "Unknown os_type '$OS_TYPE'." ;;
    esac ;;
  *)
    # Fallback by os_type
    case "$OS_TYPE" in
      windows) deploy_reinstall_windows ;;
      linux)   deploy_reinstall_linux ;;
      *)       deploy_dd_image ;;
    esac ;;
esac
