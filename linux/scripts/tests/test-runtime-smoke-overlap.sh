#!/usr/bin/env bash
# The wrapper-smoke gate runs beside the wrapper build, and nothing of the arch ships before its verdict.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RBF="${TESTS_DIR}/../01-core/runtime-build-fns.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_FNS=""
for _fn in runtime_build_chain _runtime_smoke_start _runtime_smoke_wait _runtime_timed \
           runtime_build_wrapper_image runtime_build_wrapper_rootfs _runtime_push_wrapper_tag; do
  _FNS+="$(t_fn_src "${RBF}" "${_fn}")"$'\n' || exit 1
done

# Each step appends "<what> <epoch>" to ${E}; SMOKE_RC/WRAP_RC fail a step, SMOKE_SECS/WRAP_SECS make it last.
_mark_step() { echo "$1 $(date +%s)" >> "${E}"; }
_say() { echo "$*"; }
_STUBS="$(declare -f _mark_step _say)"'
log() { _say "$@"; }
warn() { _say "$@"; }
is_dry_run() { test "${DRY_RUN:-0}" -eq 1; }
runtime_pushes_wrapper_images() { :; }
runtime_build_base_image() { _mark_step base; }
runtime_build_package_image() { _mark_step package; }
_runtime_run_package_smoke() { _mark_step smoke-start; _say "smoke says hi"; sleep "${SMOKE_SECS:-0}"; _mark_step smoke-end; return "${SMOKE_RC:-0}"; }
_runtime_build_wrapper() { local -n _t=$2; _t="repo:latest-$1"; _mark_step wrapper-start; sleep "${WRAP_SECS:-0}"; _mark_step wrapper-end; return "${WRAP_RC:-0}"; }
runtime_push_tag() { _mark_step push; }
export_rootfs_from_image() { _mark_step export; }'
# _chain [rootfs-dir]: one arch's chain; prints its output and CHAIN-RC, and marks when it returned.
_chain() {
  {
    echo 'set -uo pipefail'
    echo "${_STUBS}"
    echo "${_FNS}"
    echo "runtime_build_chain arm64 ${1:-}; rc=\$?; _mark_step returned; echo \"CHAIN-RC=\${rc}\""
  } > "${_work}/chain.sh"
  : > "${_work}/events"
  E="${_work}/events" bash "${_work}/chain.sh" 2>&1
}
_at() { sed -n "s/^$1 //p" "${_work}/events"; }
_has() { grep -q "^$1 " "${_work}/events"; }

t_case "in turn (RUNTIME_SMOKE_OVERLAP=0) the wrapper starts after the gate ends"
_t0="$(date +%s)"
out="$(RUNTIME_SMOKE_OVERLAP=0 SMOKE_SECS=3 WRAP_SECS=3 _chain)"
_ser_secs="$(( $(date +%s) - _t0 ))"
t_assert_contains "${out}" "CHAIN-RC=0"
t_assert_ok test "$(_at wrapper-start)" -ge "$(_at smoke-end)"

t_case "by default the gate runs beside the wrapper build, and the push waits for both"
_t0="$(date +%s)"
out="$(SMOKE_SECS=3 WRAP_SECS=3 _chain)"
t_assert_ok test "$(( $(date +%s) - _t0 ))" -le "$(( _ser_secs - 2 ))"
t_assert_contains "${out}" "CHAIN-RC=0"
t_assert_ok test "$(_at wrapper-start)" -lt "$(_at smoke-end)"
t_assert_ok test "$(_at push)" -ge "$(_at smoke-end)"
t_assert_contains "${out}" "[smoke arm64] smoke says hi"
t_assert_contains "${out}" "[runtime-timing] arch=arm64 step=smoke-wait"

t_case "a red gate fails the arch and nothing is pushed"
out="$(SMOKE_SECS=2 SMOKE_RC=1 _chain)"
t_assert_contains "${out}" "CHAIN-RC=1"
t_assert_fails _has push

t_case "a failed wrapper build still collects the gate before the arch fails"
out="$(SMOKE_SECS=3 WRAP_RC=1 _chain)"
t_assert_contains "${out}" "CHAIN-RC=1"
t_assert_ok test "$(_at returned)" -ge "$(_at smoke-end)"
t_assert_fails _has push

t_case "the rootfs path exports only after a green gate"
out="$(SMOKE_SECS=2 _chain "${_work}/rootfs/rootfs")"
t_assert_contains "${out}" "CHAIN-RC=0"
t_assert_ok test "$(_at export)" -ge "$(_at smoke-end)"
out="$(SMOKE_SECS=1 SMOKE_RC=1 _chain "${_work}/rootfs/rootfs")"
t_assert_contains "${out}" "CHAIN-RC=1"
t_assert_fails _has export

t_case "a dry run keeps the gate in turn"
out="$(DRY_RUN=1 SMOKE_SECS=1 _chain)"
t_assert_eq "0" "$(printf '%s\n' "${out}" | grep -c 'runs beside the wrapper build' || true)"

t_summary
