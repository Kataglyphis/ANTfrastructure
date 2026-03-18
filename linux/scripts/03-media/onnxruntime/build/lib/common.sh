#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Prefer shared platform helpers if available (container layout or repo layout)
_ONNX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOGGING_CANDIDATES=(
  "/opt/scripts/core/logging.sh"
  "${_ONNX_LIB_DIR}/../../../../01-core/logging.sh"
)
_PLATFORM_CANDIDATES=(
  "/opt/scripts/core/platform.sh"
  "${_ONNX_LIB_DIR}/../../../../01-core/platform.sh"
)
_PARALLEL_CANDIDATES=(
  "/opt/scripts/core/parallelism.sh"
  "${_ONNX_LIB_DIR}/../../../../01-core/parallelism.sh"
)

for f in "${_LOGGING_CANDIDATES[@]}"; do
  if [ -f "${f}" ]; then
    # shellcheck disable=SC1090
    source "${f}"
    break
  fi
done
for f in "${_PLATFORM_CANDIDATES[@]}"; do
  if [ -f "${f}" ]; then
    # shellcheck disable=SC1090
    source "${f}"
    break
  fi
done
for f in "${_PARALLEL_CANDIDATES[@]}"; do
  if [ -f "${f}" ]; then
    # shellcheck disable=SC1090
    source "${f}"
    break
  fi
done

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
if ! command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
  compute_jobs_with_mem_cap() {
    local requested="${1:-}"
    local mb_per_job="${2:-2000}"
    local cores avail_mb max_by_mem jobs
    cores="$(nproc --all 2>/dev/null || echo 1)"
    jobs="${cores}"
    if [ -n "${requested}" ]; then
      jobs="${requested}"
    fi
    avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo 2>/dev/null || true)"
    [ -z "${avail_mb}" ] && avail_mb=2048
    max_by_mem=$(( avail_mb / mb_per_job ))
    [ "${max_by_mem}" -lt 1 ] && max_by_mem=1
    if [ "${jobs}" -gt "${max_by_mem}" ] 2>/dev/null; then
      jobs="${max_by_mem}"
    fi
    [ "${jobs}" -lt 1 ] && jobs=1
    echo "${jobs}"
  }
fi

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
  ORT_VERSION="${ORT_VERSION:-v1.24.3}"
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

  BUILD_GENAI="${BUILD_GENAI:-true}"
  GENAI_VERSION="${GENAI_VERSION:-v0.6.0}"
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
  export NATIVE_CPU_BUILD_DIR NATIVE_CPU_OUTPUT_DIR NATIVE_CPU_CONFIG
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
