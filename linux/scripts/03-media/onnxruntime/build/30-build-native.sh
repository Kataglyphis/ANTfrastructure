#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091

source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# ----------------------------
# Performance: Cache architecture detection
# ----------------------------

readonly TARGET_ARCH="${TARGET_ARCH:-$(uname -m 2>/dev/null || echo unknown)}"

patch_project_dnnl_cmake_policy_minimum() {
  local cmake_dir="${ORT_SRC_DIR}/cmake"
  [[ -d "${cmake_dir}" ]] || return 0

  local -a matches=()
  mapfile -t matches < <(grep -rlm1 --include='*.cmake' "ExternalProject_Add( *project_dnnl" "${cmake_dir}" 2>/dev/null || true)
  
  (( ${#matches[@]} )) || return 0

  local file
  for file in "${matches[@]}"; do
    [[ -n "${file}" && -f "${file}" ]] || continue
    grep -q "CMAKE_POLICY_VERSION_MINIMUM" "${file}" && continue

    info "Patching project_dnnl to pass CMAKE_POLICY_VERSION_MINIMUM in ${file}"
    python3 - "${file}" "${CMAKE_POLICY_VERSION_MINIMUM}" <<'PY'
import sys

path, minver = sys.argv[1], sys.argv[2]

with open(path, 'r') as f:
    data = f.read()

needle = 'ExternalProject_Add(project_dnnl'
start = data.find(needle)
if start == -1:
    sys.exit(0)

open_paren = data.find('(', start)
if open_paren == -1:
    sys.exit(0)

depth, end = 0, None
for i, ch in enumerate(data[open_paren:], open_paren):
    if ch == '(':
        depth += 1
    elif ch == ')':
        depth -= 1
        if depth == 0:
            end = i + 1
            break

if end is None:
    sys.exit(0)

block = data[start:end]
if 'CMAKE_POLICY_VERSION_MINIMUM' in block:
    sys.exit(0)

idx = block.find('CMAKE_ARGS')
if idx == -1:
    sys.exit(0)

block = block.replace('CMAKE_ARGS', f'CMAKE_ARGS -DCMAKE_POLICY_VERSION_MINIMUM={minver}', 1)
with open(path, 'w') as f:
    f.write(data[:start] + block + data[end:])
PY
  done
}

copy_libraries() {
  local src_dir="$1"
  local dst_dir="$2"
  
  mkdir -p "${dst_dir}"
  
  find "${src_dir}" -maxdepth 1 -type f \( \
    -name "libonnxruntime*.so*" -o \
    -name "libonnxruntime_providers_*.so*" \
  \) -exec cp -t "${dst_dir}/" {} + 2>/dev/null || true
}

create_symlinks() {
  local src_dir="$1"
  local dst_dir="$2"
  
  find "${src_dir}" -maxdepth 1 -type f -name "lib*.so*" -print0 2>/dev/null | \
    xargs -0 -r -P"${JOBS}" ln -sf -t "${dst_dir}/" 2>/dev/null || true
}

# ----------------------------
# Early exit check
# ----------------------------

if [[ "${BUILD_NATIVE_CPU}" != "true" ]]; then
  info "Skipping native CPU build (BUILD_NATIVE_CPU=false)"
  exit 0
fi

# ----------------------------
# Build configuration
# ----------------------------

declare -a NATIVE_CPU_EXTRA_ARGS=()
declare -a CMAKE_EXTRA_DEFINES=(
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
  "CMAKE_BUILD_TYPE=${NATIVE_CPU_CONFIG}"
  "onnxruntime_BUILD_UNIT_TESTS=OFF"
  "onnxruntime_BUILD_BENCHMARKS=OFF"
)

# Global settings with defaults

BUILD_DNNL_EP="${BUILD_DNNL_EP:-false}"
BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-false}"
BUILD_ACL_EP="${BUILD_ACL_EP:-false}"

# Architecture-specific configuration

case "${TARGET_ARCH}" in
  x86_64)
    if [[ "${BUILD_DNNL_EP}" == "true" ]]; then
      info "Enabling oneDNN (DNNL) EP for native CPU build (arch=${TARGET_ARCH})"
      patch_project_dnnl_cmake_policy_minimum
      NATIVE_CPU_EXTRA_ARGS+=("--use_dnnl")
    fi
    ;;
    
  arm*|aarch64*)
    BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"
    
    [[ "${BUILD_XNNPACK_EP}" == "true" ]] && {
      info "Enabling XNNPACK EP for native CPU build (arch=${TARGET_ARCH})"
      NATIVE_CPU_EXTRA_ARGS+=("--use_xnnpack")
    }

    if [[ "${BUILD_ACL_EP}" == "true" ]]; then
      [[ -n "${ACL_HOME:-}" ]] || err "BUILD_ACL_EP=true but ACL_HOME is empty"
      [[ -n "${ACL_LIBS:-}" ]] || err "BUILD_ACL_EP=true but ACL_LIBS is empty"
      info "Enabling Arm Compute Library (ACL) EP (arch=${TARGET_ARCH})"
      NATIVE_CPU_EXTRA_ARGS+=("--use_acl" "--acl_home=${ACL_HOME}" "--acl_libs=${ACL_LIBS}")
    fi
    ;;
    
  riscv*)
    info "Detected RISC-V architecture (${TARGET_ARCH})"
    
    BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"
    ENABLE_RVV="${ENABLE_RVV:-true}"
    RVV_VERSION="${RVV_VERSION:-1.0}"
    
    [[ "${BUILD_XNNPACK_EP}" == "true" ]] && {
      info "Enabling XNNPACK EP for RISC-V (experimental)"
      NATIVE_CPU_EXTRA_ARGS+=("--use_xnnpack")
    }

    # RVV configuration
    if [[ "${ENABLE_RVV}" == "true" ]]; then
      declare -A RVV_MARCH_MAP=(
        ["1.0"]="rv64gcv"
        ["0.7"]="rv64gcv0p7"
        ["0.7.1"]="rv64gcv0p7"
      )
      RVV_MARCH="${RVV_MARCH_MAP[${RVV_VERSION}]:-rv64gcv}"
      [[ -z "${RVV_MARCH_MAP[${RVV_VERSION}]:-}" ]] && warn "Unknown RVV_VERSION=${RVV_VERSION}, using 1.0"
      
      info "Using RVV ${RVV_VERSION} (march=${RVV_MARCH})"
      CMAKE_EXTRA_DEFINES+=(
        "CMAKE_C_FLAGS=-march=${RVV_MARCH} -mtune=generic-rv64"
        "CMAKE_CXX_FLAGS=-march=${RVV_MARCH} -mtune=generic-rv64"
      )
    else
      CMAKE_EXTRA_DEFINES+=(
        "CMAKE_C_FLAGS=-march=rv64gc -mtune=generic-rv64"
        "CMAKE_CXX_FLAGS=-march=rv64gc -mtune=generic-rv64"
      )
    fi

    info "=== RISC-V Configuration ==="
    info "  XNNPACK: ${BUILD_XNNPACK_EP}, RVV: ${ENABLE_RVV}${ENABLE_RVV:+ (${RVV_VERSION})}"
    ;;
    
  *)
    info "Generic CPU build (arch=${TARGET_ARCH})"
    ;;
esac

# ----------------------------
# Build execution
# ----------------------------

BUILD_SH="${ORT_SRC_DIR}/build.sh"
[[ -x "${BUILD_SH}" ]] || err "build.sh not found or not executable at ${BUILD_SH}"

info ">>> Native CPU build: ${NATIVE_CPU_CONFIG} (shared lib, ${JOBS} parallel jobs)"

# Prepare output directory

mkdir -p "${NATIVE_CPU_OUTPUT_DIR}"/{lib,include} 2>/dev/null || true

# Clean build dir only if exists

[[ -d "${NATIVE_CPU_BUILD_DIR}" ]] && rm -rf "${NATIVE_CPU_BUILD_DIR}"

# Execute build

"${BUILD_SH}" \
  --build_dir "${NATIVE_CPU_BUILD_DIR}" \
  --config "${NATIVE_CPU_CONFIG}" \
  --build_shared_lib \
  --parallel "${JOBS}" \
  --enable_training_apis \
  --cmake_extra_defines "${CMAKE_EXTRA_DEFINES[@]}" \
  --compile_no_warning_as_error \
  --skip_submodule_sync \
  --skip_tests \
  --allow_running_as_root \
  "${NATIVE_CPU_EXTRA_ARGS[@]}"

# ----------------------------

# Post-build: Copy artifacts

# ----------------------------

# Copy headers

if command -v rsync &>/dev/null; then
  rsync -a --delete "${ORT_SRC_DIR}/include/" "${NATIVE_CPU_OUTPUT_DIR}/include/" 2>/dev/null || \
    cp -a "${ORT_SRC_DIR}/include/." "${NATIVE_CPU_OUTPUT_DIR}/include/" 2>/dev/null || \
    warn "Include directory not found at ${ORT_SRC_DIR}/include"
else
  rm -rf "${NATIVE_CPU_OUTPUT_DIR}/include"
  cp -a "${ORT_SRC_DIR}/include" "${NATIVE_CPU_OUTPUT_DIR}/" 2>/dev/null || \
    warn "Include directory not found at ${ORT_SRC_DIR}/include"
fi

# Copy libraries

copy_libraries "${NATIVE_CPU_BUILD_DIR}/${NATIVE_CPU_CONFIG}" "${NATIVE_CPU_OUTPUT_DIR}/lib"

# Create symlinks

create_symlinks "${NATIVE_CPU_OUTPUT_DIR}/lib" "/usr/local/lib"
ldconfig 2>/dev/null || true

info "Native CPU artifacts in ${NATIVE_CPU_OUTPUT_DIR}"
ls -lh "${NATIVE_CPU_OUTPUT_DIR}/lib"/*.so* 2>/dev/null | head -20 || true
