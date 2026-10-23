#!/usr/bin/env bash
# Actual probe and cache consumers run with stubbed tools; no compiler, cache server, build or network operation runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/compiler-tool-fixture.sh"
t_compiler_tool_fixture_init ffmpeg-probe-framework.sh "$@"
t_fn_src "$ORT" append_onnx_ccache_build_args > "$WORK/ort-functions.sh"
t_fn_src "$ORT" _onnx_compiler_cache_launcher >> "$WORK/ort-functions.sh"
cat > "$WORK/worker.sh" <<'BASH'
set -u
harness="$1" contexts="$2" utils="$3" ffmpeg="$4" ort="$5" work="$6" consumer="$7" flag="$8" available="$9"
shift 9
context="$1" strict="$2" preconfigured="$3" failure="$4"
source "$harness"
source "$contexts"
source "$utils"
source "$ffmpeg"
source "$ort"
command() {
  case "${2:-}" in
    ld.lld|ccache)
      printf 'lookup:%s\n' "$2" >> "$work/calls"
      printf 'resolved optional tool\n'
      printf 'optional lookup diagnostic\n' >&2
      t_command_available_override "$2" "$available" "$@" ;;
    *) builtin command "$@" ;;
  esac
}
cross_build_is_active() { return 1; }
info() { printf 'INFO:%s\n' "$*"; }
compiler_cache_launcher_env() { printf 'environment\n' >> "$work/calls"; export TOOL_ENV=retained; return 7; }
compiler_cache_launcher() { printf 'launcher\n' >> "$work/calls"; printf '%s' sccache-guard; }
fixture_cc() {
  local arg
  for arg in "$@"; do
    case "$arg" in /tmp/*/probe.c) arg=SOURCE ;; /tmp/*/probe) arg=OUTPUT ;; esac
    printf '<%s>' "$arg" >> "$work/calls"
  done
  printf '\n' >> "$work/calls"
  printf 'suppressed compiler output\n'
  printf 'suppressed compiler error\n' >&2
  return "$failure"
}
CC=fixture_cc
if [ "$flag" = unset ]; then unset USE_LLD USE_CCACHE; else USE_LLD="$flag"; USE_CCACHE="$flag"; fi
CMAKE_C_COMPILER_LAUNCHER="$preconfigured"
run_consumer() {
  if [ "$consumer" = ffmpeg ]; then
    ffmpeg_try_link_probe '' '' '-O2 -DKEEP=1' '-lm -pthread'
  else
    local -a build_args=(original)
    append_onnx_ccache_build_args build_args
    printf 'ARGS:'; printf '<%s>' "${build_args[@]}"; printf '\nENV:%s\n' "${TOOL_ENV-unset}"
  fi
}
[ "$strict" = relaxed ] || set -e
shell_fixture_run_context "$context" status run_consumer
printf 'RETURNED:%s\n' "$status"
BASH

_tool_toggle_expected_calls() {
  if [ "$1" = ffmpeg ]; then
    printf 'lookup:ld.lld\n'
    [ "$2" = 0 ] || printf '<-fuse-ld=lld>'
    printf '<-O2><-DKEEP=1><SOURCE><-o><OUTPUT><-lm><-pthread>'
  else
    printf 'lookup:ccache'
    if [ "$2" = 1 ] && [ -z "$3" ]; then printf '\nenvironment\nlauncher'; fi
  fi
}

_tool_toggle_case() {
  local consumer="$1" flag="$2" available="$3" context="$4" strict="$5" preconfigured="$6" failure="$7"
  local enabled=1 expected_calls expected_out expected_rc=0 actual_rc=0
  case "$flag" in 0|false|FALSE|no|NO|off|OFF) enabled=0 ;; esac
  [ "$available" = 1 ] || enabled=0
  : > "$WORK/calls"
  bash "$WORK/worker.sh" "$TESTS_DIR/test-harness.sh" "$TESTS_DIR/shell-context-fixture.sh" "$UTILS" "$FFMPEG" "$WORK/ort-functions.sh" "$WORK" "$consumer" "$flag" "$available" "$context" "$strict" "$preconfigured" "$failure" > "$WORK/out" 2> "$WORK/err" || actual_rc=$?
  if [ "$consumer" = ffmpeg ]; then
    expected_out=RETURNED:0
    if [ "$failure" != 0 ]; then
      expected_out=RETURNED:1
      if [ "$context" = direct ] && [ "$strict" = strict ]; then expected_rc=1; expected_out=''; fi
    fi
  else
    expected_out=$'ARGS:<original>\nENV:unset\nRETURNED:0'
    if [ "$enabled" = 1 ]; then
      if [ -n "$preconfigured" ]; then
        expected_out="INFO:ccache already configured via environment (CMAKE_C_COMPILER_LAUNCHER=${preconfigured})"$'\n'"${expected_out}"
      else
        expected_out=$'INFO:Using sccache-guard for faster compilation (via cmake_extra_defines)\nARGS:<original><--cmake_extra_defines><CMAKE_C_COMPILER_LAUNCHER=sccache-guard><CMAKE_CXX_COMPILER_LAUNCHER=sccache-guard>\nENV:retained\nRETURNED:0'
      fi
    fi
  fi
  expected_calls="$(_tool_toggle_expected_calls "$consumer" "$enabled" "$preconfigured")"
  t_case "$consumer flag='$flag' available=$available $context/$strict preconfigured='$preconfigured' failure=$failure"
  t_assert_eq "$expected_rc" "$actual_rc"
  t_assert_eq "$expected_out" "$(cat "$WORK/out")"
  t_assert_eq "$expected_calls" "$(cat "$WORK/calls")"
  t_assert_eq '' "$(cat "$WORK/err")"
  t_record_fixture_receipt "$RECEIPT" "$consumer" "$flag" "$available" "$context" "$strict" "$preconfigured" "$failure" "$actual_rc" "$(cat "$WORK/out")" "$(cat "$WORK/calls")" "$(cat "$WORK/err")"
}

for consumer in ffmpeg ort; do
  for flag in unset '' 0 false FALSE False no NO off OFF true 1 yes on No Off falsee; do
    for available in 0 1; do
      for context in direct conditional; do
        for strict in relaxed strict; do _tool_toggle_case "$consumer" "$flag" "$available" "$context" "$strict" '' 0; done
      done
    done
  done
done
for context in direct conditional; do
  for strict in relaxed strict; do
    _tool_toggle_case ffmpeg true 1 "$context" "$strict" '' 7
    _tool_toggle_case ort true 1 "$context" "$strict" 'existing launcher' 0
  done
done

t_summary
