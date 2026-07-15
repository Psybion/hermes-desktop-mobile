#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/ownership.sh
source "$ROOT/scripts/ownership.sh"

fail() {
  echo "LIFECYCLE_TEST_FAILED: $*" >&2
  exit 1
}

sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
root="$sandbox/root"
mkdir -p "$root"

paths_overlap "$root/one" "$root/one/child" || fail 'nested paths were not detected as overlapping'
if require_disjoint_paths "$root/one" "$root/one/child" >/dev/null 2>&1; then
  fail 'nested managed paths were accepted'
fi
require_disjoint_paths "$root/one" "$root/two"

mkdir -p "$root/unmanaged"
printf 'keep\n' >"$root/unmanaged/user-file"
if assert_managed_directory_available "$root/unmanaged" "$root"; then
  fail 'accepted a non-empty unmanaged directory during preflight'
fi
[[ -f "$root/unmanaged/user-file" ]] || fail 'modified unmanaged directory content'
[[ ! -e "$root/unmanaged/$MANAGED_MARKER" ]] || fail 'preflight wrote an ownership marker'

if assert_managed_directory_available "$sandbox/outside" "$root"; then
  fail 'accepted a package directory outside its ownership root'
fi

mkdir -p "$root/symlink-target"
ln -s "$root/symlink-target" "$root/symlink"
if assert_managed_directory_available "$root/symlink" "$root"; then
  fail 'accepted a symlink package directory'
fi

mkdir -p "$root/empty"
claim_managed_directory "$root/empty" "$root"
[[ -f "$root/empty/$MANAGED_MARKER" ]] || fail 'did not mark an empty claimed directory'
[[ $(<"$root/empty/$MANAGED_MARKER") == "$PACKAGE_ID" ]] || fail 'wrote the wrong directory marker'
claim_managed_directory "$root/empty" "$root"

managed="$root/managed.service"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$managed"
assert_unit_path_available "$managed"

unmanaged="$root/unmanaged.service"
printf '%s\n' '# user unit' '[Unit]' >"$unmanaged"
if assert_unit_path_available "$unmanaged"; then
  fail 'accepted a colliding unmanaged unit'
fi

home="$sandbox/home"
config_home="$home/config"
unit_dir="$config_home/systemd/user"
bin_dir="$sandbox/bin"
data_home="$home/data"
mkdir -p "$unit_dir" "$bin_dir" "$data_home"
printf '%s\n' '# user unit' '[Unit]' >"$unit_dir/hermes-desktop-web.service"
printf '%s\n' '# user gateway unit' '[Unit]' >"$unit_dir/hermes-desktop-web-gateway.service"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\ncase " $* " in *" is-active "*) exit 3;; esac\nexit 0\n' "$sandbox/systemctl.log" >"$bin_dir/systemctl"
chmod +x "$bin_dir/systemctl"
HOME="$home" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$data_home" PATH="$bin_dir:$PATH" "$ROOT/scripts/uninstall.sh"
[[ -f "$unit_dir/hermes-desktop-web.service" ]] || fail 'removed an unmanaged browser unit'
[[ -f "$unit_dir/hermes-desktop-web-gateway.service" ]] || fail 'removed an unmanaged gateway unit'
[[ ! -e "$sandbox/systemctl.log" ]] || fail 'called systemctl for unmanaged units'

managed_home="$sandbox/managed-home"
managed_config_home="$managed_home/config"
managed_data_home="$managed_home/data"
managed_config="$managed_config_home/hermes-desktop-web"
managed_prefix="$managed_data_home/hermes-mobile-desktop"
managed_unit_dir="$managed_config_home/systemd/user"
mkdir -p "$managed_config" "$managed_prefix" "$managed_unit_dir"
printf '%s\n' "$PACKAGE_ID" >"$managed_config/$MANAGED_MARKER"
printf '%s\n' "$PACKAGE_ID" >"$managed_prefix/$MANAGED_MARKER"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$managed_unit_dir/hermes-desktop-web.service"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$managed_unit_dir/hermes-desktop-web-gateway.service"
HOME="$managed_home" \
  XDG_CONFIG_HOME="$managed_config_home" \
  XDG_DATA_HOME="$managed_data_home" \
  PATH="$bin_dir:$PATH" \
  "$ROOT/scripts/uninstall.sh" --purge
[[ ! -e $managed_config && ! -e $managed_prefix ]] || fail 'managed purge left package directories behind'
[[ ! -e $managed_unit_dir/hermes-desktop-web.service ]] || fail 'managed purge left the browser unit behind'
[[ ! -e $managed_unit_dir/hermes-desktop-web-gateway.service ]] || fail 'managed purge left the gateway unit behind'

declare -F stop_managed_units >/dev/null || fail 'stop_managed_units helper is missing'
stop_bin="$sandbox/stop-bin"
mkdir -p "$stop_bin"
printf '#!/usr/bin/env bash\ncase " $* " in *" disable --now "*) exit 1;; *" is-active "*) exit 3;; esac\nexit 0\n' >"$stop_bin/systemctl"
chmod +x "$stop_bin/systemctl"
if PATH="$stop_bin:$PATH" stop_managed_units one.service two.service; then
  fail 'accepted a failed managed-service stop'
fi
printf '#!/usr/bin/env bash\ncase " $* " in *" is-active "*) exit 0;; esac\nexit 0\n' >"$stop_bin/systemctl"
if PATH="$stop_bin:$PATH" stop_managed_units one.service two.service; then
  fail 'accepted a managed service that remained active'
fi
printf '#!/usr/bin/env bash\ncase " $* " in *" is-active "*) exit 3;; esac\nexit 0\n' >"$stop_bin/systemctl"
PATH="$stop_bin:$PATH" stop_managed_units one.service two.service

printf '#!/usr/bin/env bash\ncase " $* " in *" is-active --quiet two.service "*|*" is-enabled --quiet two.service "*) exit 1;; esac\nexit 0\n' >"$stop_bin/systemctl"
if PATH="$stop_bin:$PATH" require_active_units one.service two.service; then
  fail 'accepted a partially active managed service set'
fi
if PATH="$stop_bin:$PATH" require_enabled_units one.service two.service; then
  fail 'accepted a partially enabled managed service set'
fi
printf '#!/usr/bin/env bash\nexit 0\n' >"$stop_bin/systemctl"
PATH="$stop_bin:$PATH" require_active_units one.service two.service
PATH="$stop_bin:$PATH" require_enabled_units one.service two.service

declare -F begin_managed_tree_replacement >/dev/null || fail 'managed tree replacement helper is missing'
tree_root="$sandbox/tree-swap"
mkdir -p "$tree_root/target" "$tree_root/candidate"
printf 'old\n' >"$tree_root/target/version"
printf 'new\n' >"$tree_root/candidate/version"
begin_managed_tree_replacement "$tree_root/candidate" "$tree_root/target" "$tree_root"
[[ $(<"$tree_root/target/version") == new ]] || fail 'candidate tree was not activated'
rollback_managed_tree_replacement
[[ $(<"$tree_root/target/version") == old ]] || fail 'tree rollback did not restore previous source'
mkdir -p "$tree_root/candidate"
printf 'new\n' >"$tree_root/candidate/version"
begin_managed_tree_replacement "$tree_root/candidate" "$tree_root/target" "$tree_root"
commit_managed_tree_replacement
[[ $(<"$tree_root/target/version") == new ]] || fail 'tree commit did not retain candidate source'
[[ -z ${MANAGED_TREE_BACKUP:-} || ! -e ${MANAGED_TREE_BACKUP:-} ]] || fail 'tree commit retained its backup'

failed_home="$sandbox/failed-home"
failed_config_home="$failed_home/config"
failed_data_home="$failed_home/data"
failed_config="$failed_config_home/hermes-desktop-web"
failed_prefix="$failed_data_home/hermes-mobile-desktop"
failed_unit_dir="$failed_config_home/systemd/user"
failed_bin="$sandbox/failed-bin"
mkdir -p "$failed_config" "$failed_prefix" "$failed_unit_dir" "$failed_bin"
printf '%s\n' "$PACKAGE_ID" >"$failed_config/$MANAGED_MARKER"
printf '%s\n' "$PACKAGE_ID" >"$failed_prefix/$MANAGED_MARKER"
printf 'keep\n' >"$failed_config/env"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$failed_unit_dir/hermes-desktop-web.service"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$failed_unit_dir/hermes-desktop-web-gateway.service"
printf '#!/usr/bin/env bash\ncase " $* " in *" disable --now "*) exit 1;; esac\nexit 0\n' >"$failed_bin/systemctl"
chmod +x "$failed_bin/systemctl"
if HOME="$failed_home" XDG_CONFIG_HOME="$failed_config_home" XDG_DATA_HOME="$failed_data_home" PATH="$failed_bin:$PATH" "$ROOT/scripts/uninstall.sh" --purge; then
  fail 'uninstall succeeded after managed services failed to stop'
fi
[[ -f $failed_config/env && -d $failed_prefix ]] || fail 'failed uninstall deleted managed runtime files'
[[ -f $failed_unit_dir/hermes-desktop-web.service ]] || fail 'failed uninstall deleted the browser unit'
[[ -f $failed_unit_dir/hermes-desktop-web-gateway.service ]] || fail 'failed uninstall deleted the gateway unit'

printf 'LIFECYCLE_TEST_OK\n'
