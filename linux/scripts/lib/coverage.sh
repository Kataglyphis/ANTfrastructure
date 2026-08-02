#!/usr/bin/env bash
# coverage.sh - generic coverage-report generation for CMake projects.
#
# Two independent backends, matching the two instrumentation flavours a project
# typically has:
#   gcovr    - GCC / --coverage builds, reads .gcda next to the objects
#   llvm-cov - clang -fprofile-instr-generate builds, needs a .profraw that
#              only exists once the instrumented binary has actually RUN
#
# This library is project-agnostic: nothing project-specific is hard-coded here.
# A thin wrapper script sets the COVERAGE_* variables below (its project
# defaults), sources this file, and calls the step functions it needs.
#
# It deliberately does NOT set -e / -u / -o pipefail so that sourcing it cannot
# change the caller's shell options; wrappers are expected to run under
# `set -euo pipefail` themselves.
#
# Optional caller variables (all have safe defaults):
#   COVERAGE_GCOVR_EXCLUDES      array of gcovr --exclude regexes
#   COVERAGE_GCOVR_OUTPUT        file gcovr writes to (default: stdout)
#   COVERAGE_GCOVR_EXTRA_ARGS    array of extra gcovr arguments (e.g. --xml)
#   COVERAGE_LLVM_IGNORE_REGEX   array of llvm-cov -ignore-filename-regex values
#                                applied to both `report` and `export`
#   COVERAGE_LLVM_RUN_ENV        array of NAME=VALUE assignments prefixed to the
#                                instrumented run (default:
#                                ASAN_OPTIONS=detect_leaks=0 - a coverage run
#                                only wants the profile, not a LeakSanitizer
#                                verdict)
#
# Logging comes from 01-core/logging.sh (or minimal fallbacks) and tool presence
# checks from the caller's require_tools when it declares one.

[ -n "${_COVERAGE_SH_LOADED:-}" ] && return 0
_COVERAGE_SH_LOADED=1

_COVERAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_COVERAGE_CORE_DIR="${_COVERAGE_LIB_DIR}/../01-core"

# ---------------------------------------------------------------------------
# Shared helpers: prefer the real 01-core modules, fall back to local minimals
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_COVERAGE_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_COVERAGE_CORE_DIR}/logging.sh"
  fi
fi
if ! declare -F info >/dev/null 2>&1; then
  info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fi
if ! declare -F err >/dev/null 2>&1; then
  err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
fi
if ! declare -F require_tools >/dev/null 2>&1; then
  require_tools() {
    local missing=() tool
    for tool in "$@"; do
      command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      err "Required tools not found: ${missing[*]}"
    fi
  }
fi

# ---------------------------------------------------------------------------
# gcovr backend
# ---------------------------------------------------------------------------
# Usage: coverage_run_gcovr [root]
# root defaults to "." - gcovr walks it for .gcda/.gcno pairs, so it must be the
# directory the objects were compiled under (usually the repo root, not the
# build dir, since the paths baked into .gcno are relative to the compile dir).
coverage_run_gcovr() {
  local root="${1:-.}"

  require_tools gcovr

  local args=(-r "${root}")

  local pattern
  for pattern in "${COVERAGE_GCOVR_EXCLUDES[@]:-}"; do
    [[ -n "${pattern}" ]] || continue
    args+=(--exclude "${pattern}")
  done

  local extra
  for extra in "${COVERAGE_GCOVR_EXTRA_ARGS[@]:-}"; do
    [[ -n "${extra}" ]] || continue
    args+=("${extra}")
  done

  if [[ -n "${COVERAGE_GCOVR_OUTPUT:-}" ]]; then
    args+=(--output "${COVERAGE_GCOVR_OUTPUT}")
  fi

  info "Running gcovr coverage report from $(pwd)"
  gcovr "${args[@]}"
}

# ---------------------------------------------------------------------------
# llvm-cov backend
# ---------------------------------------------------------------------------
# Usage: coverage_llvm_generate_profile <test-exe> <profraw-path> [exe args...]
#
# Generate the raw profile by RUNNING the instrumented suite. Nothing else in
# the pipeline produces this file, which is why coverage silently never ran and
# the merge below failed on a missing profraw. The suite passed here must be
# device-free (no GPU/display) so it runs in headless CI.
# LLVM_PROFILE_FILE both names and locates the output; detect_leaks=0 because a
# coverage run only wants the profile, not a LeakSanitizer verdict.
coverage_llvm_generate_profile() {
  local test_suite="$1"
  local profraw="$2"
  shift 2

  if [[ ! -f "${test_suite}" ]]; then
    err "Test executable not found at ${test_suite}. Build the project first."
    return 1
  fi

  local run_env=("${COVERAGE_LLVM_RUN_ENV[@]:-}")
  if [[ -z "${run_env[0]:-}" ]]; then
    run_env=(ASAN_OPTIONS=detect_leaks=0)
  fi

  mkdir -p "$(dirname "${profraw}")"
  info "Running ${test_suite} to generate coverage data"
  env "LLVM_PROFILE_FILE=${profraw}" "${run_env[@]}" "${test_suite}" "$@"

  if [[ ! -f "${profraw}" ]]; then
    err "Profile data still not found at ${profraw} after running the suite."
    return 1
  fi
}

# Usage: coverage_llvm_report <test-exe> <profraw> <profdata> [json-output]
# Merges the raw profile, prints the human-readable report, and - when a JSON
# path is given - exports the machine-readable one (for Codecov and friends).
coverage_llvm_report() {
  local test_suite="$1"
  local profraw="$2"
  local profdata="$3"
  local json_output="${4:-}"

  require_tools llvm-profdata llvm-cov

  local ignore_args=()
  local pattern
  for pattern in "${COVERAGE_LLVM_IGNORE_REGEX[@]:-}"; do
    [[ -n "${pattern}" ]] || continue
    ignore_args+=("-ignore-filename-regex=${pattern}")
  done

  info "Merging profile data from ${profraw}"
  llvm-profdata merge -sparse "${profraw}" -o "${profdata}"

  info "Generating coverage report"
  llvm-cov report "${test_suite}" -instr-profile="${profdata}" "${ignore_args[@]}"

  if [[ -n "${json_output}" ]]; then
    info "Exporting coverage to JSON: ${json_output}"
    llvm-cov export "${test_suite}" -format=text -instr-profile="${profdata}" "${ignore_args[@]}" > "${json_output}"
  fi
}
