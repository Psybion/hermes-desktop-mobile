#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/ownership.sh"
DATA_HOME=$(realpath -m -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_HOME=$(realpath -m -- "${XDG_CONFIG_HOME:-$HOME/.config}")
PREFIX=$(realpath -m -- "${HERMES_DESKTOP_WEB_HOME:-$DATA_HOME/hermes-mobile-desktop}")
SOURCE_ROOT=$(realpath -m -- "${HERMES_SOURCE_ROOT:-$PREFIX/source}")
CONFIG_DIR=$(realpath -m -- "${HERMES_DESKTOP_WEB_CONFIG:-$CONFIG_HOME/hermes-desktop-web}")
UNIT_DIR=$CONFIG_HOME/systemd/user
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
WEB_PORT=${HERMES_DESKTOP_WEB_PORT:-9122}
GATEWAY_PORT=${HERMES_DESKTOP_WEB_GATEWAY_PORT:-9131}
START_SERVICES=1

case ${1:-} in
  '') ;;
  --no-start) START_SERVICES=0 ;;
  -h|--help)
    echo 'usage: ./scripts/install.sh [--no-start]'
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    exit 2
    ;;
esac

for command in git npm node python3 systemctl systemd-analyze caddy; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

if [[ -n ${HERMES_BIN:-} ]]; then
  HERMES_EXECUTABLE=$HERMES_BIN
elif [[ -x "$HERMES_HOME/hermes-agent/venv/bin/hermes" ]]; then
  HERMES_EXECUTABLE=$HERMES_HOME/hermes-agent/venv/bin/hermes
else
  HERMES_EXECUTABLE=$(command -v hermes || true)
fi
[[ -n "$HERMES_EXECUTABLE" && -x "$HERMES_EXECUTABLE" ]] || {
  echo 'Could not locate the Hermes CLI. Set HERMES_BIN to its absolute path.' >&2
  exit 1
}

assert_managed_directory_available "$PREFIX" "$DATA_HOME"
assert_managed_directory_available "$CONFIG_DIR" "$CONFIG_HOME"
require_disjoint_paths "$PREFIX" "$CONFIG_DIR"
require_disjoint_paths "$PREFIX" "$UNIT_DIR"
require_disjoint_paths "$CONFIG_DIR" "$UNIT_DIR"
require_disjoint_paths "$SOURCE_ROOT" "$PREFIX/dist"
assert_unit_path_available "$UNIT_DIR/hermes-desktop-web-gateway.service"
assert_unit_path_available "$UNIT_DIR/hermes-desktop-web.service"
managed_child_path "$SOURCE_ROOT" "$PREFIX" || {
  echo "HERMES_SOURCE_ROOT must be inside the managed package prefix: $PREFIX" >&2
  exit 1
}

claim_managed_directory "$PREFIX" "$DATA_HOME"
claim_managed_directory "$CONFIG_DIR" "$CONFIG_HOME"

SOURCE_CANDIDATE=$(mktemp -d "$PREFIX/.source-candidate.XXXXXX")
cleanup_candidate() {
  if [[ -n ${SOURCE_CANDIDATE:-} && -d $SOURCE_CANDIDATE && ! -L $SOURCE_CANDIDATE ]]; then
    rm -rf -- "$SOURCE_CANDIDATE"
  fi
}
trap cleanup_candidate EXIT

"$ROOT/scripts/prepare_source.sh" "$SOURCE_CANDIDATE"
npm ci --workspace apps/desktop --include-workspace-root --prefix "$SOURCE_CANDIDATE"
npm run build --prefix "$SOURCE_CANDIDATE/apps/desktop"

python3 "$ROOT/scripts/render_config.py" \
  --repo-root "$ROOT" \
  --source-root "$SOURCE_ROOT" \
  --prefix "$PREFIX" \
  --config-dir "$CONFIG_DIR" \
  --unit-dir "$UNIT_DIR" \
  --hermes-home "$HERMES_HOME" \
  --hermes-bin "$HERMES_EXECUTABLE" \
  --caddy-bin "$(command -v caddy)" \
  --web-port "$WEB_PORT" \
  --gateway-port "$GATEWAY_PORT"

systemd-analyze --user verify \
  "$UNIT_DIR/hermes-desktop-web-gateway.service" \
  "$UNIT_DIR/hermes-desktop-web.service"
caddy validate --config "$CONFIG_DIR/Caddyfile" --adapter caddyfile

restore_previous_release() {
  local status=$? had_previous=0 restore_status=0
  trap - ERR
  [[ -n ${MANAGED_TREE_BACKUP:-} ]] && had_previous=1
  echo 'Activation failed; stopping managed services before restoring the previous source.' >&2
  if ! stop_managed_units hermes-desktop-web.service hermes-desktop-web-gateway.service; then
    echo 'Managed services could not be proven inactive; preserving both source trees for recovery.' >&2
    exit "$status"
  fi

  rollback_managed_tree_replacement || restore_status=$?
  systemctl --user daemon-reload || restore_status=$?
  if (( had_previous )); then
    systemctl --user enable hermes-desktop-web-gateway.service hermes-desktop-web.service || restore_status=$?
    require_enabled_units hermes-desktop-web-gateway.service hermes-desktop-web.service || restore_status=$?
    systemctl --user restart hermes-desktop-web-gateway.service hermes-desktop-web.service || restore_status=$?
    require_active_units hermes-desktop-web-gateway.service hermes-desktop-web.service || restore_status=$?
  fi
  (( restore_status == 0 )) || echo 'Previous source was restored, but its services require manual recovery.' >&2
  exit "$status"
}

begin_managed_tree_replacement "$SOURCE_CANDIDATE" "$SOURCE_ROOT" "$PREFIX"
SOURCE_CANDIDATE=
if (( START_SERVICES )); then
  trap restore_previous_release ERR
  systemctl --user daemon-reload
  systemctl --user enable hermes-desktop-web-gateway.service hermes-desktop-web.service
  require_enabled_units hermes-desktop-web-gateway.service hermes-desktop-web.service
  systemctl --user restart hermes-desktop-web-gateway.service hermes-desktop-web.service
  require_active_units hermes-desktop-web-gateway.service hermes-desktop-web.service
  python3 "$ROOT/scripts/verify_runtime.py" \
    --url "http://127.0.0.1:$GATEWAY_PORT" \
    --env-file "$CONFIG_DIR/env" \
    --baseline "$(tr -d '[:space:]' <"$ROOT/patches/BASELINE")"
  trap - ERR
else
  echo 'Configuration verified; services were not loaded or started (--no-start).'
fi
commit_managed_tree_replacement

if (( ! START_SERVICES )); then
  cat <<EOF

Dry-run complete. No service was loaded or started.
Rerun without --no-start to activate the verified configuration.
EOF
  exit 0
fi

cat <<EOF

Hermes Mobile Desktop is listening on http://127.0.0.1:$WEB_PORT.
Keep it loopback-only. To expose it privately over Tailscale HTTPS:

  $ROOT/scripts/expose-tailscale.sh 8457 $WEB_PORT

Then run:

  HERMES_DESKTOP_WEB_URL=https://your-device.your-tailnet.ts.net:8457 npm run qa
EOF
