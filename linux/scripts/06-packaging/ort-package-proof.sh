#!/usr/bin/env bash
# Keeps a finished package's ORT libraries and notices inside its root; it does not compare libraries with a wheel.

_ort_package_inside() {
  local resolved
  resolved="$(realpath -e "$2")" || return 1
  case "$resolved/" in "$1/"*) return 0 ;; esac
  printf '%s\n' "$3" >&2
  return 1
}

_ort_package_check_library() {
  local root="$1" file="$2" name resolved
  _ort_package_inside "$root" "$file" 'ORT library escapes package' || return 1
  resolved="$(realpath -e "$file")" || return 1
  name="${file##*/}"
  case "$name" in
    libonnxruntime_providers_*)
      [ ! -L "$file" ] || { printf 'ORT provider is a symlink: %s\n' "$name" >&2; return 1; } ;;
    libonnxruntime.so*)
      [[ "${resolved##*/}" =~ ^libonnxruntime\.so(\.[0-9]+)*$ ]] || {
        printf 'ORT core aliases another component: %s\n' "$name" >&2; return 1;
      } ;;
  esac
  return 0
}

_ort_package_refuse_link() {
  [ "$1" = 1 ] || [ ! -L "$2" ] || { printf 'Linked GPU ORT library: %s\n' "$2" >&2; return 1; }
  return 0
}

_ort_package_check_required() {
  local lib="$1" allow_links="$2" name
  shift 2
  for name in "$@"; do
    [ -f "$lib/$name" ] || { printf 'Missing GPU ORT library: %s\n' "$name" >&2; return 1; }
    _ort_package_refuse_link "$allow_links" "$lib/$name" || return 1
  done
  return 0
}

# Usage: ort_package_collect_libraries [--reject-invalid] [--reject-links] ROOT LIB_DIR OUT_ARRAY REQUIRED...
ort_package_collect_libraries() {
  local skip_invalid=1 allow_links=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reject-invalid) skip_invalid=0 ;;
      --reject-links) allow_links=0 ;;
      *) break ;;
    esac
    shift
  done
  local root lib="$2" file
  local -n _ort_package_out="$3"
  root="$(realpath -e "$1")" || return 1
  shift 3
  _ort_package_check_required "$lib" "$allow_links" "$@" || return 1
  for file in "$lib"/libonnxruntime*.so*; do
    if [ ! -f "$file" ]; then
      [ "$skip_invalid" = 1 ] && continue
      printf 'Invalid ORT library: %s\n' "$file" >&2
      return 1
    fi
    _ort_package_refuse_link "$allow_links" "$file" || return 1
    _ort_package_check_library "$root" "$file" || return 1
    _ort_package_out+=(--library "$file")
  done
  return 0
}

# Usage: ort_package_verify_notices ROOT NOTICE_DIR PROOF_DIR
ort_package_verify_notices() {
  local root notice_dir="$2" proof_dir="$3" name notice
  root="$(realpath -e "$1")" || return 1
  for name in LICENSE ThirdPartyNotices.txt; do
    notice="$notice_dir/$name"
    [ -f "$notice" ] && [ ! -L "$notice" ] || { printf 'Missing or linked ORT notice: %s\n' "$notice" >&2; return 1; }
    _ort_package_inside "$root" "$notice" 'ORT notice escapes package' || return 1
    cmp "$notice" "$proof_dir/$name" || return 1
  done
  return 0
}
