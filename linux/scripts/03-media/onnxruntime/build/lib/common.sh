#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

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
  -h, --help                    Show this help

Notes:
  - CLI args override environment variables.
  - You can also set ORT_VERSION, NATIVE_CPU_CONFIG, WASM_CONFIG via env.
EOF
}

init_defaults() {
  ORT_VERSION="${ORT_VERSION:-v1.23.2}"
  ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
  ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"

  WASM_OUTPUT_DIR="${WASM_OUTPUT_DIR:-/usr/local/lib/onnxruntime-web}"
  WASM_CONFIG="${WASM_CONFIG:-Release}"
  BUILD_DIR="${BUILD_DIR:-${ORT_SRC_DIR}/build_wasm_output}"

  NATIVE_CPU_BUILD_DIR="${NATIVE_CPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_cpu}"
  NATIVE_CPU_OUTPUT_DIR="${NATIVE_CPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
  NATIVE_CPU_CONFIG="${NATIVE_CPU_CONFIG:-Release}"

  BUILD_NATIVE_CPU="${BUILD_NATIVE_CPU:-true}"
  BUILD_DNNL_EP="${BUILD_DNNL_EP:-true}"
  BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"
  BUILD_ACL_EP="${BUILD_ACL_EP:-false}"
  ACL_HOME="${ACL_HOME:-}"
  ACL_LIBS="${ACL_LIBS:-}"

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

  export ORT_VERSION ORT_REPO ORT_SRC_DIR
  export WASM_OUTPUT_DIR WASM_CONFIG BUILD_DIR
  export NATIVE_CPU_BUILD_DIR NATIVE_CPU_OUTPUT_DIR NATIVE_CPU_CONFIG
  export BUILD_NATIVE_CPU BUILD_DNNL_EP BUILD_XNNPACK_EP BUILD_ACL_EP ACL_HOME ACL_LIBS
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

  local cores avail_mb max_by_mem
  cores="$(nproc --all || echo 1)"
  avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo || true)"
  [ -z "${avail_mb}" ] && avail_mb=2048
  max_by_mem=$(( avail_mb / 2000 ))
  JOBS=$(( cores < max_by_mem ? cores : max_by_mem ))
  [ "${JOBS}" -lt 1 ] && JOBS=1
  export JOBS
  info "Using JOBS=${JOBS}"
}

pc_numeric_version_from_ort_version() {
  local v="$1"
  local out
  out="$(printf '%s' "${v}" | sed -E 's/^v//' | sed -E 's/[^0-9.].*$//')"
  if [ -z "${out}" ]; then
    printf '%s' "0.0.0"
  else
    printf '%s' "${out}"
  fi
}

detect_target_arch() {
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

is_amd64_arch() {
  [ "$(detect_target_arch)" = "amd64" ]
}
