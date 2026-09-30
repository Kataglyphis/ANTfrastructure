#!/usr/bin/env bash
# Sourced coverage core (no shell options): gcovr for GCC --coverage, llvm-cov for clang profiles.
# Optional: COVERAGE_GCOVR_{EXCLUDES,OUTPUT,EXTRA_ARGS}, COVERAGE_LLVM_{IGNORE_REGEX,RUN_ENV} (arrays but OUTPUT).

[ -n "${_COVERAGE_SH_LOADED:-}" ] && return 0
_COVERAGE_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"
# shellcheck source=../01-core/tool-checks.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/tool-checks.sh"

# gcovr: [root] must be the compile directory, since .gcno paths are relative to it.
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

# llvm-cov: <test-exe> <profraw-path> [args...]; only running a device-free suite produces the profraw.
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

# <test-exe> <profraw> <profdata> [json-output]; COVERAGE_LLVM_HTML_DIR also emits llvm-cov show HTML.
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

  if [[ -n "${COVERAGE_LLVM_HTML_DIR:-}" ]]; then
    info "Writing browsable HTML coverage report to ${COVERAGE_LLVM_HTML_DIR}"
    mkdir -p "${COVERAGE_LLVM_HTML_DIR}"
    llvm-cov show "${test_suite}" -instr-profile="${profdata}" "${ignore_args[@]}" \
      -format=html -output-dir "${COVERAGE_LLVM_HTML_DIR}"
  fi
}
