#!/usr/bin/env bash
# Disposable library trees and recorded ln failures cover link eligibility and ordering, not packages, compilers or live system directories.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ROOT="${1:-${TESTS_DIR}/..}"
RECEIPT="${2:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
_media_link_context_contract() {
  local fixture="$2" strict context output status expected expected_status
  cat > "$fixture/context.sh" <<'CONTEXT'
set -uo pipefail
source "$(dirname "$1")/shell-context-fixture.sh"
context="$2"; strict="$3"
[ "$strict" != strict ] || set -e
operation() { printf 'OP [%s] <%s> <%s>\n' "$#" "$1" "$2"; return 19; }
shell_fixture_run_context "$context" result operation 'a b' ''
printf 'AFTER status=%s\n' "$result"
CONTEXT
  for strict in strict relaxed; do
    for context in direct conditional; do
      t_case "fixture context $context $strict retains argv and raw status"
      t_capture_command output status t_run_fixture_worker "$fixture/context.sh" "$context" "$strict"
      expected='OP [2] <a b> <>'; expected_status=0
      if [ "$strict/$context" = strict/direct ]; then expected_status=19; else expected+=$'\nAFTER status=19'; fi
      t_assert_eq "$expected_status" "$status"
      t_assert_eq "$expected" "$output"
    done
  done
  t_case 'unknown fixture contexts fail before executing the operation'
  t_capture_command output status t_run_fixture_worker "$fixture/context.sh" invalid strict
  t_assert_eq 2 "$status"
  t_assert_contains "$output" 'Unknown shell fixture context: invalid'
  t_assert_eq 1 "$(t_rc grep -q '^OP ' <<< "$output")"
}
_t_probe_file _media_link_context_contract

_media_link_worker() {
  local fixture="$1" common="$2" build="$3" arm_install="$4" ff_install="$5"
  printf 'source %q\n' "$common" > "$fixture/functions.sh"
  t_fn_src "$build" _armnn_link_openmp >> "$fixture/functions.sh"
  t_fn_src "$ff_install" _ffmpeg_ensure_vidstab_linkable | sed "s|/usr/lib/|$fixture/lib/|g" >> "$fixture/functions.sh"
  awk '/^# Arm NN links -lgomp/ {p=1; next} p {print} p && /^fi$/ {exit}' "$arm_install" | sed "s|/usr/lib/|$fixture/lib/|g" > "$fixture/install.sh"
  cat > "$fixture/worker.sh" <<'WORKER'
set -uo pipefail
source "$(dirname "$1")/shell-context-fixture.sh"
fixture="$2"; consumer="$3"; scenario="$4"; strict="$5"; context="$6"; link_status="$7"
source "$fixture/functions.sh"
set +e
[ "$strict" != strict ] || set -e
is_cross() { [ "$scenario" != non-cross ]; }
cross_target_triplet() {
  [ "$scenario" != empty-triplet ] || return 0
  printf fixture-triplet
  [ "$scenario" != triplet-failed ] || return 29
}
info() { printf 'INFO %s\n' "$*"; }
ln() {
  printf 'LN'; printf ' <%q>' "$@"; printf '\n'
  [ "$link_status" = 0 ] || return "$link_status"
  command ln "$@"
}
run_case() {
  case "$consumer" in
    build-relative) _armnn_link_openmp "$fixture/lib/fixture-triplet/libgomp.so" libgomp.so.1 'created fixture link' ;;
    build-absolute) _armnn_link_openmp "$fixture/lib/fixture-triplet/libgomp.so" "$fixture/absolute source/libgomp.so.1" 'created fixture link' ;;
    install) source "$fixture/install.sh" ;;
    ffmpeg) _ffmpeg_ensure_vidstab_linkable ;;
  esac
  printf 'TAIL\n'
}
shell_fixture_run_context "$context" case_status run_case
if [ "$context" = conditional ]; then
  if [ "$case_status" = 0 ]; then printf 'CONTEXT_OK\n'; else printf 'CONTEXT_RC=%s\n' "$case_status"; fi
else
  exit "$case_status"
fi
WORKER
}

_media_link_fixture() {
  local fixture="$1" consumer="$2" scenario="$3" dest source_file
  local -n _mlf_action="$4" _mlf_source_arg="$5"
  _mlf_action=yes
  mkdir -p "$fixture/lib/fixture-triplet" "$fixture/absolute source"
  dest="$fixture/lib/fixture-triplet/libgomp.so"; source_file="${dest}.1"; _mlf_source_arg=libgomp.so.1
  if [ "$consumer" = build-absolute ]; then source_file="$fixture/absolute source/libgomp.so.1"; _mlf_source_arg="$source_file"; fi
  printf 'runtime bytes\n' > "$source_file"
  case "$scenario" in
    missing-source) rm "$source_file"; _mlf_action=no ;;
    missing-directory) rm -r "$fixture/lib/fixture-triplet"; _mlf_action=no ;;
    regular) printf 'existing dev bytes\n' > "$dest"; _mlf_action=no ;;
    live-link) ln -s "$source_file" "$dest"; _mlf_action=no ;;
    dangling-link) ln -s vanished.so "$dest" ;;
    source-link) mv "$source_file" "$fixture/runtime bytes"; ln -s "$fixture/runtime bytes" "$source_file" ;;
    dangling-source) rm "$source_file"; ln -s vanished.so "$source_file"; _mlf_action=no ;;
    source-directory) rm "$source_file"; mkdir "$source_file" ;;
    non-cross|empty-triplet) case "$consumer" in install|ffmpeg) _mlf_action=no ;; esac ;;
  esac
}

_media_link_vidstab_verdict() {
  local consumer="$1" scenario="$2" status="$3" output="$4" dest="$5"
  [ "$consumer" = ffmpeg ] || return 0
  case "$scenario/$status" in
    non-cross/*|empty-triplet/*|missing-directory/*|*/23) t_assert_eq 1 "$(t_rc grep -q '^NOTE:' <<< "$output")" ;;
    *) t_assert_contains "$output" "NOTE: ${dest%/*}/libvidstab.so still absent" ;;
  esac
}

_media_link_case() {
  local consumer="$1" scenario="$2" strict="$3" context="$4" link_status="$5" fixture="$7"
  local common build arm_install ff_install dest output status expected_status=0 action=yes source_arg expected_link actual_link before
  if [ -f "$ROOT/03-media/core/common.sh" ]; then
    common="$ROOT/03-media/core/common.sh"; build="$ROOT/03-media/build/armnn/build-armnn.sh"
    arm_install="$ROOT/03-media/build/armnn/install-deps.sh"; ff_install="$ROOT/03-media/build/ffmpeg/install-deps.sh"
  else
    common="$ROOT/common.sh"; build="$ROOT/build-armnn.sh"; arm_install="$ROOT/armnn-install-deps.sh"; ff_install="$ROOT/ffmpeg-install-deps.sh"
  fi
  dest="$fixture/lib/fixture-triplet/libgomp.so"
  _media_link_fixture "$fixture" "$consumer" "$scenario" action source_arg
  expected_link=''
  [ ! -L "$dest" ] || expected_link="$(readlink "$dest")"
  _media_link_worker "$fixture" "$common" "$build" "$arm_install" "$ff_install"
  t_case "$consumer $scenario $strict $context ln=$link_status"
  t_capture_command output status t_run_fixture_worker "$fixture/worker.sh" "$fixture" "$consumer" "$scenario" "$strict" "$context" "$link_status"
  if [ "$action/$link_status/$strict/$context" = yes/23/strict/direct ]; then expected_status=23; fi
  t_assert_eq "$expected_status" "$status"
  if [ "$action" = yes ]; then
    t_assert_contains "$output" 'LN <-sf>'
    if [ "$link_status" = 0 ]; then expected_link="$source_arg"; fi
    if [[ "$consumer" = build-* ]]; then
      if [ "$expected_status" = 0 ]; then t_assert_contains "$output" $'\nINFO created fixture link'; else t_assert_eq 1 "$(t_rc grep -q '^INFO ' <<< "$output")"; fi
    else
      before="Creating $dest -> libgomp.so.1 (libgomp1 ships no dev symlink)"
      [ "$consumer" != ffmpeg ] || before="Creating $dest -> libgomp.so.1 (libgomp1 ships no dev symlink; the cross toolchain has no target libgomp)"
      t_assert_contains "$output" "$before"$'\nLN <-sf>'
    fi
  else
    t_assert_eq 1 "$(t_rc grep -q '^LN ' <<< "$output")"
  fi
  actual_link=''; [ ! -L "$dest" ] || actual_link="$(readlink "$dest")"
  t_assert_eq "$expected_link" "$actual_link"
  if [ "$expected_status" = 0 ]; then t_assert_contains "$output" TAIL; else t_assert_eq 1 "$(t_rc grep -q TAIL <<< "$output")"; fi
  _media_link_vidstab_verdict "$consumer" "$scenario" "$expected_status" "$output" "$dest"
  t_record_fixture_receipt "$RECEIPT" "$consumer/$scenario/$strict/$context/$link_status" "$status" "${output//${fixture}/FIXTURE}" "${actual_link//${fixture}/FIXTURE}" "$(if [ -f "$dest" ] && [ ! -L "$dest" ]; then cat "$dest"; fi)"
}
for consumer in build-relative build-absolute install ffmpeg; do
  for scenario in absent missing-source missing-directory regular live-link dangling-link source-link dangling-source source-directory non-cross empty-triplet triplet-failed; do
    for strict in strict relaxed; do
      for context in direct conditional; do
        for link_status in 0 23; do
          if [ "$scenario" != absent ] && [ "$strict/$context/$link_status" != strict/direct/0 ]; then continue; fi
          _t_probe_file _media_link_case "$consumer" "$scenario" "$strict" "$context" "$link_status"
        done
      done
    done
  done
done
t_summary
