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

managed_units=()
for unit_path in \
  "$UNIT_DIR/hermes-desktop-web.service" \
  "$UNIT_DIR/hermes-desktop-web-gateway.service"; do
  if is_managed_unit "$unit_path"; then
    managed_units+=("$unit_path")
  elif [[ -e $unit_path || -L $unit_path ]]; then
    echo "Preserving unmanaged systemd unit: $unit_path" >&2
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
  rm -rf -- "$CONFIG_DIR" "$PREFIX"
  echo 'Removed managed services, configuration, build, and source checkout.'
else
  echo "Managed services removed. Preserved $CONFIG_DIR and $PREFIX. Pass --purge to remove them."
fi
