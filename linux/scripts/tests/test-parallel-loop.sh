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

t_summary
