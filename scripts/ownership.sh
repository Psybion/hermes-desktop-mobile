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

purge_managed_directory_backups() {
  local target=$1 root=$2 backup
  for backup in "$(dirname -- "$target")/.${target##*/}.backup."*; do
    [[ -e $backup || -L $backup ]] || continue
    if require_managed_directory "$backup" "$root"; then
      rm -rf -- "$backup"
    else
      echo "Preserving unmanaged release backup: $backup" >&2
    fi
  done
}

purge_managed_unit_backups() {
  local target=$1 backup
  for backup in "$(dirname -- "$target")/.${target##*/}.backup."*; do
    [[ -e $backup || -L $backup ]] || continue
    if is_managed_unit "$backup"; then
      rm -f -- "$backup"
    else
      echo "Preserving unmanaged unit backup: $backup" >&2
    fi
  done
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

MANAGED_REPLACEMENT_TARGETS=()
MANAGED_REPLACEMENT_BACKUPS=()
MANAGED_REPLACEMENT_ROOTS=()

begin_managed_replacement() {
  local candidate target candidate_root target_root backup=
  candidate=$(realpath -m -- "$1")
  target=$(realpath -m -- "$2")
  candidate_root=$(realpath -m -- "$3")
  target_root=$(realpath -m -- "$4")

  managed_child_path "$candidate" "$candidate_root" && managed_child_path "$target" "$target_root" || {
    echo 'Refusing a managed replacement outside its ownership roots.' >&2
    return 1
  }
  [[ $candidate != "$target" && ! -L $candidate && ( -f $candidate || -d $candidate ) ]] || {
    echo "Refusing invalid replacement candidate: $candidate" >&2
    return 1
  }
  [[ ! -L $target && ( ! -e $target || ( -f $candidate && -f $target ) || ( -d $candidate && -d $target ) ) ]] || {
    echo "Refusing invalid replacement target: $target" >&2
    return 1
  }

  mkdir -p -- "$(dirname -- "$target")"
  if [[ -e $target ]]; then
    backup=$(mktemp -d "$(dirname -- "$target")/.${target##*/}.backup.XXXXXX")
    rmdir -- "$backup"
  fi
  MANAGED_REPLACEMENT_TARGETS+=("$target")
  MANAGED_REPLACEMENT_BACKUPS+=("$backup")
  MANAGED_REPLACEMENT_ROOTS+=("$target_root")

  [[ -z $backup ]] || mv -- "$target" "$backup"
  mv -- "$candidate" "$target"
}

rollback_managed_replacements() {
  local index target backup root status=0
  for (( index=${#MANAGED_REPLACEMENT_TARGETS[@]}-1; index>=0; index-- )); do
    target=${MANAGED_REPLACEMENT_TARGETS[index]}
    backup=${MANAGED_REPLACEMENT_BACKUPS[index]}
    root=${MANAGED_REPLACEMENT_ROOTS[index]}
    if ! managed_child_path "$target" "$root"; then
      status=1
      continue
    fi
    if [[ -n $backup ]]; then
      if [[ -e $backup && ! -L $backup ]]; then
        rm -rf -- "$target" || status=$?
        mv -- "$backup" "$target" || status=$?
      elif [[ ! -e $target || -L $target ]]; then
        status=1
      fi
    else
      rm -rf -- "$target" || status=$?
    fi
  done
  MANAGED_REPLACEMENT_TARGETS=()
  MANAGED_REPLACEMENT_BACKUPS=()
  MANAGED_REPLACEMENT_ROOTS=()
  return "$status"
}

commit_managed_replacements() {
  local index backup root status=0
  local -a retained_targets=() retained_backups=() retained_roots=()
  for index in "${!MANAGED_REPLACEMENT_TARGETS[@]}"; do
    backup=${MANAGED_REPLACEMENT_BACKUPS[index]}
    root=${MANAGED_REPLACEMENT_ROOTS[index]}
    [[ -n $backup ]] || continue
    if managed_child_path "$backup" "$root" && rm -rf -- "$backup"; then
      continue
    fi
    echo "Could not remove managed release backup: $backup" >&2
    retained_targets+=("${MANAGED_REPLACEMENT_TARGETS[index]}")
    retained_backups+=("$backup")
    retained_roots+=("$root")
    status=1
  done
  MANAGED_REPLACEMENT_TARGETS=("${retained_targets[@]}")
  MANAGED_REPLACEMENT_BACKUPS=("${retained_backups[@]}")
  MANAGED_REPLACEMENT_ROOTS=("${retained_roots[@]}")
  return "$status"
}
