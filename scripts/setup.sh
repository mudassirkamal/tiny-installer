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
SELF_CONFIRM_WORD="REINSTALL"

# Parse args: first bare word = deploy token; -y/--yes = pre-confirm (no prompt);
# -i=<id> = optional tracking/instance id (accepted for TinyInstaller-style
# commands; the deploy token already drives the /d/<token> status page).
TOKEN=""; PRE_CLI=0; INSTANCE=""
for a in "$@"; do
  case "$a" in
    -y|--yes)  PRE_CLI=1 ;;
    -i=*)      INSTANCE="${a#-i=}" ;;
    -*)        : ;;                       # ignore any other flag
    *)         [ -z "$TOKEN" ] && TOKEN="$a" ;;
  esac
done

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
PRE_CONFIRMED=$(jbool "$CFG" pre_confirmed)
[ "$PRE_CLI" = "1" ] && PRE_CONFIRMED=1     # -y on the command line forces pre-confirm
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
if [ "$FORCE" != "1" ] && [ "$PRE_CONFIRMED" != "1" ]; then
  say ""
  warn "This will irreversibly wipe $DISK and reinstall the OS."
  printf "  Type ${c_red}%s${c_rst} to proceed: " "$SELF_CONFIRM_WORD"
  read -r ANS
  # accept the confirm word in any case (REINSTALL / reinstall)
  ANS_UP=$(printf '%s' "$ANS" | tr '[:lower:]' '[:upper:]')
  [ "$ANS_UP" = "$SELF_CONFIRM_WORD" ] || die "Aborted by operator."
elif [ "$PRE_CONFIRMED" = "1" ]; then
  warn "Pre-confirmed: starting the deployment without asking."
else
  warn "Force mode: skipping confirmation and port checks."
fi

report "start" "Deployment started for $OS_IMAGE on $DISK" "running"
ok "Starting deployment…"
say ""
say "  ${c_grn}Live status page:${c_rst} $API_BASE/d/$TOKEN"
say "  (open it in your browser — close this terminal any time)"
say ""

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
  # NOTE: auto-branding via a confhome reroute is DISABLED — rerouting the
  # engine's config base destabilised the RAM-installer staging (the install
  # fell back to the old OS). Kept here, off, until a safer hook is proven.
  # To (re)enable branding, set BRAND_HOOK=1 in the runner config.
  if [ "${BRAND_HOOK:-0}" = "1" ]; then
    sed -i "s|^confhome=https://raw.githubusercontent.com/bin456789/reinstall/main|confhome=$API_BASE/reinstall-conf|" /tmp/reinstall.sh 2>/dev/null || true
    info "Branding hook: confhome -> $API_BASE/reinstall-conf"
  fi
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
#  PATH B — Pre-built (golden) image, written SAFELY via the reinstall engine.
#  The engine boots into a RAM environment first, then writes the image and
#  auto-extends the partition. This is safe (never overwrites the running disk),
#  terminal-independent (you can close the terminal), and works on any disk size.
# ===========================================================================
deploy_dd_image() {
  [ -n "$IMAGE_URL" ] || die "This fast image needs a direct image URL (none configured)."
  fetch_engine
  # Register this deployment's public IP so the first-boot agent (which reports
  # by IP, since we can't inject a token through a RAM-boot deploy) is matched
  # back to this token.
  [ -n "$PUBLIC_IP" ] && report_ip "$PUBLIC_IP"
  report "download" "Writing pre-built image via the reinstall engine (safe RAM boot)" "running"
  info "Deploying image with the reinstall engine — it boots into RAM first, then writes + auto-extends."
  info "Invoking: reinstall.sh dd --img \"$IMAGE_URL\""
  bash /tmp/reinstall.sh dd --img "$IMAGE_URL" || die "Reinstall engine (dd mode) reported an error."
  ok "Image deployment staged. The server will reboot into the installer and write your image."
  info "${c_grn}This now runs on the server itself — you can safely close this terminal and watch the status page:${c_rst}"
  info "${c_grn}  $API_BASE/d/$TOKEN${c_rst}"
  print_connect "Remote Desktop (RDP)"
  report "reboot" "Rebooting into installer to write the image" "running"
  finish_and_reboot
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
  ok "${c_grn}Staged.${c_rst} Rebooting in 10s to run the install in the background (Ctrl-C to cancel)…"
  # NOTE: status is 'installing', NOT 'completed' — the OS only installs AFTER this
  # reboot (10-25 min). The panel flips it to 'online' when the port actually opens.
  report "reboot" "Rebooted into the installer — the OS is now installing in the background" "installing"
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
