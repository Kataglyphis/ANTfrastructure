#!/usr/bin/env bash
# Sourced core (no shell options), apart from cmake-build.sh: CI builds once, tests many trees. docs/shared-script-libraries.md#ctest-runsh--run-a-cmake-projects-test-suite-in-a-container
[ -n "${_CTEST_RUN_SH_LOADED:-}" ] && return 0
_CTEST_RUN_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"
# shellcheck source=./cli-value-options.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cli-value-options.sh"
# shellcheck source=./project-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-env.sh"

# -T test leaves a Testing/ tree CI can upload; --output-on-failure keeps a failing test's stdout.
_CTEST_RUN_BUILTIN_ARGS=(
  --verbose
  --extra-verbose
  --debug
  -T test
  --output-on-failure
)

# No apostrophes in this heredoc: ShellCheck 0.11 mis-parses ${VAR:-} beside them (SC1073/SC1072).
ctest_run_usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- ctest args...]

${CTEST_RUN_USAGE_INTRO:-Runs the ctest suite of a CMake project.} Options:
  --build-dir DIR          build tree to run ctest in (default: ${CTEST_RUN_DEFAULT_BUILD_DIR:-build})
  --build-type CONFIG      value for ctest -C (default: ${CTEST_RUN_DEFAULT_BUILD_TYPE:-Debug})
  --ctest-exclude REGEX    value for ctest -E (default: ${CTEST_RUN_DEFAULT_EXCLUDE:-<none>})
  --timeout SECONDS        per-test limit, ctest --timeout; 0 sets none (default: ${CTEST_RUN_DEFAULT_TIMEOUT:-1500})
  --fail-on-skipped REGEX  fail when a test whose name matches REGEX is skipped; Disabled never counts (env: CTEST_FAIL_ON_SKIPPED)
  --fail-on-log-pattern REGEX  fail when a test's output has a line matching REGEX, naming the test (env: CTEST_FAIL_ON_LOG_PATTERN)
EOF
  vulkan_env_cli_usage
  cat <<EOF
  -h, --help               show this help

Anything after -- (or after the first non-option argument) is appended to the
ctest command line verbatim.
EOF
}

# Argument parsing. Precedence: CLI flag > environment > caller default.
_ctest_run_other_arg() {
  case "$1" in
    -h|--help) ctest_run_usage; exit 0 ;;
    --) return 3 ;;
    -*) err "Unknown argument: $1" ;;
    *) return 0 ;;
  esac
}

# Only ever called as a condition, so errexit cannot fire inside; 2 is an invalid pattern, 1 a miss.
_ctest_run_matches() {
  local rc
  [[ "$1" =~ $2 ]] 2>/dev/null
  rc=$?
  return "${rc}"
}

ctest_run_parse_args() {
  CTEST_RUN_PASSTHROUGH=()

  local -A _value_options=(
    [--vulkan-version]=VULKAN_VERSION
    [--vulkan-setup-script]=VULKAN_SETUP_SCRIPT
    [--vulkan-sdk]=VULKAN_SDK
    [--build-dir]=BUILD_DIR
    [--build-type]=BUILD_TYPE
    [--ctest-exclude]=CTEST_EXCLUDE
    [--timeout]=CTEST_TIMEOUT
    [--fail-on-skipped]=CTEST_FAIL_ON_SKIPPED
    [--fail-on-log-pattern]=CTEST_FAIL_ON_LOG_PATTERN
  )
  parse_cli_value_options _value_options CTEST_RUN_PASSTHROUGH _ctest_run_other_arg "$@"


  BUILD_DIR="${BUILD_DIR:-${BUILD_DIR_DEFAULT:-${CTEST_RUN_DEFAULT_BUILD_DIR-build}}}"
  BUILD_TYPE="${BUILD_TYPE:-${BUILD_TYPE_DEFAULT:-${CTEST_RUN_DEFAULT_BUILD_TYPE:-Debug}}}"
  CTEST_EXCLUDE="${CTEST_EXCLUDE:-${CTEST_EXCLUDE_DEFAULT:-${CTEST_RUN_DEFAULT_EXCLUDE:-}}}"
  # CTest's own DART_TESTING_TIMEOUT: a hung test ends named, not at the lane's 60 to 150 minute limit.
  CTEST_TIMEOUT="${CTEST_TIMEOUT:-${CTEST_RUN_DEFAULT_TIMEOUT:-1500}}"
  [[ "${CTEST_TIMEOUT}" =~ ^[0-9]+$ ]] || err "--timeout needs whole seconds, got: ${CTEST_TIMEOUT}"
  CTEST_FAIL_ON_SKIPPED="${CTEST_FAIL_ON_SKIPPED:-}"
  local _regex_rc=0
  _ctest_run_matches "" "${CTEST_FAIL_ON_SKIPPED}" || _regex_rc=$?
  [[ "${_regex_rc}" -ne 2 ]] || err "--fail-on-skipped needs an extended regular expression, got: ${CTEST_FAIL_ON_SKIPPED}"
  CTEST_FAIL_ON_LOG_PATTERN="${CTEST_FAIL_ON_LOG_PATTERN:-}"
  _regex_rc=0
  _ctest_run_matches "" "${CTEST_FAIL_ON_LOG_PATTERN}" || _regex_rc=$?
  [[ "${_regex_rc}" -ne 2 ]] || err "--fail-on-log-pattern needs an extended regular expression, got: ${CTEST_FAIL_ON_LOG_PATTERN}"
}

# Environment preparation: git refuses a host-owned bind mount until it is marked safe.
ctest_run_prepare_env() {
  project_env_allow_git_directory "${CTEST_RUN_SAFE_DIRECTORY-/workspace}"

  project_env_source_vulkan
  vulkan_env_default_cpu_driver
}

# Command construction. Pure: fills CTEST_CMD without running anything, so it stays testable.
ctest_run_build_command() {
  local default_args=("${CTEST_RUN_DEFAULT_ARGS[@]:-}")
  if [[ -z "${default_args[0]:-}" ]]; then
    default_args=("${_CTEST_RUN_BUILTIN_ARGS[@]}")
  fi

  CTEST_CMD=(ctest -C "${BUILD_TYPE}" "${default_args[@]}")

  if [[ -n "${CTEST_EXCLUDE}" ]]; then
    info "Excluding tests matching: ${CTEST_EXCLUDE}"
    CTEST_CMD+=(-E "${CTEST_EXCLUDE}")
  fi

  # A --timeout the caller passes after -- is the one ctest applies.
  if [[ "${CTEST_TIMEOUT}" != 0 && " ${CTEST_RUN_PASSTHROUGH[*]:-} " != *" --timeout "* ]]; then
    CTEST_CMD+=(--timeout "${CTEST_TIMEOUT}")
  fi

  CTEST_CMD+=("${CTEST_RUN_PASSTHROUGH[@]:+${CTEST_RUN_PASSTHROUGH[@]}}")
}

# Prints "<ran|skipped|disabled> TAB <reason> TAB <name>" per test of ctest's JUnit report.
_ctest_run_junit_results() {
  python3 -I - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET

for case in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    skipped = case.find("skipped")
    if case.get("status") == "disabled" or (skipped is not None and skipped.get("message") == "Disabled"):
        kind, reason = "disabled", "Disabled"
    elif skipped is not None:
        kind, reason = "skipped", skipped.get("message", "")
    else:
        kind, reason = "ran", case.get("status", "")
    print(f"{kind}\t{reason}\t{case.get('name', '')}")
PY
}

# A skip is not a pass: JUnit marks ctest's Skipped and Not Run tests, and only Disabled ones are exempt.
_ctest_run_check_skipped() {
  local report="$1" results kind reason name matched=0 disabled=0 skipped=0
  results="$(_ctest_run_junit_results "${report}")" || {
    warn "--fail-on-skipped: ctest wrote no readable JUnit report at ${report}"
    return 1
  }
  while IFS=$'\t' read -r kind reason name; do
    [[ -n "${kind}" ]] && _ctest_run_matches "${name}" "${CTEST_FAIL_ON_SKIPPED}" || continue
    matched=$((matched + 1))
    case "${kind}" in
      disabled) disabled=$((disabled + 1)) ;;
      skipped) skipped=$((skipped + 1)); warn "Skipped, which --fail-on-skipped forbids: ${name} (${reason})" ;;
    esac
  done <<< "${results}"
  if [[ "${skipped}" -gt 0 ]]; then
    warn "--fail-on-skipped: ${skipped} of ${matched} tests matching ${CTEST_FAIL_ON_SKIPPED} were skipped"
    return 1
  fi
  info "--fail-on-skipped: ${matched} tests match ${CTEST_FAIL_ON_SKIPPED}, none skipped (${disabled} disabled)"
}

# Prints "<name> TAB <count> TAB <first line>" per test whose output (not its Command line) matches $1 in the logs.
_ctest_run_log_matches() {
  python3 -I - "$@" <<'PY'
import re
import sys

pattern, hits = re.compile(sys.argv[1]), {}
for path in sys.argv[2:]:
    name, in_output = None, False
    with open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            started = re.match(r"^[0-9]+/[0-9]+ Test: (.+)$", line)
            if started:
                name, in_output = started.group(1).strip(), False
            elif line.startswith("Output:"):
                in_output = True
            elif line.startswith("<end of output>"):
                in_output = False
            elif in_output and name and pattern.search(line):
                hits.setdefault(name, []).append(line.rstrip("\n"))
for name, lines in hits.items():
    print(f"{name} ({len(lines)} line(s); first: {lines[0][:160]})")
PY
}

# A passing test can still log what must never happen, a GStreamer-CRITICAL or a SYNC-HAZARD (CON291).
_ctest_run_check_log_pattern() {
  local offenders offender
  local -a logs=()
  # Only logs newer than the marker are this run's: -T test names each run's LastTest_<stamp>.log anew.
  mapfile -t logs < <(find Testing/Temporary -maxdepth 1 -name 'LastTest*.log' -newer "$1" 2>/dev/null)
  [[ "${#logs[@]}" -gt 0 ]] || { warn "--fail-on-log-pattern: this run wrote no Testing/Temporary/LastTest*.log"; return 1; }
  offenders="$(_ctest_run_log_matches "${CTEST_FAIL_ON_LOG_PATTERN}" "${logs[@]}")" \
    || { warn "--fail-on-log-pattern: cannot read ${logs[*]}"; return 1; }
  if [[ -z "${offenders}" ]]; then
    info "--fail-on-log-pattern: no test logged a line matching ${CTEST_FAIL_ON_LOG_PATTERN}"
    return 0
  fi
  while IFS= read -r offender; do warn "Logged what --fail-on-log-pattern forbids: ${offender}"; done <<< "${offenders}"
  warn "--fail-on-log-pattern: $(wc -l <<< "${offenders}") test(s) logged a line matching ${CTEST_FAIL_ON_LOG_PATTERN}"
  return 1
}

# The report ctest writes: the caller's last --output-junit, else a temporary one appended here.
_ctest_run_junit_report() {
  local i
  CTEST_RUN_JUNIT_REPORT=""
  CTEST_RUN_JUNIT_OWNED=0
  for ((i = 0; i < ${#CTEST_CMD[@]} - 1; i++)); do
    [[ "${CTEST_CMD[i]}" != --output-junit ]] || CTEST_RUN_JUNIT_REPORT="${CTEST_CMD[i + 1]}"
  done
  if [[ -n "${CTEST_RUN_JUNIT_REPORT}" ]]; then
    # A report left by an earlier run must not stand in for this one.
    rm -f "${CTEST_RUN_JUNIT_REPORT}" || err "Cannot remove the old JUnit report: ${CTEST_RUN_JUNIT_REPORT}"
    return 0
  fi
  CTEST_RUN_JUNIT_REPORT="$(mktemp "${TMPDIR:-/tmp}/ctest-run-junit.XXXXXX")" || err "Cannot create a JUnit report file"
  CTEST_RUN_JUNIT_OWNED=1
  CTEST_CMD+=(--output-junit "${CTEST_RUN_JUNIT_REPORT}")
}

ctest_run_execute() {
  if [[ -n "${BUILD_DIR}" ]]; then
    info "Changing to build directory: ${BUILD_DIR}"
    # Checked explicitly: no set -e here, and a failed cd would run the suite in the wrong directory.
    [[ -d "${BUILD_DIR}" ]] || err "Build directory not found: ${BUILD_DIR}. Configure/build it first."
    cd "${BUILD_DIR}" || err "Cannot enter build directory: ${BUILD_DIR}"
  fi

  ctest_run_build_command
  _ctest_run_gates_prepare

  local rc=0
  info "Executing: ${CTEST_CMD[*]}"
  "${CTEST_CMD[@]}" || rc=$?
  _ctest_run_gates_verdict "${rc}"
}

# What the opt-in gates need before ctest starts: a JUnit report, and a marker that dates this run's logs.
_ctest_run_gates_prepare() {
  CTEST_RUN_LOG_MARKER=""
  if [[ -n "${CTEST_FAIL_ON_SKIPPED:-}" ]]; then
    command -v python3 >/dev/null 2>&1 || err "--fail-on-skipped reads ctest's JUnit report with python3, which is not on PATH"
    _ctest_run_junit_report
  fi
  if [[ -n "${CTEST_FAIL_ON_LOG_PATTERN:-}" ]]; then
    command -v python3 >/dev/null 2>&1 || err "--fail-on-log-pattern reads ctest's LastTest log with python3, which is not on PATH"
    CTEST_RUN_LOG_MARKER="$(mktemp "${TMPDIR:-/tmp}/ctest-run-start.XXXXXX")" || err "Cannot create a start marker"
  fi
}

# <ctest's status>: the run's status once each gate had its say; a gate fails a passing run, never masks a failed one.
_ctest_run_gates_verdict() {
  local rc="$1"
  if [[ -n "${CTEST_FAIL_ON_SKIPPED:-}" ]]; then
    _ctest_run_check_skipped "${CTEST_RUN_JUNIT_REPORT}" || [[ "${rc}" -ne 0 ]] || rc=1
    [[ "${CTEST_RUN_JUNIT_OWNED}" -eq 0 ]] || rm -f "${CTEST_RUN_JUNIT_REPORT}"
  fi
  if [[ -n "${CTEST_RUN_LOG_MARKER}" ]]; then
    _ctest_run_check_log_pattern "${CTEST_RUN_LOG_MARKER}" || [[ "${rc}" -ne 0 ]] || rc=1
    rm -f "${CTEST_RUN_LOG_MARKER}"
  fi
  return "${rc}"
}

# Full pipeline: parse args, prepare the environment, run the suite.
ctest_run_main() {
  ctest_run_parse_args "$@"
  ctest_run_prepare_env
  ctest_run_execute
}
