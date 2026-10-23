#!/usr/bin/env bash
# Offline runtime staging receipts cover enumeration, producer failures and package mapping, not real ELF loaders or apt databases.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_ff_runtime_worker() {
  local source="$1" root="$2" operation="$3" failure="$4" context="$5" fn status=0
  for fn in _ffmpeg_runtime_artifacts _ffmpeg_enqueue_unresolved bundle_sdk_runtime_libs emit_runtime_apt_manifest; do
    if grep -q "^${fn}() {" "$source"; then eval "$(t_fn_src "$source" "$fn")"; fi
  done
  FFMPEG_PREFIX="$root/prefix with spaces"; FFMPEG_SDK_CACHE="$root/sdk"; SUDO_WRAP=""
  export FFMPEG_SDK_CACHE SUDO_WRAP
  ensure_sudo_or_die() { :; }
  die() { printf '%s\n' "$*" >&2; exit 9; }
  ldconfig() { :; }
  objdump() { :; }
  elf_unresolved_needed() { cat "$1"; }
  elf_needed_sonames() { cat "$1"; }
  dpkg() { printf '%s: %s\n' "codec-${2##*/}" "$2"; }
  find() {
    printf '%s\n' "$*" >> "$root/find.calls"
    case "$1" in
      /usr/lib) printf '%s/distro/%s\n' "$root" "$6" ;;
      "$FFMPEG_PREFIX/bin") [ "$failure" != first ] || return 17; command find "$@" ;;
      "$FFMPEG_PREFIX/lib") [ "$failure" != second ] || return 17; command find "$@" ;;
      *) command find "$@" ;;
    esac
  }
  set -o pipefail
  case "$context" in strict-*) set -e ;; *) set +e ;; esac
  if [[ "$context" == *-conditional ]]; then
    if "$operation"; then status=0; else status=$?; fi
    return "$status"
  fi
  "$operation"
}

_ff_runtime_tree() {
  local root="$1" prefix="$1/prefix with spaces"
  mkdir -p "$prefix/bin/nested" "$prefix/lib/deeper/too-deep" "$root/sdk" "$root/distro"
  printf 'libfirst.so\n' > "$prefix/bin/tool"
  printf 'libignored.so\n' > "$prefix/bin/nested/ignored"
  printf 'libfirst.so\n' > "$prefix/lib/module.so"
  printf 'libsecond.so\n' > "$prefix/lib/deeper/leaf.so.2"
  printf 'libignored.so\n' > "$prefix/lib/deeper/too-deep/ignored.so"
  printf 'libignored.so\n' > "$prefix/lib/not-a-library.txt"
  ln -s nested/ignored "$prefix/bin/symlink"
  ln -s not-a-library.txt "$prefix/lib/symlink.so"
  printf 'libsecond.so\n' > "$root/sdk/libfirst.so"
  : > "$root/sdk/libsecond.so"
  : > "$root/sdk/libignored.so"
}

if [ "${1:-}" = --worker ]; then shift; _ff_runtime_worker "$@"; exit $?; fi
subject="${1:-${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh}"
receipt="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ -z "$receipt" ] || : > "$receipt"
for operation in bundle_sdk_runtime_libs emit_runtime_apt_manifest; do
  for failure in none first second; do
    for context in strict-direct strict-conditional relaxed-direct relaxed-conditional; do
      t_case "$operation $failure producer failure under $context"
      root="$work/$operation-$failure-$context"
      _ff_runtime_tree "$root"
      status=0
      bash "$0" --worker "$subject" "$root" "$operation" "$failure" "$context" > "$root/out" 2> "$root/err" || status=$?
      expected=0
      if [ "$operation" = emit_runtime_apt_manifest ] && [ "$failure" != none ] && [ "$context" = strict-direct ]; then expected=17; fi
      t_assert_eq "$expected" "$status"
      t_assert_eq "$root/prefix with spaces/bin -maxdepth 1 -type f" "$(head -1 "$root/find.calls")"
      prefix="$root/prefix with spaces"
      if [ "$operation" = bundle_sdk_runtime_libs ]; then
        count=2
        if [ "$failure" = first ] && [[ "$context" == strict-* ]]; then count=0; fi
        t_assert_contains "$(cat "$root/out")" "Bundled $count SDK runtime .so file(s)"
        if [ "$count" -eq 2 ]; then
          t_assert_eq libsecond.so "$(cat "$prefix/lib/libfirst.so")"
          t_assert_ok test -f "$prefix/lib/libsecond.so"
        else t_assert_fails test -e "$prefix/lib/libfirst.so"; fi
      elif [ "$expected" -eq 0 ]; then
        packages=$'codec-libfirst.so\ncodec-libsecond.so'
        if [ "$failure" = second ]; then packages=codec-libfirst.so; fi
        t_assert_eq "$packages" "$(cat "$prefix/runtime-apt-packages.txt")"
      else t_assert_fails test -e "$prefix/runtime-apt-packages.txt"; fi
      for field in out err find.calls; do
        normalized="$(sed "s|$root|ROOT|g" "$root/$field" | od -An -v -tx1 | tr -d ' \n')"
        t_record_fixture_receipt "$receipt" "$operation" "$failure" "$context" "$field" "$normalized"
      done
      t_record_fixture_receipt "$receipt" "$operation" "$failure" "$context" status "$status"
      for staged in lib/libfirst.so lib/libsecond.so runtime-apt-packages.txt; do
        bytes=missing
        if [ -f "$prefix/$staged" ]; then bytes="$(od -An -v -tx1 "$prefix/$staged" | tr -d ' \n')"; fi
        t_record_fixture_receipt "$receipt" "$operation" "$failure" "$context" "$staged" "$bytes"
      done
    done
  done
done
t_summary
