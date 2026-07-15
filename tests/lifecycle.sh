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
prefix_backup="$managed_data_home/.hermes-mobile-desktop.backup.test"
config_backup="$managed_config_home/.hermes-desktop-web.backup.test"
web_unit_backup="$managed_unit_dir/.hermes-desktop-web.service.backup.test"
gateway_unit_backup="$managed_unit_dir/.hermes-desktop-web-gateway.service.backup.test"
cp -a -- "$managed_prefix" "$prefix_backup"
cp -a -- "$managed_config" "$config_backup"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$web_unit_backup"
printf '%s\n' "$UNIT_MARKER" '[Unit]' >"$gateway_unit_backup"
rm -- "$managed_unit_dir/hermes-desktop-web.service"
printf 'running\n' >"$sandbox/managed-systemctl.state"
: >"$sandbox/managed-systemctl.enabled"
: >"$sandbox/systemctl.log"
cat >"$bin_dir/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$sandbox/systemctl.log"
case " \$* " in
  *" disable --now "*)
    printf 'stopped\\n' >"$sandbox/managed-systemctl.state"
    rm -f -- "$sandbox/managed-systemctl.enabled"
    ;;
  *" is-active "*) [[ \$(<"$sandbox/managed-systemctl.state") == running ]] && exit 0 || exit 3 ;;
  *" is-enabled "*) [[ -e "$sandbox/managed-systemctl.enabled" ]] && exit 0 || exit 1 ;;
esac
exit 0
SH
chmod +x "$bin_dir/systemctl"
HOME="$managed_home" \
  XDG_CONFIG_HOME="$managed_config_home" \
  XDG_DATA_HOME="$managed_data_home" \
  PATH="$bin_dir:$PATH" \
  "$ROOT/scripts/uninstall.sh"
managed_stop_call=$(grep 'disable --now' "$sandbox/systemctl.log" | head -n 1)
[[ $managed_stop_call == *'hermes-desktop-web-gateway.service'* &&
  $managed_stop_call == *'hermes-desktop-web.service'* ]] ||
  fail 'uninstall did not stop a loaded managed service whose unit file was missing'
[[ ! -e $sandbox/managed-systemctl.enabled ]] ||
  fail 'uninstall left a managed service enabled'
[[ -d $managed_config && -d $managed_prefix ]] ||
  fail 'ordinary uninstall removed managed package directories'

printf 'stopped\n' >"$sandbox/managed-systemctl.state"
: >"$sandbox/managed-systemctl.enabled"
: >"$sandbox/systemctl.log"
HOME="$managed_home" \
  XDG_CONFIG_HOME="$managed_config_home" \
  XDG_DATA_HOME="$managed_data_home" \
  PATH="$bin_dir:$PATH" \
  "$ROOT/scripts/uninstall.sh" --purge
managed_stop_call=$(grep 'disable --now' "$sandbox/systemctl.log" | head -n 1)
[[ $managed_stop_call == *'hermes-desktop-web-gateway.service'* &&
  $managed_stop_call == *'hermes-desktop-web.service'* ]] ||
  fail 'purge did not disable an inactive enabled managed service whose unit file was missing'
[[ ! -e $sandbox/managed-systemctl.enabled ]] ||
  fail 'purge left a missing-file managed service enabled'
[[ ! -e $managed_config && ! -e $managed_prefix ]] || fail 'managed purge left package directories behind'
[[ ! -e $managed_unit_dir/hermes-desktop-web.service ]] || fail 'managed purge left the browser unit behind'
[[ ! -e $managed_unit_dir/hermes-desktop-web-gateway.service ]] || fail 'managed purge left the gateway unit behind'
[[ ! -e $prefix_backup && ! -e $config_backup ]] || fail 'managed purge left release tree backups behind'
[[ ! -e $web_unit_backup && ! -e $gateway_unit_backup ]] || fail 'managed purge left unit backups behind'

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

declare -F begin_managed_replacement >/dev/null || fail 'managed replacement helper is missing'
tree_root="$sandbox/tree-swap"
mkdir -p "$tree_root/target-one" "$tree_root/target-two" "$tree_root/candidate-one" "$tree_root/candidate-two"
printf 'old-one\n' >"$tree_root/target-one/version"
printf 'old-two\n' >"$tree_root/target-two/version"
printf 'new-one\n' >"$tree_root/candidate-one/version"
printf 'new-two\n' >"$tree_root/candidate-two/version"
begin_managed_replacement "$tree_root/candidate-one" "$tree_root/target-one" "$tree_root" "$tree_root"
begin_managed_replacement "$tree_root/candidate-two" "$tree_root/target-two" "$tree_root" "$tree_root"
rollback_managed_replacements
[[ $(<"$tree_root/target-one/version") == old-one ]] || fail 'rollback did not restore the first tree'
[[ $(<"$tree_root/target-two/version") == old-two ]] || fail 'rollback did not restore the second tree'
mkdir -p "$tree_root/candidate-one" "$tree_root/candidate-two"
printf 'new-one\n' >"$tree_root/candidate-one/version"
printf 'new-two\n' >"$tree_root/candidate-two/version"
begin_managed_replacement "$tree_root/candidate-one" "$tree_root/target-one" "$tree_root" "$tree_root"
begin_managed_replacement "$tree_root/candidate-two" "$tree_root/target-two" "$tree_root" "$tree_root"
commit_managed_replacements
[[ $(<"$tree_root/target-one/version") == new-one ]] || fail 'commit did not retain the first tree'
[[ $(<"$tree_root/target-two/version") == new-two ]] || fail 'commit did not retain the second tree'
(( ${#MANAGED_REPLACEMENT_BACKUPS[@]} == 0 )) || fail 'commit retained replacement backups'

cleanup_root="$sandbox/cleanup-failure"
cleanup_bin="$sandbox/cleanup-bin"
mkdir -p "$cleanup_root/target" "$cleanup_root/candidate" "$cleanup_bin"
printf 'old\n' >"$cleanup_root/target/version"
printf 'new\n' >"$cleanup_root/candidate/version"
begin_managed_replacement \
  "$cleanup_root/candidate" "$cleanup_root/target" "$cleanup_root" "$cleanup_root"
retained_backup=${MANAGED_REPLACEMENT_BACKUPS[0]}
cat >"$cleanup_bin/rm" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *'.backup.'* ]]; then exit 1; fi
exec /bin/rm "$@"
SH
chmod +x "$cleanup_bin/rm"
if PATH="$cleanup_bin:$PATH" commit_managed_replacements; then
  fail 'commit accepted a failed backup cleanup'
fi
[[ -d $retained_backup ]] || fail 'failed commit discarded the previous release backup'
(( ${#MANAGED_REPLACEMENT_BACKUPS[@]} == 1 )) ||
  fail 'failed commit discarded backup recovery bookkeeping'
/bin/rm -rf -- "$retained_backup" "$cleanup_root/target"
MANAGED_REPLACEMENT_TARGETS=()
MANAGED_REPLACEMENT_BACKUPS=()
MANAGED_REPLACEMENT_ROOTS=()

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
