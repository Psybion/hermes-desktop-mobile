#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${HERMES_SOURCE_ROOT:-} ]]; then
  SOURCE=$HERMES_SOURCE_ROOT
  CLEANUP=0
else
  TMP=$(mktemp -d)
  SOURCE=$TMP/hermes-agent
  CLEANUP=1
  trap 'rm -rf -- "$TMP"' EXIT
fi
"$ROOT/scripts/check.sh"
"$ROOT/scripts/prepare_source.sh" "$SOURCE"
"$ROOT/scripts/prepare_source.sh" "$SOURCE"
python3 -m py_compile "$SOURCE/hermes_cli/web_server.py"
npm ci --workspace apps/desktop --include-workspace-root --prefix "$SOURCE"
cd "$SOURCE/apps/desktop"
npm run typecheck
npx eslint \
  src/browser-bridge.ts \
  src/browser-bridge.test.ts \
  src/main.tsx \
  src/app/chat/composer/controls.tsx \
  src/app/chat/composer/index.tsx \
  src/app/overlays/overlay-view.tsx \
  src/app/shell/app-shell.tsx \
  src/app/shell/titlebar-controls.tsx \
  src/components/pane-shell/pane-shell.tsx \
  src/components/pane-shell/pane-shell.test.tsx
npx vitest run --environment jsdom \
  src/browser-bridge.test.ts \
  src/components/pane-shell/pane-shell.test.tsx \
  src/app/chat/composer/trigger-popover.test.tsx \
  src/app/chat/composer/text-utils.test.ts \
  src/app/chat/composer/slash-nav-dom-repro.test.tsx \
  src/app/chat/composer/rich-editor.test.ts \
  src/app/chat/composer/ime-composition-dom-repro.test.tsx \
  src/app/chat/composer/hooks/use-composer-url-dialog.test.tsx \
  src/app/chat/composer/enter-submit-dom-race.test.tsx \
  src/app/chat/composer/composer-utils.test.ts \
  src/app/chat/composer/composer-text-guard.test.tsx \
  src/app/shell/titlebar.test.ts
npm run test:desktop:platforms
npm run build
git diff --check
git diff --cached --check
printf '\nSOURCE_VERIFICATION_OK\n'
