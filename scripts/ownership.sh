#!/usr/bin/env bash

PACKAGE_ID=hermes-mobile-desktop
MANAGED_MARKER=.hermes-mobile-desktop-managed
UNIT_MARKER='# Managed by hermes-mobile-desktop'

managed_child_path() {
  local path root
  path=$(realpath -m -- "$1")
  root=$(realpath -m -- "$2")
  [[ $path == "$root"/* ]]
}

paths_overlap() {
  local first second
  first=$(realpath -m -- "$1")
  second=$(realpath -m -- "$2")
  [[ $first == "$second" || $first == "$second"/* || $second == "$first"/* ]]
}

require_disjoint_paths() {
  if paths_overlap "$1" "$2"; then
    echo "Refusing overlapping managed paths: $1 and $2" >&2
    return 1
  fi
}

has_valid_directory_marker() {
  local path=$1 marker=$1/$MANAGED_MARKER
  [[ -f $marker && ! -L $marker ]] && [[ $(<"$marker") == "$PACKAGE_ID" ]]
}

require_managed_directory() {
  local path=$1 root=$2
  if ! managed_child_path "$path" "$root" || [[ -L $path ]] || ! has_valid_directory_marker "$path"; then
    echo "Refusing unmanaged package directory: $path" >&2
    return 1
  fi
}

assert_managed_directory_available() {
  local path=$1 root=$2 entry

  if ! managed_child_path "$path" "$root" || [[ -L $path ]]; then
    echo "Refusing unsafe package directory: $path" >&2
    return 1
  fi
  if [[ -e $path && ! -d $path ]]; then
    echo "Refusing non-directory package path: $path" >&2
    return 1
  fi
  if has_valid_directory_marker "$path"; then
    return 0
  fi
  if [[ -e $path/$MANAGED_MARKER || -L $path/$MANAGED_MARKER ]]; then
    echo "Refusing package directory with an invalid ownership marker: $path" >&2
    return 1
  fi
  if [[ -d $path ]]; then
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
      if [[ -e $entry || -L $entry ]]; then
        echo "Refusing non-empty unmanaged package directory: $path" >&2
        return 1
      fi
    done
  fi
}

claim_managed_directory() {
  local path=$1 root=$2

  assert_managed_directory_available "$path" "$root"
  if has_valid_directory_marker "$path"; then
    return 0
  fi
  mkdir -p -- "$path"
  (umask 077; printf '%s\n' "$PACKAGE_ID" >"$path/$MANAGED_MARKER")
}

is_managed_unit() {
  local path=$1 first_line
  [[ -f $path && ! -L $path ]] || return 1
  IFS= read -r first_line <"$path" || true
  [[ $first_line == "$UNIT_MARKER" ]]
}

assert_unit_path_available() {
  local path=$1
  if [[ ! -e $path && ! -L $path ]] || is_managed_unit "$path"; then
    return 0
  fi
  echo "Refusing to replace unmanaged systemd unit: $path" >&2
  return 1
}

stop_managed_units() {
  (( $# )) || return 0
  if ! systemctl --user disable --now "$@"; then
    echo 'Failed to stop and disable every managed service; preserving package files.' >&2
    return 1
  fi

  local status unit
  for unit in "$@"; do
    if systemctl --user is-active --quiet "$unit"; then
      echo "Managed service remained active after stop: $unit" >&2
      return 1
    else
      status=$?
    fi
    if (( status != 3 && status != 4 )); then
      echo "Could not verify that managed service stopped: $unit" >&2
      return 1
    fi
  done
}

require_unit_state() {
  local command=$1 expected=$2 unit
  shift 2
  for unit in "$@"; do
    systemctl --user "$command" --quiet "$unit" || {
      echo "Managed service is not $expected: $unit" >&2
      return 1
    }
  done
}

require_active_units() {
  require_unit_state is-active active "$@"
}

require_enabled_units() {
  require_unit_state is-enabled enabled "$@"
}

MANAGED_TREE_TARGET=
MANAGED_TREE_BACKUP=
MANAGED_TREE_ROOT=

begin_managed_tree_replacement() {
  local candidate target root backup=
  candidate=$(realpath -m -- "$1")
  target=$(realpath -m -- "$2")
  root=$(realpath -m -- "$3")

  [[ -z $MANAGED_TREE_TARGET ]] || { echo 'A managed tree replacement is already active.' >&2; return 1; }
  managed_child_path "$candidate" "$root" && managed_child_path "$target" "$root" || {
    echo 'Refusing a managed tree replacement outside its ownership root.' >&2
    return 1
  }
  [[ -d $candidate && ! -L $candidate && $candidate != "$target" ]] || {
    echo "Refusing invalid replacement candidate: $candidate" >&2
    return 1
  }
  [[ ! -L $target && ( ! -e $target || -d $target ) ]] || {
    echo "Refusing invalid replacement target: $target" >&2
    return 1
  }

  mkdir -p -- "$(dirname -- "$target")"
  if [[ -d $target ]]; then
    backup=$(mktemp -d "$root/.source-backup.XXXXXX")
    rmdir -- "$backup"
    mv -- "$target" "$backup"
  fi
  if ! mv -- "$candidate" "$target"; then
    [[ -z $backup ]] || mv -- "$backup" "$target"
    return 1
  fi

  MANAGED_TREE_TARGET=$target
  MANAGED_TREE_BACKUP=$backup
  MANAGED_TREE_ROOT=$root
}

rollback_managed_tree_replacement() {
  [[ -n $MANAGED_TREE_TARGET ]] || return 0
  managed_child_path "$MANAGED_TREE_TARGET" "$MANAGED_TREE_ROOT" || return 1
  rm -rf -- "$MANAGED_TREE_TARGET"
  [[ -z $MANAGED_TREE_BACKUP ]] || mv -- "$MANAGED_TREE_BACKUP" "$MANAGED_TREE_TARGET"
  MANAGED_TREE_TARGET=
  MANAGED_TREE_BACKUP=
  MANAGED_TREE_ROOT=
}

commit_managed_tree_replacement() {
  [[ -n $MANAGED_TREE_TARGET ]] || return 0
  if [[ -n $MANAGED_TREE_BACKUP ]]; then
    managed_child_path "$MANAGED_TREE_BACKUP" "$MANAGED_TREE_ROOT" || return 1
    rm -rf -- "$MANAGED_TREE_BACKUP"
  fi
  MANAGED_TREE_TARGET=
  MANAGED_TREE_BACKUP=
  MANAGED_TREE_ROOT=
}
