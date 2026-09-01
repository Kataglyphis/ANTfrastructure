#!/usr/bin/env bash
# cmake-build.sh - generic "configure + build a CMake project in a container" core.
#
# Project-agnostic: a wrapper sets the CMAKE_BUILD_DEFAULT_* variables, may
# declare cmake_build_prebuild_hook, sources this file and calls
# cmake_build_main "$@". Variables and the hook contract (a non-zero return is
# FATAL by default) are in docs/shared-script-libraries.md § cmake-build.sh.
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.
[ -n "${_CMAKE_BUILD_SH_LOADED:-}" ] && return 0
_CMAKE_BUILD_SH_LOADED=1

_CMAKE_BUILD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CMAKE_BUILD_CORE_DIR="${_CMAKE_BUILD_LIB_DIR}/../01-core"

# ---------------------------------------------------------------------------
# Shared helpers: prefer the real 01-core modules, fall back to local minimals
# ---------------------------------------------------------------------------
if ! declare -F info >/dev/null 2>&1; then
  if [[ -f "${_CMAKE_BUILD_CORE_DIR}/logging.sh" ]]; then
    # shellcheck source=../01-core/logging.sh
    source "${_CMAKE_BUILD_CORE_DIR}/logging.sh"
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

cmake_build_usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [preset]

${CMAKE_BUILD_USAGE_INTRO:-Configures and builds a CMake project.} Options:
  --preset NAME            CMake configure/build preset (default: ${CMAKE_BUILD_DEFAULT_PRESET:-<none>})
  --build-dir DIR          build directory (default: ${CMAKE_BUILD_DEFAULT_BUILD_DIR:-build})
  --build-config CONFIG    value for 'cmake --build --config'
  --build-target TARGET    value for 'cmake --build --target'
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Fills PRESET, BUILD_DIR, CLEAN_BUILD_DIR, SKIP_CONFIGURE, CMAKE_BUILD_CONFIG,
# CMAKE_BUILD_TARGET, PARALLEL_JOBS, MB_PER_JOB, CARGO_CACHE_DIR,
# ALLOW_PREBUILD_FAILURE and CMAKE_BUILD_POSITIONAL.
#
# Precedence per setting: CLI flag > pre-existing environment variable >
# caller default. A trailing positional argument is accepted as the preset so
# `<script> linux-release-clang` keeps working.
cmake_build_parse_args() {
  local preset_arg="" build_dir_arg="" clean_arg="" skip_arg=""
  local config_arg="" target_arg=""
  local vulkan_version_arg="" vulkan_setup_arg="" vulkan_sdk_arg=""

  PARALLEL_JOBS="${PARALLEL_JOBS:-}"
  MB_PER_JOB="${CMAKE_BUILD_DEFAULT_MB_PER_JOB:-4000}"
  ALLOW_PREBUILD_FAILURE="${CMAKE_BUILD_DEFAULT_ALLOW_PREBUILD_FAILURE:-false}"
  CMAKE_BUILD_POSITIONAL=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset)
        preset_arg="${2:-}"
        shift 2
        ;;
      --build-dir)
        build_dir_arg="${2:-}"
        shift 2
        ;;
      --clean-build-dir)
        clean_arg="${2:-}"
        shift 2
        ;;
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
      --cargo-cache-dir)
        CARGO_CACHE_DIR="${2:-}"
        shift 2
        ;;
      --parallel)
        PARALLEL_JOBS="${2:-}"
        shift 2
        ;;
      --mb-per-job)
        MB_PER_JOB="${2:-}"
        shift 2
        ;;
      --build-config)
        config_arg="${2:-}"
        shift 2
        ;;
      --build-target)
        target_arg="${2:-}"
        shift 2
        ;;
      --allow-prebuild-failure)
        ALLOW_PREBUILD_FAILURE="true"
        shift
        ;;
      --vulkan-version)
        vulkan_version_arg="${2:-}"
        shift 2
        ;;
      --vulkan-setup-script)
        vulkan_setup_arg="${2:-}"
        shift 2
        ;;
      --vulkan-sdk)
        vulkan_sdk_arg="${2:-}"
        shift 2
        ;;
      -h|--help)
        cmake_build_usage
        exit 0
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
    CMAKE_BUILD_POSITIONAL=("$@")
  fi

  # Vulkan selection: an explicit flag always wins over the inherited env.
  if [[ -n "${vulkan_version_arg}" ]]; then
    VULKAN_VERSION="${vulkan_version_arg}"
  fi
  if [[ -n "${vulkan_setup_arg}" ]]; then
    VULKAN_SETUP_SCRIPT="${vulkan_setup_arg}"
  fi
  if [[ -n "${vulkan_sdk_arg}" ]]; then
    VULKAN_SDK="${vulkan_sdk_arg}"
  fi
  if [[ -z "${vulkan_setup_arg}" && -z "${VULKAN_SETUP_SCRIPT:-}" \
        && -n "${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT:-}" \
        && -f "${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT}" ]]; then
    VULKAN_SETUP_SCRIPT="${CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT}"
  fi

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

# ---------------------------------------------------------------------------
# Environment preparation
# ---------------------------------------------------------------------------
# Makes a container image usable as an unprivileged build environment:
# git safe.directory, ccache/sccache sanity, Vulkan env, writable cargo and
# compiler-cache directories. Safe to call more than once.
cmake_build_prepare_env() {
  local safe_dir="${CMAKE_BUILD_SAFE_DIRECTORY-/workspace}"
  if [[ -n "${safe_dir}" ]]; then
    git config --global --add safe.directory "${safe_dir}" || true
  fi

  # The :latest-cross image sets CCACHE_SECONDARY_STORAGE=true, but that variable
  # is ccache's remote_storage and must be a URL - ccache parses "true" as one and
  # dies with "URL scheme must not be empty: true" on EVERY compile. sccache
  # (clang presets) ignores it, so only the gcc presets are hit, which is why the
  # gcc lanes - benchmarks (gcc) included - were red for months. Neutralize any
  # CCACHE_SECONDARY_STORAGE that is not an actual URL so the deployed image works
  # without a rebuild (the env is also removed at source in ContainerHub's
  # Dockerfile.package). A real remote URL, if ever set, is left intact.
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

  # How the cmake argument set is assembled:
  # docs/cross-build-verification.md
  if ! { mkdir -p "${CARGO_HOME:-/usr/local/cargo}/registry" 2>/dev/null \
         && [[ -w "${CARGO_HOME:-/usr/local/cargo}/registry" ]]; }; then
    if [[ -n "${CARGO_CACHE_DIR:-}" ]]; then
      export CARGO_HOME="${CARGO_CACHE_DIR}"
      # Also redirect the cargo target directory to the same volume (under
      # a subdirectory) so compiled artifacts bypass the 9p host mount which
      # has known permission issues with cargo's temp-file rename operations.
      export CARGO_TARGET_DIR="${CARGO_CACHE_DIR}/target"
      mkdir -p "${CARGO_TARGET_DIR}"
    else
      export CARGO_HOME="${TMPDIR:-/tmp}/cargo-home"
      export CARGO_TARGET_DIR="${CARGO_HOME}/target"
    fi
    mkdir -p "${CARGO_HOME}"
    echo "CARGO_HOME not writable in this image; using ${CARGO_HOME}"
  fi

  # Same treatment for the compiler caches. The image bakes
  # SCCACHE_DIR=/var/cache/sccache (ContainerHub Dockerfile.base), which is
  # only writable through BuildKit cache mounts during IMAGE builds; at
  # runtime it is root-owned, and as a non-root user every sccache-wrapped
  # compile dies with "failed to create directory ... Permission denied"
  # (sccache exits 254 — the exact failure that held the Linux CI x86 lane
  # red from 2026-07-28 to 2026-08-02). The cache never persisted across CI
  # containers anyway (no cache mount at runtime), so a container-local
  # fallback loses nothing.
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

# Memory-aware job count: the project's get_build_jobs wins, then
# 01-core/parallelism.sh, then a plain core count.
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

# ---------------------------------------------------------------------------
# Configure + build
# ---------------------------------------------------------------------------
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
    info "Configuring CMake with preset: ${PRESET}"
    if [[ -n "${BUILD_DIR}" ]]; then
      cmake -B "${BUILD_DIR}" --preset "${PRESET}"
    else
      cmake --preset "${PRESET}"
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
      # This used to be `|| warn "<step> failed"`. A warning is the wrong
      # severity: the pre-build step generates inputs the build or the runtime
      # depends on, so swallowing its exit code produces a "green" build with
      # missing artifacts that only fails much later (a shader precompile
      # failure once left CI with no SPIR-V at all, and the build still
      # passed). Failing loudly is the default; --allow-prebuild-failure is
      # the deliberate opt-out for callers that really can continue without it.
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
