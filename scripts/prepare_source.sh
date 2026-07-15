#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEST=${1:?usage: prepare_source.sh DESTINATION}
BASELINE=$(<"$ROOT/patches/BASELINE")
shopt -s nullglob
PATCHES=("$ROOT"/patches/hermes-agent-*-desktop-web.patch)
(( ${#PATCHES[@]} == 1 )) || { echo 'Expected exactly one Desktop Web patch.' >&2; exit 1; }
PATCH=${PATCHES[0]}
UPSTREAM_URL=${HERMES_DESKTOP_WEB_UPSTREAM_URL:-https://github.com/NousResearch/Hermes-Agent.git}

[[ -n "$PATCH" ]] || { echo 'Desktop Web patch is missing.' >&2; exit 1; }
(cd "$ROOT/patches" && sha256sum --check SHA256SUMS)

verify_patched_tree() {
  git -C "$DEST" diff --quiet || {
    echo "Patched source has unstaged tracked changes: $DEST" >&2
    return 1
  }
  [[ -z $(git -C "$DEST" ls-files --others --exclude-standard) ]] || {
    echo "Patched source has unexpected untracked files: $DEST" >&2
    return 1
  }
  diff -u \
    <(cut -c67- "$ROOT/patches/FILES_SHA256SUMS" | LC_ALL=C sort) \
    <(git -C "$DEST" diff --cached --name-only | LC_ALL=C sort) >/dev/null || {
      echo "Patched source file set differs from the release manifest: $DEST" >&2
      return 1
    }
  (cd "$DEST" && sha256sum --check "$ROOT/patches/FILES_SHA256SUMS")
}

if [[ ! -d "$DEST/.git" ]]; then
  if [[ -e $DEST || -L $DEST ]]; then
    [[ -d $DEST && ! -L $DEST && -z $(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
      echo "$DEST exists but is not an empty directory or Git checkout." >&2
      exit 1
    }
  else
    mkdir -p "$DEST"
  fi
  git init --quiet "$DEST"
  git -C "$DEST" remote add origin "$UPSTREAM_URL"
  git -C "$DEST" fetch --depth=1 origin "$BASELINE"
  git -C "$DEST" checkout --quiet --detach FETCH_HEAD
fi

ACTUAL=$(git -C "$DEST" rev-parse HEAD)
[[ "$ACTUAL" == "$BASELINE" ]] || {
  echo "Unsupported Hermes Agent revision: $ACTUAL (expected $BASELINE)." >&2
  exit 1
}

if git -C "$DEST" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  verify_patched_tree
  echo 'Hermes Desktop Web patch is already applied and verified.'
  exit 0
fi

if [[ -n $(git -C "$DEST" status --porcelain --untracked-files=all) ]]; then
  echo "Refusing to patch a modified Hermes Agent checkout: $DEST" >&2
  exit 1
fi

git -C "$DEST" apply --check --index "$PATCH"
git -C "$DEST" apply --index "$PATCH"
verify_patched_tree
echo "Applied and verified Hermes Desktop Web patch in $DEST"
