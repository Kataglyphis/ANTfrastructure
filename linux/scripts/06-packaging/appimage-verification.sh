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
