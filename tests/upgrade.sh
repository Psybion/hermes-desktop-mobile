#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "UPGRADE_TEST_FAILED: $*" >&2; exit 1; }
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
bin_dir="$sandbox/bin"
real_mv=$(command -v mv)
real_rm=$(command -v rm)
mkdir -p "$bin_dir"
baseline=$(tr -d '[:space:]' <"$ROOT/patches/BASELINE")
manifest=$(cut -c67- "$ROOT/patches/FILES_SHA256SUMS")

cat >"$bin_dir/git" <<'SH'
#!/usr/bin/env bash
set -u
args=" $* "
if [[ $args == *" init --quiet "* ]]; then
  destination=${!#}
  mkdir -p "$destination/.git"
  exit 0
fi
if [[ $args == *" rev-parse HEAD "* ]]; then
  printf '%s\n' "$FAKE_BASELINE"
  exit 0
fi
if [[ $args == *" diff --cached --name-only "* ]]; then
  printf '%s\n' "$FAKE_MANIFEST"
  exit 0
fi
if [[ $args == *" apply --reverse --check "* ]]; then exit 1; fi
exit 0
SH
cat >"$bin_dir/sha256sum" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$bin_dir/npm" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" ci "* ]]; then
  [[ -n ${npm_config_devdir:-} ]] || { echo 'npm_config_devdir was not set' >&2; exit 1; }
  [[ $npm_config_devdir != *' '* && $npm_config_devdir != *'%'* ]] || {
    echo 'npm_config_devdir was not isolated to a safe path' >&2
    exit 1
  }
fi
exit 0
SH
cat >"$bin_dir/systemd-analyze" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$bin_dir/caddy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
case " $* " in
  *" disable --now "*) printf 'stopped\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" restart "*) printf 'running\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" is-active "*) [[ $(<"$FAKE_SYSTEMCTL_STATE") == running ]] && exit 0 || exit 3 ;;
esac
exit 0
SH
cat >"$bin_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == */verify_runtime.py ]]; then
  exit 0
fi
exec "$FAKE_PYTHON" "$@"
SH
chmod +x "$bin_dir"/*
printf 'running\n' >"$sandbox/systemctl.state"

run_install() {
  local install_home=${INSTALL_HOME:-$sandbox}
  HOME="$install_home/home" \
  XDG_DATA_HOME="$install_home/data" \
  XDG_CONFIG_HOME="$install_home/config" \
  HERMES_BIN=/bin/true \
  FAKE_BASELINE="$baseline" \
  FAKE_MANIFEST="$manifest" \
  FAKE_MV_REAL="$real_mv" \
  FAKE_MV_SIGNAL_MARKER="${FAKE_MV_SIGNAL_MARKER:-$sandbox/mv-signal.disabled}" \
  FAKE_PYTHON="$(command -v python3)" \
  FAKE_RESTART_COUNT="$sandbox/restart.count" \
  FAKE_RM_REAL="$real_rm" \
  FAKE_SYSTEMCTL_LOG="$sandbox/systemctl.log" \
  FAKE_SYSTEMCTL_STATE="$sandbox/systemctl.state" \
  PATH="$bin_dir:$PATH" \
  "$ROOT/scripts/install.sh" "$@"
}

assert_no_transaction_artifacts() {
  local pattern
  for pattern in \
    "$sandbox/data/.hermes-mobile-desktop*" \
    "$sandbox/config/.hermes-desktop-web*" \
    "$sandbox/config/systemd/user/.hermes-desktop-web*"; do
    if compgen -G "$pattern" >/dev/null; then
      fail "retained release transaction artifact: $pattern"
    fi
  done
}

unowned_home="$sandbox/unowned"
: >"$sandbox/systemctl.log"
if INSTALL_HOME="$unowned_home" run_install >/dev/null 2>&1; then
  fail 'installer took over active services without package ownership proof'
fi
if grep -q 'disable --now' "$sandbox/systemctl.log"; then
  fail 'installer stopped active services without package ownership proof'
fi
[[ ! -e $unowned_home/data/hermes-mobile-desktop ]] ||
  fail 'installer claimed package paths without service ownership proof'
: >"$sandbox/systemctl.log"

source_root="$sandbox/data/hermes-mobile-desktop/source"
config_dir="$sandbox/config/hermes-desktop-web"
unit_dir="$sandbox/config/systemd/user"
mkdir -p "$source_root" "$sandbox/data/hermes-mobile-desktop/bin" "$config_dir" "$unit_dir"
printf 'hermes-mobile-desktop\n' >"$sandbox/data/hermes-mobile-desktop/.hermes-mobile-desktop-managed"
printf 'hermes-mobile-desktop\n' >"$config_dir/.hermes-mobile-desktop-managed"
printf 'old-source\n' >"$source_root/version"
printf 'old-stage\n' >"$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py"
printf 'old-env\n' >"$config_dir/env"
printf 'old-caddy\n' >"$config_dir/Caddyfile"
for unit in hermes-desktop-web-gateway.service hermes-desktop-web.service; do
  printf '# Managed by hermes-mobile-desktop\nold-unit\n' >"$unit_dir/$unit"
done
before=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
run_install --no-start >/dev/null
after=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
[[ $after == "$before" ]] || fail '--no-start mutated the installed release'
[[ $(<"$sandbox/systemctl.state") == running ]] || fail '--no-start changed service state'
[[ ! -s $sandbox/systemctl.log ]] || fail '--no-start invoked systemctl'
assert_no_transaction_artifacts

rm -- "$unit_dir/hermes-desktop-web.service"
: >"$sandbox/systemctl.log"
run_install >/dev/null
stop_call=$(grep 'disable --now' "$sandbox/systemctl.log" | head -n 1)
[[ $stop_call == *'hermes-desktop-web-gateway.service'* &&
  $stop_call == *'hermes-desktop-web.service'* ]] ||
  fail 'upgrade did not stop a loaded managed service whose unit file was missing'
[[ -d $source_root/.git ]] || fail 'upgrade did not activate the prepared candidate source'
[[ ! -e $source_root/version ]] || fail 'upgrade reused the previous source in place'
[[ $(<"$sandbox/systemctl.state") == running ]] || fail 'successful upgrade did not restart services'
assert_no_transaction_artifacts

printf 'stable-source\n' >"$source_root/version"
printf 'stable-stage\n' >>"$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py"
printf 'stable-env\n' >>"$config_dir/env"
printf 'stable-caddy\n' >>"$config_dir/Caddyfile"
for unit in hermes-desktop-web-gateway.service hermes-desktop-web.service; do
  printf 'stable-unit\n' >>"$unit_dir/$unit"
done
stable=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
printf 'stopped\n' >"$sandbox/systemctl.state"
rm -f -- "$sandbox/restart.count"
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
case " $* " in
  *" disable --now "*) printf 'stopped\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" restart "*)
    count=0
    [[ ! -e $FAKE_RESTART_COUNT ]] || count=$(<"$FAKE_RESTART_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_RESTART_COUNT"
    if (( count == 1 )); then exit 1; fi
    printf 'running\n' >"$FAKE_SYSTEMCTL_STATE"
    ;;
  *" is-active "*) [[ $(<"$FAKE_SYSTEMCTL_STATE") == running ]] && exit 0 || exit 3 ;;
esac
exit 0
SH
chmod +x "$bin_dir/systemctl"
if run_install >/dev/null 2>&1; then
  fail 'activation unexpectedly succeeded'
fi
[[ $(<"$source_root/version") == stable-source ]] || fail 'failed activation did not restore the previous source'
restored=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
[[ $restored == "$stable" ]] || fail 'failed activation did not restore the complete previous release'
[[ $(<"$sandbox/systemctl.state") == stopped ]] ||
  fail 'rollback started services that were inactive before installation'
assert_no_transaction_artifacts

service_state_dir="$sandbox/per-unit-state"
rm -rf -- "$service_state_dir"
mkdir -p "$service_state_dir"
: >"$service_state_dir/active-gateway"
: >"$service_state_dir/enabled-web"
cp -- "$unit_dir/hermes-desktop-web.service" "$sandbox/stable-web.service"
rm -- "$unit_dir/hermes-desktop-web.service"
mixed_stable=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service")
rm -f -- "$sandbox/restart.count"
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
unit=${!#}
case " $* " in
  *" disable --now "*) rm -f -- "$FAKE_UNIT_STATE_DIR"/* ;;
  *" is-active "*)
    [[ $unit == hermes-desktop-web-gateway.service && -e $FAKE_UNIT_STATE_DIR/active-gateway ]] && exit 0
    exit 3
    ;;
  *" is-enabled "*)
    [[ -e $FAKE_UNIT_STATE_DIR/enabled-all ]] && exit 0
    [[ $unit == hermes-desktop-web.service && -e $FAKE_UNIT_STATE_DIR/enabled-web ]] && exit 0
    exit 1
    ;;
  *" enable "*)
    if [[ " $* " == *" hermes-desktop-web-gateway.service hermes-desktop-web.service "* ]]; then
      : >"$FAKE_UNIT_STATE_DIR/enabled-all"
    else
      [[ " $* " != *" hermes-desktop-web.service "* ]] || : >"$FAKE_UNIT_STATE_DIR/enabled-web"
    fi
    ;;
  *" restart "*)
    count=0
    [[ ! -e $FAKE_RESTART_COUNT ]] || count=$(<"$FAKE_RESTART_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_RESTART_COUNT"
    (( count != 1 )) || exit 1
    [[ " $* " != *" hermes-desktop-web-gateway.service "* ]] || : >"$FAKE_UNIT_STATE_DIR/active-gateway"
    ;;
esac
exit 0
SH
chmod +x "$bin_dir/systemctl"
FAKE_UNIT_STATE_DIR="$service_state_dir" run_install >/dev/null 2>&1 &&
  fail 'mixed-state activation failure unexpectedly succeeded'
[[ -e $service_state_dir/active-gateway && ! -e $service_state_dir/enabled-all && -e $service_state_dir/enabled-web ]] ||
  fail 'rollback did not restore the previous mixed per-unit service state'
[[ ! -e $unit_dir/hermes-desktop-web.service ]] ||
  fail 'rollback created a unit file that was previously missing'
mixed_restored=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service")
[[ $mixed_restored == "$mixed_stable" ]] ||
  fail 'mixed-state activation failure did not restore the complete previous release'
cp -- "$sandbox/stable-web.service" "$unit_dir/hermes-desktop-web.service"
assert_no_transaction_artifacts

rm -f -- "$sandbox/signal.sent"
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
case " $* " in
  *" disable --now "*) printf 'stopped\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" daemon-reload "*)
    if [[ ! -e $FAKE_SIGNAL_MARKER ]]; then
      : >"$FAKE_SIGNAL_MARKER"
      kill -TERM "$PPID"
    fi
    ;;
  *" restart "*) printf 'running\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" is-active "*) [[ $(<"$FAKE_SYSTEMCTL_STATE") == running ]] && exit 0 || exit 3 ;;
esac
exit 0
SH
chmod +x "$bin_dir/systemctl"
FAKE_SIGNAL_MARKER="$sandbox/signal.sent" run_install >/dev/null 2>&1 &&
  fail 'signal-interrupted activation unexpectedly succeeded'
[[ $(<"$source_root/version") == stable-source ]] ||
  fail 'signal interruption did not restore the previous source'
signal_restored=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
[[ $signal_restored == "$stable" ]] ||
  fail 'signal interruption did not restore the complete previous release'
assert_no_transaction_artifacts

rm -f -- "$sandbox/mv-signal.sent"
printf 'running\n' >"$sandbox/systemctl.state"
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
case " $* " in
  *" disable --now "*) printf 'stopped\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" restart "*) printf 'running\n' >"$FAKE_SYSTEMCTL_STATE" ;;
  *" is-active "*) [[ $(<"$FAKE_SYSTEMCTL_STATE") == running ]] && exit 0 || exit 3 ;;
esac
exit 0
SH
cat >"$bin_dir/mv" <<'SH'
#!/usr/bin/env bash
"$FAKE_MV_REAL" "$@"
destination=${!#}
if [[ $destination == *.backup.* && ! -e $FAKE_MV_SIGNAL_MARKER ]]; then
  : >"$FAKE_MV_SIGNAL_MARKER"
  kill -TERM "$PPID"
fi
SH
chmod +x "$bin_dir/systemctl" "$bin_dir/mv"
FAKE_MV_SIGNAL_MARKER="$sandbox/mv-signal.sent" run_install >/dev/null 2>&1 &&
  fail 'swap-interrupted activation unexpectedly succeeded'
[[ -f $source_root/version && $(<"$source_root/version") == stable-source ]] ||
  fail 'signal during a component swap did not restore the previous source'
swap_signal_restored=$(sha256sum \
  "$source_root/version" \
  "$sandbox/data/hermes-mobile-desktop/bin/stage_renderer.py" \
  "$config_dir/env" \
  "$config_dir/Caddyfile" \
  "$unit_dir/hermes-desktop-web-gateway.service" \
  "$unit_dir/hermes-desktop-web.service")
[[ $swap_signal_restored == "$stable" ]] ||
  fail 'signal during a component swap did not restore the complete previous release'
assert_no_transaction_artifacts

: >"$sandbox/mv-signal.disabled"
rm -f -- "$sandbox/rm-failure.sent"
cat >"$bin_dir/rm" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ $argument == *.backup.* && ! -e $FAKE_RM_FAILURE_MARKER ]]; then
    : >"$FAKE_RM_FAILURE_MARKER"
    exit 1
  fi
done
exec "$FAKE_RM_REAL" "$@"
SH
chmod +x "$bin_dir/rm"
cleanup_output=$(FAKE_RM_FAILURE_MARKER="$sandbox/rm-failure.sent" run_install 2>&1) ||
  fail 'verified activation failed solely because backup cleanup was incomplete'
grep -q 'Activation succeeded, but some previous-release backups were retained' <<<"$cleanup_output" ||
  fail 'backup cleanup failure was not reported accurately'
[[ -d $source_root/.git ]] ||
  fail 'backup cleanup failure prevented the verified candidate from remaining active'
[[ ! -f $source_root/version || $(<"$source_root/version") != stable-source ]] ||
  fail 'backup cleanup failure rolled back to the previous source'
compgen -G "$sandbox/data/.hermes-mobile-desktop.backup.*" >/dev/null ||
  fail 'failed backup cleanup did not retain a package backup for guarded purge'

printf 'UPGRADE_TEST_OK\n'
