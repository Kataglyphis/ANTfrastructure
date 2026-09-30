#!/usr/bin/env bash
# Sourced core, so it sets no shell options. docs/shared-script-libraries.md#cmake-buildsh--configure--build-a-cmake-project-in-a-container
[ -n "${_CMAKE_BUILD_SH_LOADED:-}" ] && return 0
_CMAKE_BUILD_SH_LOADED=1

_CMAKE_BUILD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CMAKE_BUILD_CORE_DIR="${_CMAKE_BUILD_LIB_DIR}/../01-core"
# shellcheck source=./log-bootstrap.sh
source "${_CMAKE_BUILD_LIB_DIR}/log-bootstrap.sh"

cmake_build_usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [preset]

${CMAKE_BUILD_USAGE_INTRO:-Configures and builds a CMake project.} Options:
  --preset NAME            CMake configure/build preset (default: ${CMAKE_BUILD_DEFAULT_PRESET:-<none>})
  --build-dir DIR          build directory (default: ${CMAKE_BUILD_DEFAULT_BUILD_DIR:-build})
  --build-config CONFIG    value for 'cmake --build --config'
  --build-target TARGET    value for 'cmake --build --target'
  --configure-arg ARG      extra argument for the CONFIGURE step (repeatable)
  --clean-build-dir BOOL   rm -rf the build dir before configuring
  --skip-configure [BOOL]  build an already-configured tree
  --parallel N             explicit job count (default: memory-aware auto-detect)
  --mb-per-job MB          peak RAM per job used by the auto-detection (default: ${CMAKE_BUILD_DEFAULT_MB_PER_JOB:-4000})
  --cargo-cache-dir DIR    writable CARGO_HOME/CARGO_TARGET_DIR (e.g. a named volume)
  --vulkan-version VER     Vulkan SDK version to source
  --vulkan-setup-script P  explicit Vulkan setup-env.sh to source
  --vulkan-sdk DIR         Vulkan SDK root whose setup-env.sh is sourced
  --allow-prebuild-failure downgrade a failing pre-build hook to a warning
  -h, --help               show this help
EOF
}

# Argument parsing. A --vulkan-* flag beats the environment; the default setup script applies only if it exists.
_cmake_build_resolve_vulkan() {
  local version_arg="$1" setup_arg="$2" sdk_arg="$3"

  if [[ -n "${version_arg}" ]]; then
    VULKAN_VERSION="${version_arg}"
  fi
  if [[ -n "${setup_arg}" ]]; then
    VULKAN_SETUP_SCRIPT="${setup_arg}"
  fi
  if [[ -n "${sdk_arg}" ]]; then
    VULKAN_SDK="${sdk_arg}"
  fi
  if [[ -z "${VULKAN_SETUP_SCRIPT:-}" \
        && -n "${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT:-}" \
        && -f "${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT}" ]]; then
    VULKAN_SETUP_SCRIPT="${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT}"
  fi
}

# Precedence: CLI flag > environment > caller default; a trailing positional is the preset.
cmake_build_parse_args() {
  local preset_arg="" build_dir_arg="" clean_arg="" skip_arg=""
  local config_arg="" target_arg=""
  local vulkan_version_arg="" vulkan_setup_arg="" vulkan_sdk_arg=""

  PARALLEL_JOBS="${PARALLEL_JOBS:-}"
  MB_PER_JOB="${CMAKE_BUILD_DEFAULT_MB_PER_JOB:-4000}"
  ALLOW_PREBUILD_FAILURE="${CMAKE_BUILD_DEFAULT_ALLOW_PREBUILD_FAILURE:-false}"
  CMAKE_BUILD_POSITIONAL=()
  # An array, never an env string (splitting breaks -D values with spaces); reset so a re-parse inherits nothing.
  CMAKE_BUILD_CONFIGURE_ARGS=( ${CMAKE_BUILD_DEFAULT_CONFIGURE_ARGS[@]+"${CMAKE_BUILD_DEFAULT_CONFIGURE_ARGS[@]}"} )

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset)              preset_arg="${2:-}";         shift 2 ;;
      --build-dir)           build_dir_arg="${2:-}";      shift 2 ;;
      --clean-build-dir)     clean_arg="${2:-}";          shift 2 ;;
      --build-config)        config_arg="${2:-}";         shift 2 ;;
      --build-target)        target_arg="${2:-}";         shift 2 ;;
      # Repeatable; an empty value is fatal because `cmake ""` fails far from the caller.
      --configure-arg)
        [[ -n "${2:-}" ]] || err "--configure-arg expects a value (e.g. --configure-arg -DCMAKE_LINK_WHAT_YOU_USE=FALSE)"
        CMAKE_BUILD_CONFIGURE_ARGS+=("$2"); shift 2 ;;
      --cargo-cache-dir)     CARGO_CACHE_DIR="${2:-}";    shift 2 ;;
      --parallel)            PARALLEL_JOBS="${2:-}";      shift 2 ;;
      --mb-per-job)          MB_PER_JOB="${2:-}";         shift 2 ;;
      --vulkan-version)      vulkan_version_arg="${2:-}"; shift 2 ;;
      --vulkan-setup-script) vulkan_setup_arg="${2:-}";   shift 2 ;;
      --vulkan-sdk)          vulkan_sdk_arg="${2:-}";     shift 2 ;;
      --allow-prebuild-failure) ALLOW_PREBUILD_FAILURE="true"; shift ;;
      --skip-configure)
        if [[ $# -ge 2 && "${2}" != -* ]]; then
          skip_arg="${2}"
          shift 2
        else
          skip_arg="true"
          shift
        fi
        ;;
      --use-thread-sanitizer)
        err "--use-thread-sanitizer does nothing (legacy plumbing) — select a sanitizer preset via --preset instead"
        ;;
      -h|--help) cmake_build_usage; exit 0 ;;
      -*)        err "Unknown argument: $1" ;;
      *)         break ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    CMAKE_BUILD_POSITIONAL=("$@")
  fi

  _cmake_build_resolve_vulkan \
    "${vulkan_version_arg}" "${vulkan_setup_arg}" "${vulkan_sdk_arg}"

  PRESET="${preset_arg:-${PRESET:-${CMAKE_BUILD_POSITIONAL[0]:-${CMAKE_BUILD_DEFAULT_PRESET:-}}}}"
  BUILD_DIR="${build_dir_arg:-${BUILD_DIR:-${CMAKE_BUILD_DEFAULT_BUILD_DIR:-build}}}"
  CLEAN_BUILD_DIR="${clean_arg:-${CLEAN_BUILD_DIR:-${CMAKE_BUILD_DEFAULT_CLEAN_BUILD_DIR:-false}}}"
  SKIP_CONFIGURE="${skip_arg:-${SKIP_CONFIGURE:-${CMAKE_BUILD_DEFAULT_SKIP_CONFIGURE:-false}}}"
  CMAKE_BUILD_CONFIG="${config_arg:-${CMAKE_BUILD_CONFIG:-}}"
  CMAKE_BUILD_TARGET="${target_arg:-${CMAKE_BUILD_TARGET:-}}"

  if [[ "${SKIP_CONFIGURE}" != "true" && -z "${PRESET}" ]]; then
    PRESET="${CMAKE_BUILD_DEFAULT_PRESET:-}"
  fi
}

# Environment preparation for an unprivileged build; safe to call more than once.
cmake_build_prepare_env() {
  local safe_dir="${CMAKE_BUILD_SAFE_DIRECTORY-/workspace}"
  if [[ -n "${safe_dir}" ]]; then
    git config --global --add safe.directory "${safe_dir}" || true
  fi

  # ccache reads CCACHE_SECONDARY_STORAGE as a URL; a non-URL value fails every gcc compile.
  if [[ -n "${CCACHE_SECONDARY_STORAGE:-}" && "${CCACHE_SECONDARY_STORAGE}" != *"://"* ]]; then
    echo "Ignoring invalid CCACHE_SECONDARY_STORAGE='${CCACHE_SECONDARY_STORAGE}' (not a URL)"
    unset CCACHE_SECONDARY_STORAGE
  fi

  if declare -F source_vulkan_env >/dev/null 2>&1; then
    source_vulkan_env
  elif [[ -n "${VULKAN_SETUP_SCRIPT:-}" && -f "${VULKAN_SETUP_SCRIPT}" ]]; then
    info "Sourcing Vulkan env from: ${VULKAN_SETUP_SCRIPT}"
    # shellcheck disable=SC1090
    . "${VULKAN_SETUP_SCRIPT}"
  fi

  # See docs/cross-build-verification.md#cmake-buildsh-a-writable-cargo_home
  if ! { mkdir -p "${CARGO_HOME:-/usr/local/cargo}/registry" 2>/dev/null \
         && [[ -w "${CARGO_HOME:-/usr/local/cargo}/registry" ]]; }; then
    if [[ -n "${CARGO_CACHE_DIR:-}" ]]; then
      export CARGO_HOME="${CARGO_CACHE_DIR}"
      # The target dir too: the 9p host mount breaks cargo's temp-file renames.
      export CARGO_TARGET_DIR="${CARGO_CACHE_DIR}/target"
      mkdir -p "${CARGO_TARGET_DIR}"
    else
      export CARGO_HOME="${TMPDIR:-/tmp}/cargo-home"
      export CARGO_TARGET_DIR="${CARGO_HOME}/target"
    fi
    mkdir -p "${CARGO_HOME}"
    echo "CARGO_HOME not writable in this image; using ${CARGO_HOME}"
  fi

  # The baked cache dirs are root-owned at runtime, failing non-root compiles; nothing persisted there anyway.
  local cache_var cache_dir fallback
  for cache_var in SCCACHE_DIR CCACHE_DIR; do
    cache_dir="${!cache_var:-}"
    if [[ -n "${cache_dir}" ]] && ! { mkdir -p "${cache_dir}" 2>/dev/null && [[ -w "${cache_dir}" ]]; }; then
      fallback="${TMPDIR:-/tmp}/$(echo "${cache_var}" | tr '[:upper:]' '[:lower:]')"
      export "${cache_var}=${fallback}"
      mkdir -p "${fallback}"
      echo "${cache_var} not writable in this image; using ${fallback}"
    fi
  done
}

# The project's get_build_jobs wins, then parallelism.sh, then a plain core count.
cmake_build_jobs() {
  local mb_per_job="${1:-4000}"

  if declare -F get_build_jobs >/dev/null 2>&1; then
    get_build_jobs "${mb_per_job}"
    return 0
  fi

  if ! declare -F compute_jobs_with_mem_cap >/dev/null 2>&1 \
     && [[ -f "${_CMAKE_BUILD_CORE_DIR}/parallelism.sh" ]]; then
    # shellcheck source=../01-core/parallelism.sh
    source "${_CMAKE_BUILD_CORE_DIR}/parallelism.sh"
  fi

  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    compute_jobs_with_mem_cap "" "${mb_per_job}"
  else
    nproc --all 2>/dev/null || echo 1
  fi
}

# Configure + build. Split out for the complexity gate; extras are echoed so every -D shows in the log.
_cmake_build_log_configure() {
  local _n=0
  [[ -n "${CMAKE_BUILD_CONFIGURE_ARGS+x}" ]] && _n="${#CMAKE_BUILD_CONFIGURE_ARGS[@]}"
  if [[ "${_n}" -gt 0 ]]; then
    info "Configuring CMake with preset: ${PRESET} (+ ${CMAKE_BUILD_CONFIGURE_ARGS[*]})"
  else
    info "Configuring CMake with preset: ${PRESET}"
  fi
}

# Consumes the variables produced by cmake_build_parse_args.
cmake_build_run() {
  if [[ "${CLEAN_BUILD_DIR}" == "true" && -n "${BUILD_DIR}" ]]; then
    info "Cleaning build directory: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
  fi

  if [[ "${SKIP_CONFIGURE}" != "true" ]]; then
    if [[ -z "${PRESET}" ]]; then
      err "Missing --preset for configure step."
    fi
    _cmake_build_log_configure
    if [[ -n "${BUILD_DIR}" ]]; then
      cmake -B "${BUILD_DIR}" --preset "${PRESET}" ${CMAKE_BUILD_CONFIGURE_ARGS[@]+"${CMAKE_BUILD_CONFIGURE_ARGS[@]}"}
    else
      cmake --preset "${PRESET}" ${CMAKE_BUILD_CONFIGURE_ARGS[@]+"${CMAKE_BUILD_CONFIGURE_ARGS[@]}"}
    fi
  fi

  # Compute optimal parallel jobs based on available memory
  if [[ -z "${PARALLEL_JOBS}" ]]; then
    PARALLEL_JOBS=$(cmake_build_jobs "${MB_PER_JOB}")
    info "Auto-detected parallel jobs: ${PARALLEL_JOBS} (memory-aware)"
  else
    info "Using specified parallel jobs: ${PARALLEL_JOBS}"
  fi

  local build_cmd=(cmake --build)
  if [[ -n "${BUILD_DIR}" ]]; then
    build_cmd+=("${BUILD_DIR}")
  fi
  if [[ -n "${PRESET}" && -z "${BUILD_DIR}" ]]; then
    build_cmd+=(--preset "${PRESET}")
  fi
  if [[ -n "${CMAKE_BUILD_CONFIG}" ]]; then
    build_cmd+=(--config "${CMAKE_BUILD_CONFIG}")
  fi
  if [[ -n "${CMAKE_BUILD_TARGET}" ]]; then
    build_cmd+=(--target "${CMAKE_BUILD_TARGET}")
  fi
  build_cmd+=(--parallel "${PARALLEL_JOBS}")

  info "Executing: ${build_cmd[*]}"

  if declare -F cmake_build_prebuild_hook >/dev/null 2>&1; then
    info "Running pre-build step${CMAKE_BUILD_PREBUILD_LABEL:+: ${CMAKE_BUILD_PREBUILD_LABEL}}"
    if ! cmake_build_prebuild_hook; then
      # Fatal by default: the pre-build step generates inputs, so a swallowed failure builds green without them.
      if [[ "${ALLOW_PREBUILD_FAILURE}" == "true" ]]; then
        warn "Pre-build step${CMAKE_BUILD_PREBUILD_LABEL:+ (${CMAKE_BUILD_PREBUILD_LABEL})} failed; continuing because --allow-prebuild-failure was given"
      else
        err "Pre-build step${CMAKE_BUILD_PREBUILD_LABEL:+ (${CMAKE_BUILD_PREBUILD_LABEL})} failed (pass --allow-prebuild-failure to downgrade this to a warning)"
      fi
    fi
  fi

  "${build_cmd[@]}"
}

# Full pipeline: parse args, prepare the environment, configure and build.
cmake_build_main() {
  cmake_build_parse_args "$@"
  cmake_build_prepare_env
  cmake_build_run
}
