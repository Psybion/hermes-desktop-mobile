#!/usr/bin/env bash
set -Eeuo pipefail

HTTPS_PORT=${1:-8457}
WEB_PORT=${2:-${HERMES_DESKTOP_WEB_PORT:-9122}}
[[ "$HTTPS_PORT" =~ ^[0-9]+$ && "$WEB_PORT" =~ ^[0-9]+$ ]] || {
  echo 'usage: expose-tailscale.sh [HTTPS_PORT] [LOCAL_WEB_PORT]' >&2
  exit 1
}
command -v tailscale >/dev/null || { echo 'tailscale is not installed.' >&2; exit 1; }

sudo tailscale serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$WEB_PORT"
sudo tailscale serve status
