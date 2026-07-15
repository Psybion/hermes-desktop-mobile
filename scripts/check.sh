#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

for script in scripts/*.sh; do bash -n "$script"; done
python3 -m py_compile scripts/*.py tests/*.py
for script in qa/*.cjs; do node --check "$script"; done
(cd patches && sha256sum --check SHA256SUMS)
./tests/lifecycle.sh
./tests/runtime-pinning.sh
./tests/upgrade.sh
./tests/verify-contract.sh
python3 -m unittest tests/test_render_config.py tests/test_verify_runtime.py

if grep -RInF "$HOME/" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=qa-output --exclude='check.sh' . ||
  grep -RInE '[[:alnum:]-]+\.tail[[:alnum:]]+\.ts\.net|gh[pousr]_[[:alnum:]_]{20,}|AKIA[0-9A-Z]{16}|sk-[[:alnum:]]{20,}|BEGIN [A-Z ]*PRIVATE KEY|HERMES_DASHBOARD_SESSION_TOKEN=.+' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=qa-output --exclude='check.sh' .; then
  echo 'Machine-specific data or a possible secret was found.' >&2
  exit 1
fi

if grep -RIn '@[A-Z_][A-Z_]*@' --exclude='*.in' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=qa-output .; then
  echo 'Unresolved template placeholder found outside templates.' >&2
  exit 1
fi

printf 'PACKAGE_CHECK_OK\n'
