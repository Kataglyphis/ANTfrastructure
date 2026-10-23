#!/usr/bin/env bash
# Offline tag receipts cover mode rejection and lazy probe behavior, not registry contents or image execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
t_fixture_workspace_init WORK
source "${TESTS_DIR}/stream-receipt-fixture.sh"
subject="${1:-${TESTS_DIR}/../01-core/tag-naming.sh}"
receipt="${2:-}"
[ -z "$receipt" ] || : > "$receipt"
cat > "$WORK/worker.sh" <<'BASH_WORKER'
set -u
harness="$1"; shift
source "${harness%/*}/shell-context-fixture.sh"
source "$1"
function_name=$2; mode=$3; context=$4; strict=$5; probe_output=$6; probe_status=$7; work=$8
if [ "$mode" = unset ]; then unset ARTIFACT_BUILD_MODE; else ARTIFACT_BUILD_MODE="$mode"; fi
case "$mode" in
  unset|''|cross|native) ARTIFACT_IMAGE_PREFIX='registry/prefix with spaces:$literal' ;;
  *) unset ARTIFACT_IMAGE_PREFIX ;;
esac
cross_build_platform() {
  printf 'cross_build_platform\n' >> "$work/trace"
  printf '%s' "$probe_output"
  printf 'probe stderr\n' >&2
  return "$probe_status"
}
[ "$strict" != strict ] || set -e
shell_fixture_run_context "$context" status "$function_name" 'target arch'
printf '%s\n' "$status" > "$work/returned"
exit "$status"
BASH_WORKER

_tag_probe_expectation() {
  expected_err=$'probe stderr\n'; expected_trace=$'cross_build_platform\n'
  if t_stream_should_abort "$1" "$2" "$3"; then
    expected_status="$3"
  elif [ -z "$4" ]; then
    expected_status=1
    expected_err+=$'[ERROR] cross_build_platform returned empty (platform.sh not loaded?)\n'
  else expected_out="$4"; fi
}

_tag_case_expectation() {
  local function_name="$1" mode="$2" context="$3" strict="$4"
  case "$mode" in
    unset|''|cross)
      if [ "$function_name" = runtime_artifact_platform ]; then _tag_probe_expectation "$strict" "$context" "$5" "$6"
      else expected_out='registry/prefix with spaces:$literal-target arch'; fi ;;
    native)
      if [ "$function_name" = runtime_artifact_platform ]; then expected_out='linux/target arch'
      else expected_out='registry/prefix with spaces:$literal'; fi ;;
    *) expected_status=1; printf -v expected_err '[ERROR] Unsupported artifact build mode: %s\n' "$mode" ;;
  esac
  expected_returned="$(t_stream_expected_return "$expected_status" "$context" "$strict")"
}

_tag_assert_case() {
  local function_name="$1" mode="$2" context="$3" strict="$4" output="$5" probe_rc="$6" status=0
  local expected_status=0 expected_out="" expected_err="" expected_trace="" expected_returned=""
  _tag_case_expectation "$function_name" "$mode" "$context" "$strict" "$probe_rc" "$7"
  t_case "$function_name $mode $context $strict probe=$probe_rc"
  t_stream_capture status "$WORK" "$WORK/worker.sh" "$subject" "$function_name" "$mode" "$context" "$strict" "$output" "$probe_rc" "$WORK"
  t_assert_eq "$expected_status" "$status"
  printf '%s' "$expected_out" > "$WORK/expected.out"
  printf '%s' "$expected_err" > "$WORK/expected.err"
  printf '%s' "$expected_trace" > "$WORK/expected.trace"
  t_stream_assert_files "$WORK" out err trace
  t_stream_assert_return "$WORK" "$expected_returned"
  t_stream_record "$receipt" "$WORK" 'out err trace' "$function_name" "$mode" "$context" "$strict" "$output" "$probe_rc" "$status"
}

for context in direct conditional; do
  for strict in strict relaxed; do
    for mode in unset '' cross native bogus 'mode with spaces' $'bad\nmode'; do
      for function_name in runtime_artifact_platform runtime_artifact_image_ref; do
        _tag_assert_case "$function_name" "$mode" "$context" "$strict" 'linux/host with spaces' 0 'linux/host with spaces'
      done
    done
    _tag_assert_case runtime_artifact_platform cross "$context" "$strict" '' 0 ''
    _tag_assert_case runtime_artifact_platform cross "$context" "$strict" 'linux/failed probe' 7 'linux/failed probe'
    _tag_assert_case runtime_artifact_platform cross "$context" "$strict" '' 7 ''
    _tag_assert_case runtime_artifact_platform cross "$context" "$strict" $'linux/embedded\nnewline\n' 0 $'linux/embedded\nnewline'
  done
done
t_summary
