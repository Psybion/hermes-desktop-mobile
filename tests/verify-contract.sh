#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
fixture="$sandbox/fixture"
bin_dir="$sandbox/bin"
mkdir -p "$fixture/scripts" "$fixture/patches" "$bin_dir"
cp "$ROOT/scripts/verify.sh" "$fixture/scripts/verify.sh"
cp "$ROOT/scripts/ownership.sh" "$fixture/scripts/ownership.sh"
printf 'baseline\n' >"$fixture/patches/BASELINE"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/systemd-analyze"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/caddy"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin_dir/systemctl"
printf '#!/usr/bin/env bash\ncat >/dev/null || true\nexit 0\n' >"$bin_dir/python3"
chmod +x "$bin_dir"/*

output="$sandbox/output"
if PATH="$bin_dir:$PATH" HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" "$fixture/scripts/verify.sh" >"$output" 2>&1; then
  echo 'VERIFY_CONTRACT_TEST_FAILED: verification passed without Playwright' >&2
  exit 1
fi
if grep -Fq 'RUNTIME_VERIFICATION_OK' "$output"; then
  echo 'VERIFY_CONTRACT_TEST_FAILED: full verification marker printed after browser QA skip' >&2
  exit 1
fi
grep -Fq 'Playwright QA is required' "$output"
printf 'VERIFY_CONTRACT_TEST_OK\n'
