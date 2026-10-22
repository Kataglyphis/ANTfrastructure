#!/usr/bin/env bash
# _runtime_timed's heartbeat: silent under the first threshold, periodic while a step runs, and stopped when it ends (CON157).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FNS="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_heartbeat)" || exit 1
FNT="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_timed)" || exit 1
_LOG="$(mktemp)"
trap 'rm -f "${_LOG}"' EXIT
log() { echo "$*" >> "${_LOG}"; }
eval "${FNS}"
eval "${FNT}"

t_case "a step under the first threshold prints no heartbeat"
: > "${_LOG}"
RUNTIME_HEARTBEAT_FIRST_SECS=5 RUNTIME_HEARTBEAT_EVERY_SECS=1 _runtime_timed quick amd64 sleep 0.2
t_assert_eq "0" "$(grep -c heartbeat "${_LOG}")"

t_case "a long step prints heartbeats, then the timing line, and the heartbeat stops"
: > "${_LOG}"
RUNTIME_HEARTBEAT_FIRST_SECS=1 RUNTIME_HEARTBEAT_EVERY_SECS=1 _runtime_timed long riscv64 sleep 3.5
t_assert_eq "1" "$([ "$(grep -c '\[heartbeat riscv64 long\]' "${_LOG}")" -ge 2 ] && echo 1 || echo 0)"
t_assert_contains "$(tail -n 1 "${_LOG}")" "[runtime-timing] arch=riscv64 step=long"
before="$(wc -l < "${_LOG}")"
sleep 2.5
t_assert_eq "${before}" "$(wc -l < "${_LOG}")"

t_summary
