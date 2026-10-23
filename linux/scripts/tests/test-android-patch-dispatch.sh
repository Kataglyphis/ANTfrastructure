#!/usr/bin/env bash
# Records patch argv and status with a fake bash; no patch tool, SDK or build runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WRAPPER="${1:-${TESTS_DIR}/../03-media/build/gstreamer/android/build-android-from-source.sh}"
PREAMBLE="${2:-${TESTS_DIR}/../03-media/android-build-preamble.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
scripts="$work/scripts"
driver="$scripts/03-media/build/gstreamer/android/driver.sh"
helper="$scripts/03-media/android-build-preamble.sh"
project="$work/project with spaces"
mkdir -p "$(dirname "$driver")" "$project/recipes/build-tools"
t_fn_src "$PREAMBLE" android_apply_patch > "$helper"
cat > "$driver" <<'DRIVER'
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$1"
layout="$2" patch_status="$3" trace="$4"
cd "$5"
function [ {
  if [[ "$1" = -f && "$2" = /opt/scripts/core/apply-patch.sh ]]; then
    if [[ "$layout" = container ]]; then return 0; fi
    return 1
  fi
  builtin [ "$@"
}
bash() { printf '%s\n' "$#" "$@" > "$trace"; return "$patch_status"; }
DRIVER
t_fn_src "$WRAPPER" patch_cerbero_system_m4_usage >> "$driver"
printf '\npatch_cerbero_system_m4_usage\nprintf "FINISHED\\n"\n' >> "$driver"

for layout in container repository; do
  for scenario in complete missing-autoconf missing-libtool failed-patch; do
    t_case "$layout patch dispatch: $scenario"
    touch "$project/recipes/build-tools/autoconf.recipe" "$project/recipes/build-tools/libtool.recipe"
    patch_status=0 expected_status=0
    case "$scenario" in
      missing-autoconf) rm "$project/recipes/build-tools/autoconf.recipe" ;;
      missing-libtool) rm "$project/recipes/build-tools/libtool.recipe" ;;
      failed-patch) patch_status=7; expected_status=7 ;;
    esac
    trace="$work/trace"
    rm -f "$trace"
    status=0
    output="$(bash "$driver" "$helper" "$layout" "$patch_status" "$trace" "$project" 2>&1)" || status=$?
    t_assert_eq "$expected_status" "$status"
    expected_output=FINISHED
    [ "$scenario" != failed-patch ] || expected_output=''
    t_assert_eq "$expected_output" "$output" 'selected patch failure remains fatal'
    case "$scenario" in
      missing-*) t_assert_fails test -e "$trace" ;;
      *)
        prefix="$scripts"
        [ "$layout" != container ] || prefix=/opt/scripts
        expected="$(printf '%s\n' 4 "$prefix/core/apply-patch.sh" "$prefix/patches/cerbero/001-drop-m4-dependency.patch" "$project" 'Cerbero drop m4 dependency from autoconf/libtool recipes')"
        if [ "$layout" = repository ]; then expected="${expected/\/core\//\/01-core\/}"; fi
        t_assert_eq "$expected" "$(cat "$trace")" 'tool, patch, target and description retain exact argv'
        ;;
    esac
  done
done
t_summary
