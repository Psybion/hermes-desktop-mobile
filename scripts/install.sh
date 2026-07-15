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

SOURCE_RELATIVE=${SOURCE_ROOT#"$PREFIX"/}
CANDIDATE_ROOT=
if (( START_SERVICES )); then
  mkdir -p -- "$DATA_HOME" "$CONFIG_HOME"
  PREFIX_CANDIDATE=$(mktemp -d "$DATA_HOME/.hermes-mobile-desktop-prefix-candidate.XXXXXX")
  CONFIG_CANDIDATE=$(mktemp -d "$CONFIG_HOME/.hermes-desktop-web-config-candidate.XXXXXX")
  UNIT_CANDIDATE=$(mktemp -d "$CONFIG_HOME/.hermes-desktop-web-units-candidate.XXXXXX")
else
  CANDIDATE_ROOT=$(mktemp -d)
  PREFIX_CANDIDATE=$CANDIDATE_ROOT/prefix
  CONFIG_CANDIDATE=$CANDIDATE_ROOT/config
  UNIT_CANDIDATE=$CANDIDATE_ROOT/units
  mkdir -p -- "$PREFIX_CANDIDATE" "$CONFIG_CANDIDATE" "$UNIT_CANDIDATE"
fi
SOURCE_CANDIDATE=$PREFIX_CANDIDATE/$SOURCE_RELATIVE
STAGE_CANDIDATE=$PREFIX_CANDIDATE/bin/stage_renderer.py

cleanup_candidates() {
  local candidate
  for candidate in \
    "${NODE_GYP_DEVDIR:-}" \
    "$UNIT_CANDIDATE" \
    "$CONFIG_CANDIDATE" \
    "$PREFIX_CANDIDATE" \
    "${CANDIDATE_ROOT:-}"; do
    if [[ -n $candidate && -d $candidate && ! -L $candidate ]]; then
      rm -rf -- "$candidate"
    fi
  done
}
trap cleanup_candidates EXIT
NODE_GYP_DEVDIR=$(mktemp -d /tmp/hermes-mobile-node-gyp.XXXXXX)

mkdir -p -- "$(dirname -- "$SOURCE_CANDIDATE")"
printf '%s\n' "$PACKAGE_ID" >"$PREFIX_CANDIDATE/$MANAGED_MARKER"
printf '%s\n' "$PACKAGE_ID" >"$CONFIG_CANDIDATE/$MANAGED_MARKER"
"$ROOT/scripts/prepare_source.sh" "$SOURCE_CANDIDATE"
npm_config_devdir="$NODE_GYP_DEVDIR" \
  npm ci --workspace apps/desktop --include-workspace-root --prefix "$SOURCE_CANDIDATE"
npm run build --prefix "$SOURCE_CANDIDATE/apps/desktop"

python3 "$ROOT/scripts/render_config.py" \
  --repo-root "$ROOT" \
  --source-root "$SOURCE_ROOT" \
  --prefix "$PREFIX" \
  --config-dir "$CONFIG_DIR" \
  --unit-dir "$UNIT_DIR" \
  --output-config-dir "$CONFIG_CANDIDATE" \
  --output-unit-dir "$UNIT_CANDIDATE" \
  --output-stage-script "$STAGE_CANDIDATE" \
  --hermes-home "$HERMES_HOME" \
  --hermes-bin "$HERMES_EXECUTABLE" \
  --caddy-bin "$(command -v caddy)" \
  --web-port "$WEB_PORT" \
  --gateway-port "$GATEWAY_PORT"

systemd-analyze --user verify \
  "$UNIT_CANDIDATE/hermes-desktop-web-gateway.service" \
  "$UNIT_CANDIDATE/hermes-desktop-web.service"
caddy validate --config "$CONFIG_CANDIDATE/Caddyfile" --adapter caddyfile

if (( ! START_SERVICES )); then
  cat <<EOF

Dry-run complete. The candidate source, configuration, and units passed validation.
The installed release and service state were not changed.
EOF
  exit 0
fi

ACTIVATION_ATTEMPTED=0
restore_previous_release() {
  local status=${1:-$?} restore_status=0
  trap - ERR HUP INT TERM
  echo 'Activation failed; restoring the complete previous release.' >&2
  if (( ACTIVATION_ATTEMPTED )) &&
    ! stop_managed_units hermes-desktop-web.service hermes-desktop-web-gateway.service; then
    echo 'Managed services could not be proven inactive; preserving release backups for recovery.' >&2
    exit "$status"
  fi

  rollback_managed_replacements || restore_status=$?
  systemctl --user daemon-reload || restore_status=$?
  if (( ${#previous_enabled_units[@]} )); then
    systemctl --user enable "${previous_enabled_units[@]}" || restore_status=$?
    require_enabled_units "${previous_enabled_units[@]}" || restore_status=$?
  fi
  if (( ${#previous_active_units[@]} )); then
    systemctl --user restart "${previous_active_units[@]}" || restore_status=$?
    require_active_units "${previous_active_units[@]}" || restore_status=$?
  fi
  (( restore_status == 0 )) || echo 'The previous release was restored, but its services require manual recovery.' >&2
  exit "$status"
}
HAS_MANAGED_RELEASE=0
if has_valid_directory_marker "$PREFIX" && has_valid_directory_marker "$CONFIG_DIR"; then
  HAS_MANAGED_RELEASE=1
fi
existing_units=()
previous_active_units=()
previous_enabled_units=()
for unit in hermes-desktop-web-gateway.service hermes-desktop-web.service; do
  unit_owned=0
  unit_active=0
  unit_enabled=0
  is_managed_unit "$UNIT_DIR/$unit" && unit_owned=1
  if systemctl --user is-active --quiet "$unit"; then
    unit_active=1
  else
    status=$?
    if (( status != 3 && status != 4 )); then
      echo "Could not determine whether managed service is active: $unit" >&2
      exit 1
    fi
  fi
  if systemctl --user is-enabled --quiet "$unit"; then
    unit_enabled=1
  else
    status=$?
    if (( status != 1 && status != 4 )); then
      echo "Could not determine whether managed service is enabled: $unit" >&2
      exit 1
    fi
  fi
  if (( (unit_active || unit_enabled) && ! unit_owned )); then
    if (( ! HAS_MANAGED_RELEASE )); then
      echo "Refusing loaded service without package ownership proof: $unit" >&2
      exit 1
    fi
    unit_owned=1
  fi
  (( unit_owned )) || continue
  existing_units+=("$unit")
  (( unit_active )) && previous_active_units+=("$unit")
  (( unit_enabled )) && previous_enabled_units+=("$unit")
done
trap 'restore_previous_release $?' ERR
trap 'restore_previous_release 129' HUP
trap 'restore_previous_release 130' INT
trap 'restore_previous_release 143' TERM
if (( ${#existing_units[@]} )); then
  stop_managed_units "${existing_units[@]}"
fi

begin_managed_replacement "$PREFIX_CANDIDATE" "$PREFIX" "$DATA_HOME" "$DATA_HOME"
begin_managed_replacement "$CONFIG_CANDIDATE" "$CONFIG_DIR" "$CONFIG_HOME" "$CONFIG_HOME"
begin_managed_replacement \
  "$UNIT_CANDIDATE/hermes-desktop-web-gateway.service" \
  "$UNIT_DIR/hermes-desktop-web-gateway.service" \
  "$CONFIG_HOME" "$CONFIG_HOME"
begin_managed_replacement \
  "$UNIT_CANDIDATE/hermes-desktop-web.service" \
  "$UNIT_DIR/hermes-desktop-web.service" \
  "$CONFIG_HOME" "$CONFIG_HOME"

ACTIVATION_ATTEMPTED=1
systemctl --user daemon-reload
systemctl --user enable hermes-desktop-web-gateway.service hermes-desktop-web.service
require_enabled_units hermes-desktop-web-gateway.service hermes-desktop-web.service
systemctl --user restart hermes-desktop-web-gateway.service hermes-desktop-web.service
require_active_units hermes-desktop-web-gateway.service hermes-desktop-web.service
python3 "$ROOT/scripts/verify_runtime.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT" \
  --env-file "$CONFIG_DIR/env" \
  --baseline "$(tr -d '[:space:]' <"$ROOT/patches/BASELINE")"
trap - ERR HUP INT TERM
if ! commit_managed_replacements; then
  echo 'Activation succeeded, but some previous-release backups were retained; uninstall.sh --purge removes them.' >&2
fi

cat <<EOF

Hermes Mobile Desktop is listening on http://127.0.0.1:$WEB_PORT.
Keep it loopback-only. To expose it privately over Tailscale HTTPS:

  $ROOT/scripts/expose-tailscale.sh 8457 $WEB_PORT

Then run:

  HERMES_DESKTOP_WEB_URL=https://your-device.your-tailnet.ts.net:8457 npm run qa
EOF
