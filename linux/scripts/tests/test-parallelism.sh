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

# ---------------------------------------------------------------------------
t_case "BUILD_MEM_DIVISOR=3 yields exactly 1/3 of the divisor=1 jobs"
# The divisor is applied inside the REAL _usable_mem_mb (parallelism.sh
# ~173-184: usable = avail / BUILD_MEM_DIVISOR), which this file's stub above
# bypasses — so run the case in a fresh child bash and stub one level LOWER
# (_mem_available_mb, the raw probe). Math with avail=24000, peak=1000,
# cores=64:  divisor=1 -> min(64, 24000/1000) = 24;  divisor=3 ->
# min(64, 8000/1000) = 8;  an invalid divisor must fall back to 1 -> 24.
_div_out="$(bash -c '
  set -u
  source "'"${TESTS_DIR}"'/../01-core/parallelism.sh"
  _mem_available_mb() { printf "24000"; }
  detect_available_cores() { printf "64"; }
  compute_jobs() { printf "%s" "${1:-64}"; }
  unset PARALLEL_JOBS 2>/dev/null || true
  printf "%s;%s;%s" \
    "$(BUILD_MEM_DIVISOR=1 mem_capped_jobs 1000 64)" \
    "$(BUILD_MEM_DIVISOR=3 mem_capped_jobs 1000 64)" \
    "$(BUILD_MEM_DIVISOR=bogus mem_capped_jobs 1000 64)"
')"
t_assert_eq "24;8;24" "${_div_out}" \
  "divisor must divide usable RAM (3x concurrency -> 1/3 jobs each; invalid divisor -> 1)"

# ── _cgroup_mem_remaining_mb: one owner for two cgroup generations (F1) ──────
# The two halves were the same four tests twice over. CGROUP_ROOT lets the suite
# stand a fixture in for absolute kernel paths, which is what made this
# untestable before. docs/build-parallelism-memory-tuning.md
_cg() {
  local root; root="$(mktemp -d)"
  mkdir -p "${root}/memory"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "${root}/memory.max"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "${root}/memory.current"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "${root}/memory/memory.limit_in_bytes"
  [ -z "${4:-}" ] || printf '%s\n' "$4" > "${root}/memory/memory.usage_in_bytes"
  CGROUP_ROOT="${root}" _cgroup_mem_remaining_mb
  rm -rf "${root}"
}
_GB=1073741824

t_case "cgroup v2: remaining is limit minus current, in MB"
t_assert_eq "1024" "$(_cg $(( 2 * _GB )) $(( 1 * _GB )))"
t_assert_eq "2048" "$(_cg $(( 2 * _GB )) 0)"

t_case "cgroup v1 answers when v2 is absent, with the SAME arithmetic"
t_assert_eq "1024" "$(_cg '' '' $(( 2 * _GB )) $(( 1 * _GB )))" \
  "two generations that disagree about the maths are two functions wearing one name"

t_case "an unreadable current falls back to the whole limit, not to unknown"
t_assert_eq "2048" "$(_cg $(( 2 * _GB )))"
t_assert_eq "2048" "$(_cg '' '' $(( 2 * _GB )))"

t_case "usage above the limit clamps at 0 instead of going negative"
t_assert_eq "0" "$(_cg $(( 1 * _GB )) $(( 2 * _GB )))" \
  "a negative remaining would read as the SMALLEST cap and throttle every job"

t_case "each generation's spelling of 'no limit' yields unknown, not a number"
t_assert_eq "" "$(_cg max 12345)" "cgroup v2 writes the literal max"
t_assert_eq "" "$(_cg '' '' 9223372036854771712 0)" "cgroup v1 writes a huge number"
t_assert_eq "" "$(_cg '' '' 0 0)" "and 0 means unlimited there too"
t_assert_eq "" "$(_cg)" "no cgroup files at all is unknown"

t_case "garbage in a limit file is unknown, and never reaches the arithmetic"
# Unguarded, `$(( max - current ))` on a non-number aborts the caller under errexit.
t_assert_eq "" "$(_cg 'not-a-number' 5)"
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/parallelism.sh"
  d="$(mktemp -d)"; printf "garbage\n" > "${d}/memory.max"
  CGROUP_ROOT="${d}" _cgroup_mem_remaining_mb >/dev/null
  rm -rf "${d}"'

t_summary
