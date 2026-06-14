#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

_ONNX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preserve caller's SCRIPT_DIR — this may be the build-onnxruntime.sh directory
# which dispatches to step scripts using SCRIPT_DIR. Do NOT overwrite it.
ONNX_SCRIPT_DIR="${_ONNX_LIB_DIR}"
: "${SCRIPT_DIR:=${ONNX_SCRIPT_DIR}}"

# Use the standard modules.sh framework
for helper in \
    "/opt/scripts/core/modules.sh" \
    "${_ONNX_LIB_DIR}/../../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        source_modules_framework "${_ONNX_LIB_DIR}"
        break
    fi
done

source_module logging.sh || true
source_module platform.sh || true
source_module cross-env.sh || true
source_module parallelism.sh || true

# Fallback for cross_build_is_active in case cross-env.sh guard prevents reload
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  cross_build_is_active() { cross_build_enabled; }
fi

# Fallback definitions — safety nets when modules.sh framework is unavailable.
# Fallback loggers if shared logging is not present
if ! command -v info >/dev/null 2>&1; then
  info() { printf '[INFO] %s\n' "$*"; }
fi
if ! command -v warn >/dev/null 2>&1; then
  warn() { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! command -v err >/dev/null 2>&1; then
  err()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
fi

# Fallbacks if shared helpers are not present
if ! command -v arch_oci >/dev/null 2>&1; then
  arch_oci() {
    local raw="${TARGETARCH:-${TARGET_ARCH:-}}"
    if [ -z "${raw}" ]; then
      raw="$(uname -m 2>/dev/null || echo unknown)"
    fi
    case "${raw}" in
      amd64|x86_64) printf '%s' "amd64" ;;
      arm64|aarch64) printf '%s' "arm64" ;;
      *) printf '%s' "${raw}" ;;
    esac
  }
fi
if ! command -v is_amd64_arch >/dev/null 2>&1; then
  is_amd64_arch() { [ "$(arch_oci)" = "amd64" ]; }
fi
if ! command -v cross_build_enabled >/dev/null 2>&1; then
  cross_build_enabled() { return 1; }
fi
if ! command -v host_python_bin >/dev/null 2>&1; then
  host_python_bin() {
    if [ -n "${MEDIA_HOST_PYTHON:-}" ] && [ -x "${MEDIA_HOST_PYTHON}" ]; then
      printf '%s' "${MEDIA_HOST_PYTHON}"
      return 0
    fi

    if [ -n "${UV_PYTHON:-}" ] && [ -x "${UV_PYTHON}" ]; then
      printf '%s' "${UV_PYTHON}"
      return 0
    fi

    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
      printf '%s' "${VIRTUAL_ENV}/bin/python"
      return 0
    fi

    if [ -n "${PYTHON_MAJOR_MINOR:-}" ] && [ -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
      printf '%s' "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
      return 0
    fi

    if [ -n "${PYTHON_VERSION:-}" ] && command -v version_major_minor >/dev/null 2>&1; then
      local python_mm=""
      python_mm="$(version_major_minor "${PYTHON_VERSION}" 2>/dev/null || true)"
      if [ -n "${python_mm}" ] && [ -x "/usr/local/bin/python${python_mm}" ]; then
        printf '%s' "/usr/local/bin/python${python_mm}"
        return 0
      fi
    fi

    command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
  }
fi
if ! command -v host_python_major_minor >/dev/null 2>&1; then
  host_python_major_minor() {
    local python_bin

    if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
      printf '%s' "${PYTHON_MAJOR_MINOR}"
      return 0
    fi

    if [ -n "${PYTHON_VERSION:-}" ] && command -v version_major_minor >/dev/null 2>&1; then
      version_major_minor "${PYTHON_VERSION}"
      return 0
    fi

    python_bin="$(host_python_bin)" || return 1
    "${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
  }
fi
# compute_jobs_with_mem_cap is loaded from the canonical parallelism.sh module
# (sourced above via source_module). Do not add a fallback here — the canonical
# version includes cgroup awareness, AGGRESSIVE_PARALLELISM, and PARALLEL_JOBS.

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found in PATH: $1"
}

usage_common() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --ort-version <tag>           ONNX Runtime git tag/branch to checkout (default: ${ORT_VERSION})
  --build-type <cfg>            Native CPU build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${NATIVE_CPU_CONFIG})
  --wasm-config <cfg>           WASM build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${WASM_CONFIG})
  --genai-version <tag>          ONNX Runtime GenAI git tag/branch to checkout (default: ${GENAI_VERSION})
  --genai-config <cfg>           GenAI build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${GENAI_CONFIG})
  --skip-genai                   Skip GenAI build (default: enabled)
  -h, --help                    Show this help

Notes:
  - CLI args override environment variables.
  - GenAI is built by default. Use --skip-genai or BUILD_GENAI=false to disable.
  - You can also set ORT_VERSION, NATIVE_CPU_CONFIG, WASM_CONFIG, GENAI_VERSION, GENAI_CONFIG via env.
EOF
}

init_defaults() {
  ORT_VERSION="${ORT_VERSION:-v1.26.0}"
  ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
  ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"

  WASM_OUTPUT_DIR="${WASM_OUTPUT_DIR:-/usr/local/lib/onnxruntime-web}"
  WASM_CONFIG="${WASM_CONFIG:-Release}"
  BUILD_DIR="${BUILD_DIR:-${ORT_SRC_DIR}/build_wasm_output}"

  NATIVE_CPU_BUILD_DIR="${NATIVE_CPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_cpu}"
  NATIVE_CPU_OUTPUT_DIR="${NATIVE_CPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
  NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  NATIVE_CPU_CONFIG="${NATIVE_CPU_CONFIG:-Release}"

  BUILD_NATIVE_CPU="${BUILD_NATIVE_CPU:-true}"
  BUILD_DNNL_EP="${BUILD_DNNL_EP:-true}"
  BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"
  BUILD_ACL_EP="${BUILD_ACL_EP:-false}"
  ACL_HOME="${ACL_HOME:-}"
  ACL_LIBS="${ACL_LIBS:-}"

  BUILD_GENAI="${BUILD_GENAI:-true}"
  GENAI_VERSION="${GENAI_VERSION:-v0.13.1}"
  GENAI_REPO="${GENAI_REPO:-https://github.com/microsoft/onnxruntime-genai.git}"
  GENAI_SRC_DIR="${GENAI_SRC_DIR:-${ORT_SRC_DIR}-genai}"
  GENAI_BUILD_DIR="${GENAI_BUILD_DIR:-${GENAI_SRC_DIR}/build}"
  GENAI_OUTPUT_DIR="${GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}"
  GENAI_CONFIG="${GENAI_CONFIG:-Release}"

  USE_UV_VENV="${USE_UV_VENV:-true}"
  UV_VENV_DIR="${UV_VENV_DIR:-${ORT_SRC_DIR}/.venv}"

  CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

  SKIP_DEP_INSTALL="${SKIP_DEP_INSTALL:-false}"
  ENABLE_ASYNCIFY="${ENABLE_ASYNCIFY:-false}"
  ASYNCIFY_STACK_SIZE="${ASYNCIFY_STACK_SIZE:-5242880}"
}

parse_common_args() {
  init_defaults

  while [ $# -gt 0 ]; do
    case "$1" in
      --ort-version)
        [ $# -ge 2 ] || err "--ort-version requires a value"
        ORT_VERSION="$2"
        shift 2
        ;;
      --build-type|--native-cpu-config|--native-config)
        [ $# -ge 2 ] || err "$1 requires a value"
        NATIVE_CPU_CONFIG="$2"
        shift 2
        ;;
      --wasm-config)
        [ $# -ge 2 ] || err "--wasm-config requires a value"
        WASM_CONFIG="$2"
        shift 2
        ;;
      --genai-version)
        [ $# -ge 2 ] || err "--genai-version requires a value"
        GENAI_VERSION="$2"
        shift 2
        ;;
      --genai-config)
        [ $# -ge 2 ] || err "--genai-config requires a value"
        GENAI_CONFIG="$2"
        shift 2
        ;;
      --build-genai)
        BUILD_GENAI="true"
        shift
        ;;
      --skip-genai)
        BUILD_GENAI="false"
        shift
        ;;
      -h|--help)
        usage_common
        exit 0
        ;;
      *)
        err "Unknown argument: $1 (use --help)"
        ;;
    esac
  done

  validate_build_type "${NATIVE_CPU_CONFIG}" "--build-type"
  validate_build_type "${WASM_CONFIG}" "--wasm-config"
  validate_build_type "${GENAI_CONFIG}" "--genai-config"

  export ORT_VERSION ORT_REPO ORT_SRC_DIR
  export WASM_OUTPUT_DIR WASM_CONFIG BUILD_DIR
  export NATIVE_CPU_BUILD_DIR NATIVE_CPU_OUTPUT_DIR NATIVE_GPU_OUTPUT_DIR NATIVE_CPU_CONFIG
  export BUILD_NATIVE_CPU BUILD_DNNL_EP BUILD_XNNPACK_EP BUILD_ACL_EP ACL_HOME ACL_LIBS
  export BUILD_GENAI GENAI_VERSION GENAI_REPO GENAI_SRC_DIR GENAI_BUILD_DIR GENAI_OUTPUT_DIR GENAI_CONFIG
  export USE_UV_VENV UV_VENV_DIR
  export CMAKE_POLICY_VERSION_MINIMUM
  export SKIP_DEP_INSTALL ENABLE_ASYNCIFY ASYNCIFY_STACK_SIZE
}

validate_build_type() {
  local v="$1"
  local flag="$2"
  case "${v}" in
    Release|RelWithDebInfo|Debug|MinSizeRel) ;;
    *) err "Invalid ${flag} '${v}'" ;;
  esac
}

detect_jobs() {
  if [ -n "${JOBS:-}" ]; then
    export JOBS
    info "Using JOBS=${JOBS}"
    return 0
  fi

  JOBS="$(compute_jobs_with_mem_cap "" 2000)"
  export JOBS
  info "Using JOBS=${JOBS}"
}

source_build_acceleration_helpers() {
  local include_sccache="${1:-false}"
  local helper

  for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${_ONNX_LIB_DIR}/../../../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      setup_ccache
      if [ "${include_sccache}" = "true" ] && command -v setup_sccache >/dev/null 2>&1; then
        setup_sccache
      fi
      setup_lld_linker
      return 0
    fi
  done

  return 0
}

setup_host_python_environment() {
  HOST_PYTHON_BIN="$(host_python_bin)"
  export HOST_PYTHON_BIN
  export PYTHON_EXECUTABLE="${HOST_PYTHON_BIN}" \
         Python_EXECUTABLE="${HOST_PYTHON_BIN}" \
         Python3_EXECUTABLE="${HOST_PYTHON_BIN}"
}

ensure_uv_python_packages() {
  local python_bin="${1:-}"
  shift || true

  [ "$#" -gt 0 ] || return 0
  require_cmd uv

  if [ -z "${python_bin}" ]; then
    python_bin="$(host_python_bin)"
  fi

  uv pip install --python "${python_bin}" "$@"
}

ensure_onnx_output_tree() {
  local output_dir="${1:?output dir required}"

  mkdir -p "${output_dir}" "${output_dir}/lib" "${output_dir}/include" "${output_dir}/wheels"
}

ensure_onnx_gpu_placeholder_output_dir() {
  ensure_onnx_output_tree "${NATIVE_GPU_OUTPUT_DIR}"
}

collect_wheels_from_tree() {
  local search_root="${1:?search root required}"
  local output_dir="${2:?output dir required}"
  local wheel_label="${3:-wheel}"
  local wheel_path

  [ -d "${search_root}" ] || return 0
  mkdir -p "${output_dir}/wheels"

  local _wheels_found=0
  while read -r wheel_path; do
    _wheels_found=1
    info "Copying ${wheel_label}: ${wheel_path}"
    cp "${wheel_path}" "${output_dir}/wheels/"
    ls -lh "${output_dir}/wheels/$(basename "${wheel_path}")"
  done < <(find "${search_root}" -name "*.whl" -type f 2>/dev/null || true)
  [ "${_wheels_found}" -eq 1 ] || info "No wheels found in ${search_root}"
}

maybe_build_source_wheel() {
  local source_dir="${1:?source dir required}"
  local output_dir="${2:?output dir required}"
  local python_bin="${3:?python binary required}"
  local package_label="${4:-package}"

  if [ -n "$(ls -A "${output_dir}/wheels" 2>/dev/null || true)" ]; then
    return 0
  fi

  if [ -f "${source_dir}/pyproject.toml" ] || [ -f "${source_dir}/setup.py" ]; then
    info "No ${package_label} wheels found; attempting pip wheel build from source"
    mkdir -p "${output_dir}/wheels"
    "${python_bin}" -m pip wheel -w "${output_dir}/wheels" "${source_dir}" || info "pip wheel failed for ${package_label} source"
    ls -lh "${output_dir}/wheels"/*.whl 2>/dev/null || true
  else
    info "${package_label} python packaging not detected; skipping pip wheel"
  fi
}

copy_onnx_headers_to_output() {
  local output_dir="${1:?output dir required}"
  local search_dir header_path

  shift
  mkdir -p "${output_dir}/include"

  for search_dir in "$@"; do
    [ -d "${search_dir}/include" ] || continue
    cp -a "${search_dir}/include/." "${output_dir}/include/" 2>/dev/null || true
    info "Copied headers from ${search_dir}/include"
  done

  for search_dir in "$@"; do
    [ -d "${search_dir}/include" ] || continue
    while read -r header_path; do
      cp "${header_path}" "${output_dir}/include/" 2>/dev/null || true
    done < <(find "${search_dir}/include" -name "onnxruntime*.h" -type f 2>/dev/null || true)
  done
}

verify_onnxruntime_core_header() {
  local output_dir="${1:?output dir required}"
  shift || true

  if [ -f "${output_dir}/include/onnxruntime_c_api.h" ]; then
    info "Found onnxruntime_c_api.h in ${output_dir}/include"
    return 0
  fi

  warn "onnxruntime_c_api.h not found in ${output_dir}/include"
  for search_dir in "$@"; do
    [ -d "${search_dir}" ] || continue
    find "${search_dir}" -name "onnxruntime_c_api.h" 2>/dev/null | head -5 || true
  done
}

copy_onnx_libraries_to_output() {
  local build_dir="${1:?build dir required}"
  local build_config="${2:?build config required}"
  local output_dir="${3:?output dir required}"

  mkdir -p "${output_dir}/lib"
  find "${build_dir}/${build_config}" -maxdepth 1 -type f \
    \( -name "libonnxruntime*.so*" -o -name "libonnxruntime_providers_*.so*" \) \
    -exec cp -t "${output_dir}/lib/" {} + 2>/dev/null || true
}

ensure_onnxruntime_symlink() {
  local output_dir="${1:?output dir required}"
  local onnx_lib=""

  onnx_lib="$(find "${output_dir}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f | head -1)"
  if [ -n "${onnx_lib}" ] && [ ! -e "${output_dir}/lib/libonnxruntime.so" ]; then
    ln -sf "$(basename "${onnx_lib}")" "${output_dir}/lib/libonnxruntime.so"
    info "Created symlink: libonnxruntime.so -> $(basename "${onnx_lib}")"
  fi
}

symlink_output_libraries_into_usr_local() {
  local output_dir="${1:?output dir required}"

  find "${output_dir}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
    xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

  ldconfig 2>/dev/null || true
}

append_onnx_cross_cmake_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  local enable_python="OFF"
  if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
    enable_python="ON"
    info "Target Python dev files available; enabling ONNX Runtime Python in cross mode"
  fi

  build_args_ref+=(
    --cmake_extra_defines
    CMAKE_SYSTEM_NAME=Linux
    CMAKE_SYSTEM_PROCESSOR="${CROSS_TARGET_PROCESSOR}"
    CMAKE_C_COMPILER="${CC}"
    CMAKE_CXX_COMPILER="${CXX}"
    CMAKE_ASM_COMPILER="${CC}"
    CMAKE_SYSROOT=/
    CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    "onnxruntime_ENABLE_PYTHON=${enable_python}"
    onnxruntime_BUILD_UNIT_TESTS=OFF
    onnxruntime_GENERATE_TEST_REPORTS=OFF
  )
}

append_onnx_lld_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
    build_args_ref+=(
      --cmake_extra_defines
      CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
      CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld
      CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld
    )
    info "Using lld linker for faster linking"
  fi
}

append_onnx_ccache_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  if command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
    if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
      build_args_ref+=(
        --cmake_extra_defines
        CMAKE_C_COMPILER_LAUNCHER=ccache
        CMAKE_CXX_COMPILER_LAUNCHER=ccache
      )
      info "Using ccache for faster compilation (via cmake_extra_defines)"
    else
      info "ccache already configured via environment (CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER})"
    fi
  fi
}

pc_numeric_version_from_ort_version() {
  local v="$1"
  local out
  
  # Check if this is the main branch
  if [ "${v}" = "main" ] || [ "${v}" = "master" ]; then
    # Fetch version from GitHub
    out="$(curl -sL https://raw.githubusercontent.com/microsoft/onnxruntime/main/VERSION_NUMBER | tr -d '\n\r' | sed -E 's/[^0-9.].*//')"
    if [ -z "${out}" ]; then
      printf '%s' "0.0.0"
    else
      printf '%s' "${out}"
    fi
  else
    # Original logic for version tags
    out="$(printf '%s' "${v}" | sed -E 's/^v//' | sed -E 's/[^0-9.].*$//')"
    if [ -z "${out}" ]; then
      printf '%s' "0.0.0"
    else
      printf '%s' "${out}"
    fi
  fi
}

detect_target_arch() { arch_oci; }
