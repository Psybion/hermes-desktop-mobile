#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/ownership.sh"
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CONFIG_DIR=${HERMES_DESKTOP_WEB_CONFIG:-$CONFIG_HOME/hermes-desktop-web}
UNIT_DIR=$CONFIG_HOME/systemd/user
WEB_PORT=${HERMES_DESKTOP_WEB_PORT:-9122}
URL=${HERMES_DESKTOP_WEB_URL:-http://127.0.0.1:$WEB_PORT}

systemd-analyze --user verify \
  "$UNIT_DIR/hermes-desktop-web-gateway.service" \
  "$UNIT_DIR/hermes-desktop-web.service"
caddy validate --config "$CONFIG_DIR/Caddyfile" --adapter caddyfile
require_enabled_units hermes-desktop-web-gateway.service hermes-desktop-web.service
require_active_units hermes-desktop-web-gateway.service hermes-desktop-web.service
python3 "$ROOT/scripts/verify_runtime.py" \
  --url "$URL" \
  --env-file "$CONFIG_DIR/env" \
  --baseline "$(tr -d '[:space:]' <"$ROOT/patches/BASELINE")"

python3 - "$URL" "$CONFIG_DIR/env" <<'PY'
import json, sys, urllib.request
from pathlib import Path
url, env_path = sys.argv[1:]
values = {}
for raw in Path(env_path).read_text(encoding='utf-8').splitlines():
    key, sep, value = raw.partition('=')
    if sep:
        values[key.strip()] = value.strip().strip('"').strip("'")
token = values.get('HERMES_DASHBOARD_SESSION_TOKEN', '')
if not token:
    raise SystemExit('Gateway token is missing')
with urllib.request.urlopen(url.rstrip('/') + '/', timeout=10) as response:
    html = response.read().decode()
if 'data-hermes-browser' not in html and '<div id="root"' not in html:
    raise SystemExit('Hermes renderer root not found')
request = urllib.request.Request(url.rstrip('/') + '/api/status', headers={'X-Hermes-Session-Token': token})
with urllib.request.urlopen(request, timeout=10) as response:
    status = json.load(response)
print(json.dumps({'renderer': True, 'backend_version': status.get('version')}))
PY

if [[ -d "$ROOT/node_modules/playwright" ]]; then
  HERMES_DESKTOP_WEB_URL="$URL" node "$ROOT/qa/verify.cjs"
else
  echo 'Playwright QA is required for full runtime verification. Run npm ci in the repository first.' >&2
  exit 1
fi

printf 'RUNTIME_VERIFICATION_OK\n'
