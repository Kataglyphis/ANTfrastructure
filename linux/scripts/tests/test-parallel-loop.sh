#!/usr/bin/env bash
# Tests for 01-core/parallel-loop.sh.
#
# The headline case is a regression guard: run_parallel_arch_loop used to clean
# its flag dir with `trap 'rm -rf "${_flagdir}"' RETURN`. A RETURN trap set
# inside a function is NOT scoped to it — it stays armed and fires again when
# the CALLER returns, where ${_flagdir} (a local) no longer exists. Under the
# orchestrator's `set -u` that killed build-cross-chain.sh with a bare
# "_flagdir: unbound variable" right after the build loop, i.e. AFTER every
# stage had succeeded, turning a green chain into exit 1.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"

_bool_truthy() { case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

source "${CORE_DIR}/parallel-loop.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---------------------------------------------------------------------------
t_case "arch_loop_flag_prefix honors TMPDIR and returns a bare prefix"
t_assert_eq "/custom/tmp/cross-loop-flags" \
            "$(TMPDIR=/custom/tmp arch_loop_flag_prefix cross-loop-flags)"

# ---------------------------------------------------------------------------
# Regression: a caller returning after run_parallel_arch_loop must not trip
# over a still-armed RETURN trap. This is run in a child bash under the same
# `set -euo pipefail` the orchestrator uses, because the failure mode is the
# shell aborting — which cannot be observed from inside the same process.
_run_caller_scenario() {
  bash -c '
    set -euo pipefail
    source "'"${CORE_DIR}"'/parallel-loop.sh"
    _bool_truthy() { case "${1:-}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
    warn() { :; }
    worker() { return 0; }
    # run_parallel_arch_loop is called from INSIDE a function, exactly as
    # build-cross-chain.sh calls it from _chain_run_build_loop.
    caller_fn() {
      run_parallel_arch_loop worker "'"${workdir}"'/flags" 4 amd64 || return 1
      return 0
    }
    caller_fn
    echo REACHED_END
  ' 2>&1
}

t_case "the caller of run_parallel_arch_loop returns cleanly (no leaked RETURN trap)"
out="$(_run_caller_scenario)"; rc=$?
t_assert_eq "0" "${rc}" "caller scenario should exit 0"
t_assert_contains "${out}" "REACHED_END" "execution must continue past the caller's return"

t_case "no 'unbound variable' escapes the loop"
case "${out}" in
  *_flagdir*|*"unbound variable"*|*"ist nicht gesetzt"*)
    t_assert_eq "" "${out}" "flag dir leaked into an unbound-variable error" ;;
  *) t_assert_eq "0" "0" ;;
esac

# ---------------------------------------------------------------------------
t_case "the flag dir is removed once the loop returns"
before="$(find "${workdir}" -maxdepth 1 -name 'flags.*' 2>/dev/null | wc -l)"
_run_caller_scenario >/dev/null 2>&1
after="$(find "${workdir}" -maxdepth 1 -name 'flags.*' 2>/dev/null | wc -l)"
t_assert_eq "${before}" "${after}" "run_parallel_arch_loop must not leak its flag dir"

# ---------------------------------------------------------------------------
t_case "a failing arch is reported as a non-zero return (sequential path)"
worker_fail() { [ "$1" = "amd64" ]; }   # arm64 fails
PARALLEL_ARCHS=0
t_assert_fails run_parallel_arch_loop worker_fail "${workdir}/f2" 4 amd64 arm64
t_assert_ok    run_parallel_arch_loop worker_fail "${workdir}/f3" 4 amd64

# ---------------------------------------------------------------------------
# PARALLEL-path failure harvest: workers run as background subshells; a failed
# lane is persisted as a failed-<arch> flag file and harvested after the join
# into a nonzero return, while sibling lanes still complete their work. Safe
# to assert from this process: cleanup is explicit at the single exit point
# (see the no-RETURN-trap contract at the top of parallel-loop.sh), so no
# trap is left armed to corrupt our own returns.
t_case "parallel path: one failing arch -> nonzero return, sibling lane completed"
worker_par() {
  if [ "$1" = "amd64" ]; then
    touch "${workdir}/par-done-amd64"
    return 0
  fi
  return 1   # arm64 lane fails
}
rm -f "${workdir}/par-done-amd64"
PARALLEL_ARCHS=1   # truthy per _bool_truthy (1|true|yes|on)
t_assert_fails run_parallel_arch_loop worker_par "${workdir}/f4" 4 amd64 arm64
t_assert_ok test -f "${workdir}/par-done-amd64"

t_case "parallel path: all lanes green -> rc 0, work done, flag dir cleaned"
worker_ok_par() { touch "${workdir}/par-ok-$1"; }
t_assert_ok run_parallel_arch_loop worker_ok_par "${workdir}/f5" 4 amd64 arm64
t_assert_ok test -f "${workdir}/par-ok-amd64"
t_assert_ok test -f "${workdir}/par-ok-arm64"
t_assert_eq "0" "$(find "${workdir}" -maxdepth 1 \( -name 'f4.*' -o -name 'f5.*' \) | wc -l | tr -d ' ')" \
  "parallel runs must not leak their flag dirs"
PARALLEL_ARCHS=0

# ---------------------------------------------------------------------------
# O4: PARALLEL_LOOP_FAIL_FAST (sequential path). Default keep-going still
# attempts every arch after a failure (CI resilience); opt-in fail-fast aborts
# the loop on the first failure so the remaining arches aren't ground for hours.
# A worker records each arch it is invoked for (into an order file), so we can
# assert exactly which arches ran. The scenario runs in a child bash under the
# same set the orchestrator uses; amd64 is made to fail first.

t_case "O4: fail-fast aborts the sequential loop after the first arch failure"
: > "${workdir}/ff-order"
PARALLEL_ARCHS=0
t_assert_fails env PARALLEL_LOOP_FAIL_FAST=1 bash -c '
  source "'"${CORE_DIR}"'/parallel-loop.sh"
  _bool_truthy() { case "${1:-}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
  warn() { :; }
  w() { printf "%s\n" "$1" >> "'"${workdir}"'/ff-order"; [ "$1" != "amd64" ]; }
  run_parallel_arch_loop w "'"${workdir}"'/ff" 4 amd64 arm64 riscv64
'
t_assert_eq "amd64" "$(tr '\n' ' ' < "${workdir}/ff-order" | sed 's/ *$//')" \
  "fail-fast must stop after amd64 fails (arm64/riscv64 skipped)"

t_case "O4: default (keep-going) still attempts every arch after a failure"
: > "${workdir}/kg-order"
PARALLEL_ARCHS=0
t_assert_fails env -u PARALLEL_LOOP_FAIL_FAST bash -c '
  source "'"${CORE_DIR}"'/parallel-loop.sh"
  _bool_truthy() { case "${1:-}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
  warn() { :; }
  w() { printf "%s\n" "$1" >> "'"${workdir}"'/kg-order"; [ "$1" != "amd64" ]; }
  run_parallel_arch_loop w "'"${workdir}"'/kg" 4 amd64 arm64 riscv64
'
t_assert_eq "amd64 arm64 riscv64" "$(tr '\n' ' ' < "${workdir}/kg-order" | sed 's/ *$//')" \
  "default keep-going must attempt all three arches"

t_summary
