#!/usr/bin/env bash
# Extracted real GStreamer calls cover callback bindings, not actual target Python files or builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COLLECTOR="${1:-${TESTS_DIR}/../01-core/cross-python.sh}"
CALLER="${2:-${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
t_fn_src "${COLLECTOR}" cross_collect_python_dev_paths > "${WORK}/worker.sh" || exit 1
t_fn_src "${COLLECTOR}" cross_capture_python_dev_path >> "${WORK}/worker.sh" || exit 1
t_fn_src "${COLLECTOR}" cross_python_provider_api_ready >> "${WORK}/worker.sh" || exit 1
t_fn_src "${CALLER}" _gst_xpy_resolve_target_paths >> "${WORK}/worker.sh" || exit 1
cat >> "${WORK}/worker.sh" <<'BASH'
field=GLOBAL_FIELD probe=GLOBAL_PROBE python_paths=GLOBAL_PATHS
cross_target_triplet() { printf x86_64-linux-gnu; }
cross_target_python_include_dir() { printf '%s/%s/%s' "$field" "$probe" "$python_paths"; }
cross_target_python_library() { printf '%s/%s/%s' "$field" "$probe" "$python_paths"; }
cross_target_python_pkgconfig_dir() { printf '%s/%s/%s' "$field" "$probe" "$python_paths"; }
target_python_include='' target_python_library='' target_python_pkgconfig_dir=''
run_actual_caller() {
 local -A captured=()
 cross_collect_python_dev_paths captured include_dir
 printf 'COLLECTOR:%s\n' "${captured[include_dir]}"
 _gst_xpy_resolve_target_paths
 printf 'VALUES:%s|%s|%s\n' "$target_python_include" "$target_python_library" "$target_python_pkgconfig_dir"
}
run_with_caller_locals() {
 local field=CALLER_FIELD probe=CALLER_PROBE python_paths=CALLER_PATHS
 run_actual_caller
}
run_both() {
 run_actual_caller
 run_with_caller_locals
 printf 'GLOBALS:%s/%s/%s\n' "$field" "$probe" "$python_paths"
}
if [ "$1" = conditional ]; then
 if run_both; then printf 'STATUS:0\n'; else printf 'STATUS:%s\n' "$?"; fi
else
 run_both
 printf 'STATUS:%s\n' "$?"
fi
BASH
expected=$'COLLECTOR:GLOBAL_FIELD/GLOBAL_PROBE/GLOBAL_PATHS\nVALUES:GLOBAL_FIELD/GLOBAL_PROBE/GLOBAL_PATHS|GLOBAL_FIELD/GLOBAL_PROBE/GLOBAL_PATHS|GLOBAL_FIELD/GLOBAL_PROBE/GLOBAL_PATHS\nCOLLECTOR:CALLER_FIELD/CALLER_PROBE/CALLER_PATHS\nVALUES:CALLER_FIELD/CALLER_PROBE/CALLER_PATHS|CALLER_FIELD/CALLER_PROBE/CALLER_PATHS|CALLER_FIELD/CALLER_PROBE/CALLER_PATHS\nGLOBALS:GLOBAL_FIELD/GLOBAL_PROBE/GLOBAL_PATHS\nSTATUS:0'
for strict in strict relaxed; do
  for context in direct conditional; do
    t_case "actual GStreamer probes preserve global and caller-local bindings: $strict $context"
    flags=-u
    [ "$strict" != strict ] || flags=-eu
    rc=0
    out="$(bash "${flags}" "${WORK}/worker.sh" "${context}" 2> "${WORK}/err")" || rc=$?
    t_assert_eq 0 "$rc"
    t_assert_eq "$expected" "$out"
    t_assert_eq '' "$(cat "${WORK}/err")"
  done
done
t_case 'legacy collector retains arbitrary fields, partial output, absent defaults and empty requests'
t_source_functions "$COLLECTOR" cross_collect_python_dev_paths
cross_target_python_custom_field() { printf custom-partial; return 7; }
t_case 'the literal provider fixture returns partial output with a failure status'
rc=0
out="$(cross_target_python_custom_field)" || rc=$?
t_assert_eq 7 "$rc"
t_assert_eq custom-partial "$out"
t_case 'the same provider resolves dynamically without changing absent-field defaults'
declare -A custom_paths=([absent_field]=keep-absent)
cross_collect_python_dev_paths custom_paths custom_field absent_field
t_assert_eq custom-partial "${custom_paths[custom_field]}"
t_assert_eq keep-absent "${custom_paths[absent_field]}"
t_assert_eq 0 "$(t_rc cross_collect_python_dev_paths custom_paths)"
t_assert_eq custom-partial "${custom_paths[custom_field]}"
t_case 'legacy optional partial output remains advisory under direct errexit'
t_fn_src "$COLLECTOR" cross_collect_python_dev_paths > "${WORK}/legacy.sh" || exit 1
cat >> "${WORK}/legacy.sh" <<'BASH'
cross_target_python_custom_field() { printf custom-partial; return 7; }
declare -A captured=()
cross_collect_python_dev_paths captured custom_field
printf '%s' "${captured[custom_field]}"
BASH
rc=0
out="$(bash -eu "${WORK}/legacy.sh" 2> "${WORK}/err")" || rc=$?
t_assert_eq 0 "$rc"
t_assert_eq custom-partial "$out"
t_assert_eq '' "$(cat "${WORK}/err")"
t_summary
