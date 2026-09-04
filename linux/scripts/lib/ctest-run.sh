#!/usr/bin/env bash
# ctest-run.sh - generic "run a CMake project's test suite in a container" core.
#
# The test-phase twin of cmake-build.sh, deliberately separate: CI builds once
# and runs ctest over several trees (plain, ASan, TSan), and sourcing the build
# driver would drag in machinery a test run has no use for.
# Variables: docs/shared-script-libraries.md § ctest-run.sh.
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.
[ -n "${_CTEST_RUN_SH_LOADED:-}" ] && return 0
_CTEST_RUN_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# --verbose --extra-verbose --debug together with -T test: verbose output plus a
# Testing/ subtree that CI can upload, and --output-on-failure so a failing test
# prints its own stdout even when the rest is filtered.
_CTEST_RUN_BUILTIN_ARGS=(
  --verbose
  --extra-verbose
  --debug
  -T test
  --output-on-failure
)

# NOTE: keep this heredoc free of apostrophes and inner single quotes:
# ShellCheck 0.11 mis-parses ${VAR:-} expansions combined with apostrophes
# inside heredocs (SC1073/SC1072 parser errors).
ctest_run_usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- ctest args...]

${CTEST_RUN_USAGE_INTRO:-Runs the ctest suite of a CMake project.} Options:
  --build-dir DIR          build tree to run ctest in (default: ${CTEST_RUN_DEFAULT_BUILD_DIR:-build})
  --build-type CONFIG      value for ctest -C (default: ${CTEST_RUN_DEFAULT_BUILD_TYPE:-Debug})
  --ctest-exclude REGEX    value for ctest -E (default: ${CTEST_RUN_DEFAULT_EXCLUDE:-<none>})
  --vulkan-version VER     Vulkan SDK version to source
  --vulkan-setup-script P  explicit Vulkan setup-env.sh to source
  --vulkan-sdk DIR         Vulkan SDK root whose setup-env.sh is sourced
  -h, --help               show this help

Anything after -- (or after the first non-option argument) is appended to the
ctest command line verbatim.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Fills BUILD_DIR, BUILD_TYPE, CTEST_EXCLUDE and CTEST_RUN_PASSTHROUGH.
#
# Precedence per setting: CLI flag > pre-existing environment variable >
# caller default.
ctest_run_parse_args() {
  CTEST_RUN_PASSTHROUGH=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vulkan-version)
        VULKAN_VERSION="${2:-}"
        shift 2
        ;;
      --vulkan-setup-script)
        VULKAN_SETUP_SCRIPT="${2:-}"
        shift 2
        ;;
      --vulkan-sdk)
        VULKAN_SDK="${2:-}"
        shift 2
        ;;
      --build-dir)
        BUILD_DIR="${2:-}"
        shift 2
        ;;
      --build-type)
        BUILD_TYPE="${2:-}"
        shift 2
        ;;
      --ctest-exclude)
        CTEST_EXCLUDE="${2:-}"
        shift 2
        ;;
      -h|--help)
        ctest_run_usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        err "Unknown argument: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    CTEST_RUN_PASSTHROUGH=("$@")
  fi

  BUILD_DIR="${BUILD_DIR:-${BUILD_DIR_DEFAULT:-${CTEST_RUN_DEFAULT_BUILD_DIR-build}}}"
  BUILD_TYPE="${BUILD_TYPE:-${BUILD_TYPE_DEFAULT:-${CTEST_RUN_DEFAULT_BUILD_TYPE:-Debug}}}"
  CTEST_EXCLUDE="${CTEST_EXCLUDE:-${CTEST_EXCLUDE_DEFAULT:-${CTEST_RUN_DEFAULT_EXCLUDE:-}}}"
}

# ---------------------------------------------------------------------------
# Environment preparation
# ---------------------------------------------------------------------------
# A bind-mounted workspace is owned by the host user, so git inside the
# container refuses to touch it until it is marked safe - and tests that shell
# out to git (or a CTest fixture that does) fail in confusing ways without it.
ctest_run_prepare_env() {
  local safe_dir="${CTEST_RUN_SAFE_DIRECTORY-/workspace}"
  if [[ -n "${safe_dir}" ]]; then
    git config --global --add safe.directory "${safe_dir}" || true
  fi

  if declare -F source_vulkan_env >/dev/null 2>&1; then
    source_vulkan_env
  elif [[ -n "${VULKAN_SETUP_SCRIPT:-}" && -f "${VULKAN_SETUP_SCRIPT}" ]]; then
    info "Sourcing Vulkan env from: ${VULKAN_SETUP_SCRIPT}"
    # shellcheck disable=SC1090
    . "${VULKAN_SETUP_SCRIPT}"
  fi
}

# ---------------------------------------------------------------------------
# Command construction + execution
# ---------------------------------------------------------------------------
# Builds the ctest argv into CTEST_CMD. Pure: nothing is executed and no
# directory is changed, so the command line stays inspectable (and testable).
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

  CTEST_CMD+=("${CTEST_RUN_PASSTHROUGH[@]:+${CTEST_RUN_PASSTHROUGH[@]}}")
}

ctest_run_execute() {
  if [[ -n "${BUILD_DIR}" ]]; then
    info "Changing to build directory: ${BUILD_DIR}"
    # Checked explicitly rather than leaning on the caller's `set -e`: this
    # library does not set -e itself, and a failed cd that is merely warned
    # about would run the whole suite in the wrong directory.
    [[ -d "${BUILD_DIR}" ]] || err "Build directory not found: ${BUILD_DIR}. Configure/build it first."
    cd "${BUILD_DIR}" || err "Cannot enter build directory: ${BUILD_DIR}"
  fi

  ctest_run_build_command

  info "Executing: ${CTEST_CMD[*]}"
  "${CTEST_CMD[@]}"
}

# Full pipeline: parse args, prepare the environment, run the suite.
ctest_run_main() {
  ctest_run_parse_args "$@"
  ctest_run_prepare_env
  ctest_run_execute
}
