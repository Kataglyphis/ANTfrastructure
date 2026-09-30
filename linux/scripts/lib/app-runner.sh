#!/usr/bin/env bash
# Launcher core: the wrapper sets APP_RUNNER_DEFAULT_{EXE_NAME,BUILD_DIR,BUILD_TYPE}, then calls app_runner_main "$@".
# Optional: APP_RUNNER_{LABEL,USAGE_INTRO,ENABLE_SHADER_CLEAN,SHADER_CLEAN_DIR,SHADER_COMPILE_SCRIPT},
# hooks app_runner_post_vulkan_hook / app_runner_env_hook; the wrapper provides get_project_root and source_vulkan_env.
[ -n "${_APP_RUNNER_LIB_LOADED:-}" ] && return 0
_APP_RUNNER_LIB_LOADED=1
# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

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

# Fills EXE_NAME, BUILD_DIR, BUILD_TYPE, APP_ARGS and CLEAN_AND_REBUILD_SHADERS.
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

# The caller's get_project_root wins, then the git worktree, then $PWD.
app_runner_project_root() {
  if declare -F get_project_root >/dev/null 2>&1; then
    get_project_root
  elif command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

# <abs_build_dir> <exe_name> <build_type>; prints the path, returns 1 when nothing is found.
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

  cd "${WORK_DIR}" || err "Cannot enter working directory: ${WORK_DIR}"

  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    exec "${EXE_PATH}" "${APP_ARGS[@]}"
  else
    exec "${EXE_PATH}"
  fi
}
