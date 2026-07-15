#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "UPGRADE_TEST_FAILED: $*" >&2; exit 1; }
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
bin_dir="$sandbox/bin"
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
  *" is-active "*) exit 3 ;;
esac
exit 0
SH
chmod +x "$bin_dir"/*

run_install() {
  HOME="$sandbox/home" \
  XDG_DATA_HOME="$sandbox/data" \
  XDG_CONFIG_HOME="$sandbox/config" \
  HERMES_BIN=/bin/true \
  FAKE_BASELINE="$baseline" \
  FAKE_MANIFEST="$manifest" \
  FAKE_SYSTEMCTL_LOG="$sandbox/systemctl.log" \
  PATH="$bin_dir:$PATH" \
  "$ROOT/scripts/install.sh" "$@"
}

source_root="$sandbox/data/hermes-mobile-desktop/source"
mkdir -p "$source_root"
printf 'hermes-mobile-desktop\n' >"$sandbox/data/hermes-mobile-desktop/.hermes-mobile-desktop-managed"
printf 'old\n' >"$source_root/version"
run_install --no-start >/dev/null
[[ -d $source_root/.git ]] || fail 'upgrade did not activate the prepared candidate source'
[[ ! -e $source_root/version ]] || fail 'upgrade reused the previous source in place'
if compgen -G "$sandbox/data/hermes-mobile-desktop/.source-*" >/dev/null; then
  fail 'successful upgrade retained a candidate or backup tree'
fi

rm -rf -- "$source_root"
mkdir -p "$source_root"
printf 'old\n' >"$source_root/version"
cat >"$bin_dir/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
case " $* " in
  *" restart "*) exit 1 ;;
  *" is-active "*) exit 3 ;;
esac
exit 0
SH
chmod +x "$bin_dir/systemctl"
if run_install >/dev/null 2>&1; then
  fail 'activation unexpectedly succeeded'
fi
[[ $(<"$source_root/version") == old ]] || fail 'failed activation did not restore the previous source'
[[ -f $sandbox/config/hermes-desktop-web/env ]] || fail 'failed activation removed runtime configuration'

printf 'UPGRADE_TEST_OK\n'
