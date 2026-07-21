#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
source_root="$sandbox/source % tree"
prefix="$sandbox/data/prefix % root"
config_dir="$sandbox/config/client % config"
unit_dir="$sandbox/config/systemd/user"
mkdir -p "$source_root/apps/desktop/dist" "$source_root/node_modules/@nous-research/ui/dist/fonts"

python3 "$ROOT/scripts/render_config.py" \
  --repo-root "$ROOT" \
  --source-root "$source_root" \
  --prefix "$prefix" \
  --config-dir "$config_dir" \
  --unit-dir "$unit_dir" \
  --hermes-home "$sandbox/hermes home" \
  --hermes-bin /bin/true \
  --caddy-bin /bin/true \
  --web-port 19122 \
  --gateway-port 19131 >/dev/null

unit="$unit_dir/hermes-desktop-web-gateway.service"
grep -Fq '# Managed by hermes-mobile-desktop' "$unit"
escaped_source_root=${source_root//%/%%}
grep -Fq "Environment=\"PYTHONPATH=$escaped_source_root\"" "$unit"
grep -Fq "ExecStart=\"$(realpath /bin/true)\" dashboard" "$unit"
if command -v systemd-analyze >/dev/null; then
  systemd-analyze --user verify \
    "$unit_dir/hermes-desktop-web-gateway.service" \
    "$unit_dir/hermes-desktop-web.service"
fi

baseline=$(tr -d '[:space:]' <"$ROOT/patches/BASELINE")
grep -Fq 'require_disjoint_paths "$PREFIX" "$CONFIG_DIR"' "$ROOT/scripts/install.sh"
grep -Fq 'require_disjoint_paths "$SOURCE_ROOT" "$PREFIX/dist"' "$ROOT/scripts/install.sh"
patch_file=$(printf '%s/hermes-agent-%s-desktop-web.patch' "$ROOT/patches" "${baseline:0:12}")
grep -Fq "\"baseline\": \"$baseline\"" "$patch_file"
grep -Fq '  hermes_cli/web_server.py' "$ROOT/patches/FILES_SHA256SUMS"

grep -Fq $'\t@asset_file {' "$config_dir/Caddyfile"
grep -Fq $'\t\tfile {path}' "$config_dir/Caddyfile"
grep -Fq $'\t\tnot file {path}' "$config_dir/Caddyfile"
grep -Fq $'\theader @private Cache-Control "private, no-store"' "$config_dir/Caddyfile"
grep -Fq $'\theader @asset_file Cache-Control "public, max-age=31536000, immutable"' "$config_dir/Caddyfile"
grep -Fq $'\theader @asset_missing Cache-Control "private, no-store"' "$config_dir/Caddyfile"
if grep -Fq 'header /index.html Cache-Control' "$config_dir/Caddyfile"; then
  echo 'RUNTIME_PINNING_TEST_FAILED: cache protection only matches /index.html' >&2
  exit 1
fi

overlap_home="$sandbox/overlap-home"
overlap_data="$sandbox/overlap-data"
overlap_config="$sandbox/overlap-config"
mkdir -p "$sandbox/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$sandbox/bin/caddy"
chmod +x "$sandbox/bin/caddy"
if overlap_output=$(HOME="$overlap_home" \
  XDG_DATA_HOME="$overlap_data" \
  XDG_CONFIG_HOME="$overlap_config" \
  HERMES_BIN=/bin/true \
  HERMES_SOURCE_ROOT="$overlap_data/hermes-mobile-desktop/dist/source" \
  PATH="$sandbox/bin:$PATH" \
  "$ROOT/scripts/install.sh" --no-start 2>&1); then
  echo 'RUNTIME_PINNING_TEST_FAILED: installer accepted overlapping source and renderer paths' >&2
  exit 1
fi
grep -Fq 'Refusing overlapping managed paths:' <<<"$overlap_output"
[[ ! -e "$overlap_data/hermes-mobile-desktop/.hermes-mobile-desktop-managed" ]] || {
  echo 'RUNTIME_PINNING_TEST_FAILED: failed overlap preflight claimed the package directory' >&2
  exit 1
}

brace_source="$sandbox/source {env.HOME}"
if python3 "$ROOT/scripts/render_config.py" \
  --repo-root "$ROOT" \
  --source-root "$brace_source" \
  --prefix "$sandbox/brace-prefix" \
  --config-dir "$sandbox/brace-config" \
  --unit-dir "$sandbox/brace-units" \
  --hermes-home "$sandbox/brace-home" \
  --hermes-bin /bin/true \
  --caddy-bin /bin/true >/dev/null 2>&1; then
  echo 'RUNTIME_PINNING_TEST_FAILED: accepted active Caddy placeholder braces in a path' >&2
  exit 1
fi

printf 'RUNTIME_PINNING_TEST_OK\n'
