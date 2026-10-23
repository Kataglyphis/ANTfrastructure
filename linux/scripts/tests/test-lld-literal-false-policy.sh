#!/usr/bin/env bash
# Offline build-argument fixtures cover literal-false policy and probe statuses, not real linking or cache startup.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/compiler-tool-fixture.sh"
t_compiler_tool_fixture_init build-ffmpeg.sh "$@"
# shellcheck source=../01-core/compiler-cache-utils.sh
source "$UTILS"
eval "$(t_fn_src "$FFMPEG" _ffmpeg_linker_ccache_args)"
eval "$(t_fn_src "$ORT" append_onnx_lld_build_args)"
command() {
  if [ "$1" = -v ] && [ "$2" = ld.lld ]; then
    printf 'lookup:ld.lld\n' >> "$WORK/trace"
    printf 'lookup stdout\n'; printf 'lookup stderr\n' >&2
    return "$_lld_lookup_status"
  fi
  builtin command "$@"
}
media_compiler_launcher() { printf 'launcher\n' >> "$WORK/trace"; printf -v "$1" '%s' ''; }
cross_build_is_active() { printf 'cross\n' >> "$WORK/trace"; return 1; }
info() { printf 'INFO %s\n' "$*"; }

_lld_hex() { od -An -v -tx1 "$1" | tr -d ' \n'; }

_lld_assert_case() {
  local function="$1" flag="$2" _lld_lookup_status="$3" predicate expected_predicate status=0 actual_predicate=0 enabled=0
  local argv expected_argv='<existing value>' expected_log="" expected_trace=$'lookup:ld.lld\n'
  local -a args=('existing value')
  if [ "$flag" = unset ]; then unset USE_LLD; else USE_LLD="$flag"; fi
  expected_predicate="$_lld_lookup_status"
  if [ "$_lld_lookup_status" -eq 0 ]; then
    expected_predicate=0
    if [ "$flag" = false ]; then expected_predicate=1; else enabled=1; fi
  fi
  t_case "$function flag=$flag lookup=$_lld_lookup_status"
  predicate="$(declare -f "$function" | sed -n 's/^[[:space:]]*if \(.*\); then$/\1/p' | head -1)"
  : > "$WORK/trace"
  eval "$predicate" > "$WORK/predicate.out" 2> "$WORK/predicate.err" || actual_predicate=$?
  t_assert_eq "$expected_predicate" "$actual_predicate"
  t_assert_fails test -s "$WORK/predicate.out"
  t_assert_fails test -s "$WORK/predicate.err"
  t_assert_eq lookup:ld.lld "$(cat "$WORK/trace")"
  : > "$WORK/trace"
  "$function" args > "$WORK/out" 2> "$WORK/err" || status=$?
  if [ "$function" = _ffmpeg_linker_ccache_args ]; then
    expected_trace+=$'launcher\ncross\n'
    if [ "$enabled" -eq 1 ]; then
      expected_argv+='<--extra-ldflags=-fuse-ld=lld>'
      expected_log=$'Using lld linker for faster linking\n'
    fi
  elif [ "$enabled" -eq 1 ]; then
    expected_argv+='<--cmake_extra_defines><CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld><CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld><CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld>'
    expected_log=$'INFO Using lld linker for faster linking\n'
  fi
  printf '%s' "$expected_log" > "$WORK/expected.out"
  printf '%s' "$expected_trace" > "$WORK/expected.trace"
  argv="$(printf '<%s>' "${args[@]}")"
  t_assert_eq 0 "$status"
  t_assert_eq "$expected_argv" "$argv"
  t_assert_eq "$(_lld_hex "$WORK/expected.out")" "$(_lld_hex "$WORK/out")"
  t_assert_eq "$(_lld_hex "$WORK/expected.trace")" "$(_lld_hex "$WORK/trace")"
  t_assert_fails test -s "$WORK/err"
  t_assert_eq "$flag" "${USE_LLD-unset}"
  t_record_fixture_receipt "$RECEIPT" "$function" "$flag" "$_lld_lookup_status" "$actual_predicate" "$status" "$argv" \
    "$(_lld_hex "$WORK/predicate.out")" "$(_lld_hex "$WORK/predicate.err")" "$(_lld_hex "$WORK/out")" "$(_lld_hex "$WORK/err")" "$(_lld_hex "$WORK/trace")"
}

t_case 'compiler-tool subjects retain positional overrides and reset a requested receipt'
printf stale > "$WORK/init.receipt"
init_result="$(
  t_fixture_workspace_init() { printf 'init:%s\n' "$1"; }
  t_compiler_tool_fixture_init build-ffmpeg.sh 'fixture ffmpeg' 'fixture ort' 'fixture utils' "$WORK/init.receipt"
  printf '%s\n' "$FFMPEG" "$ORT" "$UTILS" "$RECEIPT"
)"
t_assert_eq "$(printf '%s\n' init:WORK 'fixture ffmpeg' 'fixture ort' 'fixture utils' "$WORK/init.receipt")" "$init_result"
t_assert_fails test -s "$WORK/init.receipt"

for lookup in 0 1 7 127; do
  for flag in unset '' true false False FALSE 0 no off arbitrary $'spaces and\nnewlines'; do
    for function in _ffmpeg_linker_ccache_args append_onnx_lld_build_args; do
      _lld_assert_case "$function" "$flag" "$lookup"
    done
  done
done
t_summary
