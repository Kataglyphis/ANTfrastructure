#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

ARMNN_VERSION="${ARMNN_VERSION:-v25.11}"
ARMNN_REPO="${ARMNN_REPO:-https://github.com/ARM-software/armnn.git}"
ARMNN_SRC_DIR="${ARMNN_SRC_DIR:-/tmp/armnn-src}"
ARMNN_INSTALL_DIR="${ARMNN_INSTALL_DIR:-/opt/armnn}"
ARMNN_BUILD_DIR="${ARMNN_BUILD_DIR:-${ARMNN_SRC_DIR}/build}"
ACL_INSTALL_DIR="${ACL_INSTALL_DIR:-/opt/acl}"

ARCH="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

clone_armnn() {
  if [ ! -d "${ARMNN_SRC_DIR}" ]; then
    info "Cloning Arm NN ${ARMNN_VERSION} into ${ARMNN_SRC_DIR}"
    git clone --branch "${ARMNN_VERSION}" --depth 1 "${ARMNN_REPO}" "${ARMNN_SRC_DIR}"
    cd "${ARMNN_SRC_DIR}"
    git submodule update --init --recursive
  else
    info "Arm NN source already exists at ${ARMNN_SRC_DIR}"
  fi
}

build_armnn() {
  info "Building Arm NN for ${ARCH}"

  local cross_args=()
  if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${ARCH}" != "amd64" ]; then
    if command -v append_cmake_cross_args >/dev/null 2>&1; then
      # Canonical cross toolchain args (same helper opencv/litert/onnx use).
      append_cmake_cross_args cross_args
    else
      # Fallback: hand-rolled cross toolchain args (pre-helper environments).
      local cross_prefix triplet
      case "${ARCH}" in
        arm64|aarch64)
          cross_prefix="aarch64-linux-gnu"
          triplet="aarch64-linux-gnu"
          ;;
        *) die "No cross config for ${ARCH}" ;;
      esac
      cross_args=(
        -DCMAKE_C_COMPILER="${cross_prefix}-gcc"
        -DCMAKE_CXX_COMPILER="${cross_prefix}-g++"
        -DCMAKE_FIND_ROOT_PATH="/usr/${triplet}"
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
      )
    fi
  fi

  mkdir -p "${ARMNN_BUILD_DIR}"
  cd "${ARMNN_BUILD_DIR}"

  # Arm NN v25.11+ probes ACL's CMake package config directly (installed by
  # scons into ACL_BUILD_DIR). ARMCOMPUTE_ROOT points to the ACL build tree
  # which contains the generated cmake files and arm_compute_version.h.
  # GCC 16.1.0's -Werror=array-bounds triggers false positives on std::mutex
  # placement in ACL/Arm NN buffers; suppress to avoid build failure.
  cmake "${ARMNN_SRC_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${ARMNN_INSTALL_DIR}" \
    -DARMCOMPUTE_ROOT="${ACL_SRC_DIR:-/tmp/acl-src}" \
    -DARMCOMPUTE_BUILD_DIR="${ACL_SRC_DIR:-/tmp/acl-src}/build" \
    -DARMCOMPUTE_LIBS="${ACL_INSTALL_DIR}/lib" \
    -DBUILD_UNIT_TESTS=0 \
    -DBUILD_TESTS=0 \
    -DBUILD_BENCHMARK_TESTS=0 \
    -DBUILD_BENCHMARK_EXECUTABLE=0 \
    -DCMAKE_CXX_FLAGS="-Wno-array-bounds" \
    -DCMAKE_C_FLAGS="-Wno-array-bounds" \
    "${cross_args[@]}"

  cmake --build . -j"$(media_jobs)"
  cmake --install .

  info "Arm NN installed to ${ARMNN_INSTALL_DIR}"
  ls -la "${ARMNN_INSTALL_DIR}/lib/" 2>/dev/null | head -10 || true
}

main() {
  if [ "${ARCH}" != "arm64" ] && [ "${ARCH}" != "aarch64" ]; then
    info "Arm NN is only built for arm64; skipping on ${ARCH}"
    exit 0
  fi
  clone_armnn
  build_armnn "$@"
}

main "$@"
