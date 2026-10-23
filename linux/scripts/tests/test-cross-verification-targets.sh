#!/usr/bin/env bash
# Stubbed verifier callbacks cover target dispatch and environment restoration, not compilers or target execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
verify_source="${1:-${TESTS_DIR}/../01-core/verify.sh}"
llvm_source="${2:-${TESTS_DIR}/../02-toolchain/llvm-validate.sh}"
platform_source="${3:-${TESTS_DIR}/../01-core/platform.sh}"
cat > "$work/worker" <<'WORKER'
set -euo pipefail
source "$1"
source "$2"
source "$3"
shift 3
probe="$1" mode="$2" configured="$3" resolver="$4" raw="$5" initial="$6" callback_status="$7"
unset VERIFY_CROSS_TARGETS CROSS_TARGETS ARCH TARGETARCH TARGET_ARCH
if [ "$initial" = old ]; then export ARCH=old TARGETARCH=old-target TARGET_ARCH=old-config; fi
if [ "$initial" = empty ]; then export ARCH='' TARGETARCH='' TARGET_ARCH=''; fi
export VERIFY_CROSS_TARGETS="$configured"
IFS=$'\n\t'
verify_cross_mode_requested() { if [ "$mode" = cross ]; then return 0; fi; return 1; }
cross_mode_requested() { verify_cross_mode_requested; }
log() { printf '%s\n' "$*"; }
verify_cross_target_versions() { printf 'TARGET:%s|%s|%s\n' "$ARCH" "$TARGETARCH" "$TARGET_ARCH"; return "$callback_status"; }
for_each_cross_target() { printf 'LLVM:%s:%s\n' "$1" "$2"; return "$callback_status"; }
if [ "$resolver" != absent ]; then
  cross_effective_targets_raw() {
    printf '%s' "$raw"
    if [ "$resolver" = fail ]; then return 17; fi
    return 0
  }
fi
if [ "$probe" = versions ]; then verify_all_cross_target_versions; else verify_cross_llvm_targets; fi
printf 'STATE:%s|%s|%s\n' "${ARCH-unset}" "${TARGETARCH-unset}" "${TARGET_ARCH-unset}"
WORKER

_verification_case() {
  local expected_status="$1" expected_output="$2" actual status=0
  shift 2
  actual="$(bash "$work/worker" "$platform_source" "$verify_source" "$llvm_source" "$@" 2>&1)" || status=$?
  t_assert_eq "$expected_status" "$status"
  t_assert_eq "$expected_output" "$actual"
}
old_state='STATE:old|old-target|old-config'
unset_state='STATE:unset|unset|unset'
for probe in versions llvm; do
  t_case "$probe skips native mode without resolving the list"
  _verification_case 0 "$old_state" "$probe" native arm64 fail arm64 old 0
  t_case "$probe honors an empty resolver instead of falling back"
  _verification_case 0 "$old_state" "$probe" cross arm64 value '' old 0
  t_case "$probe preserves resolver failures with and without partial output"
  _verification_case 17 '' "$probe" cross arm64 fail '' old 0
  _verification_case 17 '' "$probe" cross arm64 fail arm64 old 0
  t_case "$probe dispatches aliases with a nondefault IFS and restores the caller"
  expected=$'TARGET:arm64|arm64|arm64\nTARGET:riscv64|riscv64|riscv64'
  [ "$probe" != llvm ] || expected='LLVM:verify_cross_llvm_target:arm64,riscv64'
  _verification_case 0 "$expected"$'\n'"$old_state" "$probe" cross amd64 value 'aarch64,riscv64' old 0
  t_case "$probe skips unsupported normalized lists with its own diagnostic policy"
  expected="$old_state"
  [ "$probe" != llvm ] || expected=$'Skipping unsupported LLVM cross verification target list: \n'"$old_state"
  _verification_case 0 "$expected" "$probe" cross unknown absent '' old 0
  t_case "$probe retains its legacy no-override fallback"
  expected="$unset_state"
  [ "$probe" != llvm ] || expected=$'LLVM:verify_cross_llvm_target:amd64,arm64,riscv64\n'"$unset_state"
  _verification_case 0 "$expected" "$probe" cross '' absent '' unset 0
  t_case "$probe honors configured targets without an optional resolver"
  expected='TARGET:arm64|arm64|arm64'
  [ "$probe" != llvm ] || expected='LLVM:verify_cross_llvm_target:arm64'
  restored_state="$unset_state"
  [ "$probe" != llvm ] || restored_state='STATE:||'
  _verification_case 0 "$expected"$'\n'"$restored_state" "$probe" cross arm64 absent '' empty 0
  t_case "$probe propagates a failed verifier before later work"
  _verification_case 23 "$expected" "$probe" cross arm64 absent '' old 23
done
t_summary
