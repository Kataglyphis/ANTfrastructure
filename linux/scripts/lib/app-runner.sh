#!/usr/bin/env bash
# app-runner.sh - generic launcher core for per-profile "run the built app" scripts.
#
# This library is project-agnostic: nothing project-specific is hard-coded here.
# A thin wrapper script sets the variables below (its per-profile defaults),
# optionally declares hook functions, sources this file, and calls
# app_runner_main "$@".
#
# Required caller variables:
#   APP_RUNNER_DEFAULT_EXE_NAME     default executable name (e.g. MyApp)
#   APP_RUNNER_DEFAULT_BUILD_DIR    default build directory (abs or repo-relative)
#   APP_RUNNER_DEFAULT_BUILD_TYPE   default CMake build type (Debug/Release/...)
#
# Optional caller variables:
#   APP_RUNNER_LABEL                label for the "Starting" log line, e.g. "release"
#   APP_RUNNER_USAGE_INTRO          one-line description shown in --help
#   APP_RUNNER_ENABLE_SHADER_CLEAN  "true" to accept --clean-and-rebuild-shaders
#   APP_RUNNER_SHADER_CLEAN_DIR     dir whose *.spv files are deleted by the clean
#                                   step (relative paths resolve against the
#                                   project root)
#   APP_RUNNER_SHADER_COMPILE_SCRIPT  shader compile script re-run after cleaning
#
# Optional hook functions (called only when declared by the wrapper):
#   app_runner_post_vulkan_hook   after Vulkan env sourcing, before executable
#                                 discovery (e.g. auto-install a missing SDK)
#   app_runner_env_hook           after LD_LIBRARY_PATH export, before launch
#                                 (e.g. force/clear validation layers)
#
# The wrapper's environment is expected to provide info/warn/err logging and
# get_project_root/source_vulkan_env (e.g. from a project common.sh); minimal
# fallbacks are defined here so the library also works standalone.

# ---------------------------------------------------------------------------
# Bootstrap — brought in line with the sibling libs (complexity audit F-A):
# this file was the drifted copy with NO re-source guard and NO attempt to
# load the real 01-core/logging.sh, so standalone consumers silently got the
# minimal fallbacks (no log/die, divergent formatting) forever.
# ---------------------------------------------------------------------------
[ -n "${_APP_RUNNER_LIB_LOADED:-}" ] && return 0
_APP_RUNNER_LIB_LOADED=1
_APP_RUNNER_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core"
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_APP_RUNNER_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_APP_RUNNER_CORE_DIR}/logging.sh"
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

app_runner_usage() {
  local shader_flag_summary=""
  local shader_flag_help=""
  if [[ "${APP_RUNNER_ENABLE_SHADER_CLEAN:-false}" == "true" ]]; then
    shader_flag_summary=" [--clean-and-rebuild-shaders]"
    shader_flag_help="
  --clean-and-rebuild-shaders: Deletes all .spv files and runs the compiler script before running"
  fi

  cat <<EOF
Usage: $(basename "$0") [--exe-name NAME] [--build-dir DIR] [--build-type TYPE]${shader_flag_summary} [--] [app args...]

${APP_RUNNER_USAGE_INTRO:-Starts the built application.} Defaults:
  --exe-name ${APP_RUNNER_DEFAULT_EXE_NAME}
  --build-dir ${APP_RUNNER_DEFAULT_BUILD_DIR}
  --build-type ${APP_RUNNER_DEFAULT_BUILD_TYPE}${shader_flag_help}
EOF
}

# Parses the standard runner CLI into EXE_NAME, BUILD_DIR, BUILD_TYPE,
# APP_ARGS and CLEAN_AND_REBUILD_SHADERS.
app_runner_parse_args() {
  EXE_NAME="${APP_RUNNER_DEFAULT_EXE_NAME}"
  BUILD_DIR="${APP_RUNNER_DEFAULT_BUILD_DIR}"
  BUILD_TYPE="${APP_RUNNER_DEFAULT_BUILD_TYPE}"
  APP_ARGS=()
  CLEAN_AND_REBUILD_SHADERS=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exe-name)
        EXE_NAME="${2:-}"
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
      --clean-and-rebuild-shaders)
        if [[ "${APP_RUNNER_ENABLE_SHADER_CLEAN:-false}" != "true" ]]; then
          err "Unknown option: $1"
        fi
        CLEAN_AND_REBUILD_SHADERS=true
        shift
        ;;
      -h|--help)
        app_runner_usage
        exit 0
        ;;
      --)
        shift
        APP_ARGS+=("$@")
        break
        ;;
      -* )
        err "Unknown option: $1"
        ;;
      *)
        APP_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Resolves the project root: prefers the caller's get_project_root (from its
# common.sh), then the enclosing git worktree, then the current directory.
app_runner_project_root() {
  if declare -F get_project_root >/dev/null 2>&1; then
    get_project_root
  elif command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

# Locates the built executable inside a build tree.
#   $1 = absolute build dir, $2 = executable name, $3 = build type
# Prints the resolved path; returns 1 when nothing was found.
app_runner_find_executable() {
  local abs_build_dir="$1"
  local exe_name="$2"
  local build_type="$3"

  # Candidate locations to look for the executable
  local candidates=(
    "${abs_build_dir}/${exe_name}"
    "${abs_build_dir}/bin/${exe_name}"
    "${abs_build_dir}/${build_type}/${exe_name}"
    "${abs_build_dir}/bin/${build_type}/${exe_name}"
  )

  local c
  for c in "${candidates[@]}"; do
    if [[ -x "${c}" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done

  if [[ -d "${abs_build_dir}" ]]; then
    local found
    found=$(find "${abs_build_dir}" -maxdepth 3 -type f -executable -name "${exe_name}" -print -quit || true)
    if [[ -n "${found}" ]]; then
      printf '%s\n' "${found}"
      return 0
    fi
  fi

  return 1
}

# Deletes compiled .spv shader artifacts and re-runs the compile script.
# Controlled by APP_RUNNER_SHADER_CLEAN_DIR / APP_RUNNER_SHADER_COMPILE_SCRIPT.
app_runner_clean_and_rebuild_shaders() {
  local clean_dir="${APP_RUNNER_SHADER_CLEAN_DIR:-}"
  if [[ -n "${clean_dir}" && "${clean_dir}" != /* ]]; then
    clean_dir="${PROJECT_ROOT}/${clean_dir}"
  fi

  info "Cleaning and rebuilding Slang shaders..."
  if [[ -n "${clean_dir}" ]]; then
    find "${clean_dir}" -name "*.spv" -delete 2>/dev/null || true
  fi
  if [[ -n "${APP_RUNNER_SHADER_COMPILE_SCRIPT:-}" && -f "${APP_RUNNER_SHADER_COMPILE_SCRIPT}" ]]; then
    bash "${APP_RUNNER_SHADER_COMPILE_SCRIPT}"
  else
    warn "compile-slang-shaders.sh not found, skipping rebuild step"
  fi
}

# Full pipeline: parse args, resolve paths, source the Vulkan env, discover the
# executable, set up the runtime environment and exec the application.
app_runner_main() {
  app_runner_parse_args "$@"

  PROJECT_ROOT="$(app_runner_project_root)"

  # Resolve build dir absolute path (accept absolute or repo-relative)
  if [[ "${BUILD_DIR}" = /* ]]; then
    ABS_BUILD_DIR="${BUILD_DIR}"
  else
    ABS_BUILD_DIR="${PROJECT_ROOT}/${BUILD_DIR}"
  fi

  if declare -F source_vulkan_env >/dev/null 2>&1; then
    source_vulkan_env
  fi

  if declare -F app_runner_post_vulkan_hook >/dev/null 2>&1; then
    app_runner_post_vulkan_hook
  fi

  EXE_PATH="$(app_runner_find_executable "${ABS_BUILD_DIR}" "${EXE_NAME}" "${BUILD_TYPE}")" \
    || err "Executable '${EXE_NAME}' not found in '${ABS_BUILD_DIR}'. Please build the project first."

  # Ensure runtime loader finds built shared libraries
  export LD_LIBRARY_PATH="${ABS_BUILD_DIR}:${ABS_BUILD_DIR}/bin:${LD_LIBRARY_PATH:-}"

  if declare -F app_runner_env_hook >/dev/null 2>&1; then
    app_runner_env_hook
  fi

  if [[ "${CLEAN_AND_REBUILD_SHADERS}" = true ]]; then
    app_runner_clean_and_rebuild_shaders
  fi

  WORK_DIR="${PROJECT_ROOT}"
  info "Starting${APP_RUNNER_LABEL:+ (${APP_RUNNER_LABEL})}: ${EXE_PATH}"
  info "Working directory: ${WORK_DIR}"
  info "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"

  cd "${WORK_DIR}"

  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    exec "${EXE_PATH}" "${APP_ARGS[@]}"
  else
    exec "${EXE_PATH}"
  fi
}
