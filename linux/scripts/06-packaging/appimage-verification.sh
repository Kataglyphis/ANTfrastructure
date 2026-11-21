#!/usr/bin/env bash
# Common checks keep extraction native and constrain paths to the payload.
appimage_require_args() {
  if [ "$1" -ne "$2" ]; then
    printf 'Usage: %s %s\n' "$3" "$4" >&2
    return 2
  fi
}

appimage_init() {
  image="$(realpath -e -- "$1")" || return
  target="$(arch_normalize "$2")" || return
  host="$(arch_normalize "$(uname -m)")" || return
}

appimage_validate_path() {
  local path="$1" label="$2" part
  local -a parts
  case "$path" in
    ''|/*|*/|*//*|*\\*|*'*'*|*'?'*|*'['*|*']'*|*':'*|*[[:cntrl:]]*) printf 'Invalid %s: %s\n' "$label" "$path" >&2; return 2 ;;
  esac
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in .|..) printf 'Invalid %s: %s\n' "$label" "$path" >&2; return 2 ;; esac
  done
}

appimage_require_native() {
  case "$target" in amd64|arm64) ;; *) printf 'Unsupported AppImage architecture: %s\n' "$1" >&2; return 2 ;; esac
  if [ "$target" != "$host" ]; then
    printf 'AppImage verification requires a native %s host, got %s\n' "$target" "$host" >&2
    return 1
  fi
}

appimage_create_work() {
  [ -x "$image" ] || { printf 'AppImage is not executable: %s\n' "$image" >&2; return 1; }
  work="$(mktemp -d)" || return
  trap 'rm -rf -- "$work"' EXIT
}

appimage_verify_file() {
  local verifier="$1" entry expected
  shift
  appimage_require_args "$#" 4 "$0" 'APPIMAGE ARCH ENTRY SOURCE' || return $?
  appimage_init "$1" "$2" || return $?
  entry="$3"
  expected="$(realpath -e -- "$4")" || return $?
  appimage_validate_path "$entry" 'AppImage entry' || return $?
  appimage_require_native "$2" || return $?
  appimage_create_work || return $?
  (
    cd "$work" || exit $?
    "$image" --appimage-extract "$entry" > /dev/null || exit $?
    if [[ ! -d squashfs-root || -L squashfs-root ]]; then
      printf 'AppImage extraction root is missing or linked\n' >&2
      exit 1
    fi
    python3 "$verifier" squashfs-root --require "${entry}=${expected}"
  ) || return $?
  rm -rf -- "$work" || return $?
  trap - EXIT
}
