#!/usr/bin/env bash
#
# TinyInstaller Panel — one-command deploy.
#
#   ./deploy.sh                      # HTTP on port 8787 (Docker if available, else Node/systemd)
#   ./deploy.sh --domain panel.you.com   # automatic HTTPS via Caddy (Docker)
#   ./deploy.sh --port 9000          # custom port (Node mode)
#
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN=""
PORT="8787"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

c_g=$'\e[32m'; c_c=$'\e[36m'; c_y=$'\e[33m'; c_r=$'\e[0m'; c_b=$'\e[1m'
say() { printf '%s\n' "$*"; }
ok()  { printf '%s\n' "  ${c_g}✓${c_r} $*"; }
inf() { printf '%s\n' "  ${c_c}»${c_r} $*"; }

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  elif command -v node >/dev/null 2>&1; then node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
  else head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

# --- .env ------------------------------------------------------------------
if [ ! -f .env ]; then
  inf "Creating .env with a fresh TI_SECRET…"
  SECRET="$(gen_secret)"
  {
    echo "TI_SECRET=$SECRET"
    echo "PORT=$PORT"
    echo "DOMAIN=$DOMAIN"
  } > .env
  ok ".env created."
else
  ok ".env already exists (leaving it as-is)."
  # keep DOMAIN/PORT in sync if passed
  [ -n "$DOMAIN" ] && sed -i.bak "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" .env && rm -f .env.bak || true
fi

PUBIP="$(curl -fsS -m5 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)"

# --- Docker path -----------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  inf "Docker detected — building and starting the panel…"
  if [ -n "$DOMAIN" ]; then
    DOMAIN="$DOMAIN" docker compose --profile tls up -d --build
    URL="https://$DOMAIN"
  else
    docker compose up -d --build
    URL="http://$PUBIP:$PORT"
  fi
  ok "Panel is running in Docker."
elif command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
  inf "Docker (legacy compose) detected — starting…"
  if [ -n "$DOMAIN" ]; then DOMAIN="$DOMAIN" docker-compose --profile tls up -d --build; URL="https://$DOMAIN"
  else docker-compose up -d --build; URL="http://$PUBIP:$PORT"; fi
  ok "Panel is running in Docker."

# --- Node / systemd fallback ----------------------------------------------
elif command -v node >/dev/null 2>&1; then
  inf "Docker not found — using Node.js directly."
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    inf "Installing a systemd service (tinyinstaller-panel)…"
    cat >/etc/systemd/system/tinyinstaller-panel.service <<EOF
[Unit]
Description=TinyInstaller Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
Environment=PORT=$PORT
Environment=TI_SECRET=$TI_SECRET
ExecStart=$(command -v node) server/index.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tinyinstaller-panel
    ok "systemd service started (systemctl status tinyinstaller-panel)."
  else
    inf "Starting in the background with nohup (no systemd/root)…"
    nohup node server/index.js > panel.log 2>&1 &
    ok "Started. Logs: panel.log"
  fi
  URL="http://$PUBIP:$PORT"
else
  say "${c_y}Neither Docker nor Node.js is installed.${c_r}"
  say "Install one of them, then re-run ./deploy.sh"
  say "  Debian/Ubuntu:  apt-get install -y nodejs   (or install Docker)"
  exit 1
fi

# --- Done ------------------------------------------------------------------
say ""
say "${c_b}${c_g}TinyInstaller Panel is deployed.${c_r}"
say "  Open:            ${c_c}$URL${c_r}"
[ -z "$DOMAIN" ] && say "  ${c_y}Tip:${c_r} for HTTPS run:  ./deploy.sh --domain panel.yourdomain.com"
say ""
say "  Next: open the panel, create an account, configure a deployment,"
say "  then run the generated one-liner on your Linux VPS as root."
say ""
