#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/ownership.sh"
CONFIG_HOME=$(realpath -m -- "${XDG_CONFIG_HOME:-$HOME/.config}")
DATA_HOME=$(realpath -m -- "${XDG_DATA_HOME:-$HOME/.local/share}")
CONFIG_DIR=$(realpath -m -- "${HERMES_DESKTOP_WEB_CONFIG:-$CONFIG_HOME/hermes-desktop-web}")
PREFIX=$(realpath -m -- "${HERMES_DESKTOP_WEB_HOME:-$DATA_HOME/hermes-mobile-desktop}")
UNIT_DIR=$CONFIG_HOME/systemd/user

if [[ ${1:-} == --purge ]]; then
  require_managed_directory "$CONFIG_DIR" "$CONFIG_HOME"
  require_managed_directory "$PREFIX" "$DATA_HOME"
elif [[ -n ${1:-} ]]; then
  echo 'usage: ./scripts/uninstall.sh [--purge]' >&2
  exit 2
fi

HAS_MANAGED_RELEASE=0
if has_valid_directory_marker "$CONFIG_DIR" && has_valid_directory_marker "$PREFIX"; then
  HAS_MANAGED_RELEASE=1
fi
managed_units=()
for unit_path in \
  "$UNIT_DIR/hermes-desktop-web.service" \
  "$UNIT_DIR/hermes-desktop-web-gateway.service"; do
  if is_managed_unit "$unit_path"; then
    managed_units+=("$unit_path")
  elif [[ -e $unit_path || -L $unit_path ]]; then
    echo "Preserving unmanaged systemd unit: $unit_path" >&2
  elif (( HAS_MANAGED_RELEASE )); then
    unit=${unit_path##*/}
    unit_active=0
    unit_enabled=0
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
    (( unit_active || unit_enabled )) && managed_units+=("$unit_path")
  fi
done
if (( ${#managed_units[@]} )); then
  unit_names=()
  for unit_path in "${managed_units[@]}"; do unit_names+=("${unit_path##*/}"); done
  stop_managed_units "${unit_names[@]}"
  rm -f -- "${managed_units[@]}"
  systemctl --user daemon-reload
fi

if [[ ${1:-} == --purge ]]; then
  purge_managed_directory_backups "$CONFIG_DIR" "$CONFIG_HOME"
  purge_managed_directory_backups "$PREFIX" "$DATA_HOME"
  purge_managed_unit_backups "$UNIT_DIR/hermes-desktop-web.service"
  purge_managed_unit_backups "$UNIT_DIR/hermes-desktop-web-gateway.service"
  rm -rf -- "$CONFIG_DIR" "$PREFIX"
  echo 'Removed managed services, configuration, build, and source checkout.'
else
  echo "Managed services removed. Preserved $CONFIG_DIR and $PREFIX. Pass --purge to remove them."
fi
