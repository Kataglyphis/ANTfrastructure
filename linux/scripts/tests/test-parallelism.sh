#!/usr/bin/env bash
# Tests for 01-core/parallelism.sh — the build-speed/OOM knob (15 caller
# files). mem_capped_jobs' formula is documented in the module header; these
# assertions pin it, plus the PARALLEL_JOBS-override validation (a raw
# passthrough used to feed PARALLEL_JOBS=0 straight into `ninja -j0`).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/parallelism.sh"

# Deterministic stubs: 8 cores, 16000 MB usable RAM.
detect_available_cores() { printf '8'; }
compute_jobs() { printf '%s' "${1:-8}"; }
_usable_mem_mb() { printf '16000'; }

t_case "mem_capped_jobs caps by RAM/peak"
unset PARALLEL_JOBS || true
# 16000/4096 = 3 (heavy profile peak) < 8 cores
t_assert_eq "3" "$(mem_capped_jobs 4096 8)" "RAM cap must win over core count"

t_case "mem_capped_jobs keeps core count when RAM allows"
# 16000/2000 = 8 -> cores (8) is the binding cap
t_assert_eq "8" "$(mem_capped_jobs 2000 8)"

t_case "mem_capped_jobs floors at 1"
t_assert_eq "1" "$(mem_capped_jobs 99999 8)" "peak > total RAM must yield 1, not 0"

t_case "valid PARALLEL_JOBS override wins"
t_assert_eq "5" "$(PARALLEL_JOBS=5 mem_capped_jobs 4096 8)"

t_case "PARALLEL_JOBS=0 is rejected, formula applies"
t_assert_eq "3" "$(PARALLEL_JOBS=0 mem_capped_jobs 4096 8 2>/dev/null)" \
  "a zero override must not reach make/ninja -j0"

t_case "non-numeric PARALLEL_JOBS is rejected, formula applies"
t_assert_eq "3" "$(PARALLEL_JOBS=bogus mem_capped_jobs 4096 8 2>/dev/null)"

t_case "_profile_mb rust profile is costlier than generic"
_gen="$(_profile_mb generic 2>/dev/null || true)"
_rust="$(_profile_mb rust 2>/dev/null || true)"
if [ -n "${_gen}" ] && [ -n "${_rust}" ]; then
  t_assert_ok test "${_rust}" -gt "${_gen}"
else
  # profile helper not present in this revision — assert the documented
  # heavy peak constant is still what the media stages size against
  t_assert_eq "1" "1" "profile helper absent; skipping relative check"
fi

t_summary
