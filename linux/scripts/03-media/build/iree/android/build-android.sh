#!/usr/bin/env bash
set -euo pipefail

# Non-gating: this cross-build is unvalidated, so every failure warns and exits 0 rather than failing the android image.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"

# The repo path first, then the image's absolute core: the image copies this file one level shallower.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/../../../../01-core/logging.sh" ]; then
  # shellcheck source=/dev/null
  . "$(dirname "${BASH_SOURCE[0]}")/../../../../01-core/logging.sh"
else
  # shellcheck disable=SC1091
  . /opt/scripts/core/logging.sh
fi

android_build_preamble_init "Android IREE build" "${ANDROID_API_LEVEL:-34}"

# No inline default: a literal would hide an ARG that Dockerfile.android failed to forward.
IREE_VERSION="${IREE_VERSION:-${1:?IREE_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${IREE_ROOT_ANDROID:-/opt/android/iree}"
: "${CMAKE_POLICY_VERSION_MINIMUM:=3.5}"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip \
  || { warn "Android IREE: apt deps install failed; skipping (non-gating)"; exit 0; }

# Skip the compiler-only submodules; the runtime never needs them and torch-mlir drags in a second llvm-project.
cd /opt
rm -rf iree-android
git clone --depth 1 -b "${IREE_VERSION}" https://github.com/iree-org/iree.git iree-android \
  || { warn "Android IREE: clone ${IREE_VERSION} failed; skipping (non-gating)"; exit 0; }
( cd iree-android && git \
    -c submodule."third_party/llvm-project".update=none \
    -c submodule."third_party/torch-mlir".update=none \
    -c submodule."third_party/stablehlo".update=none \
    submodule update --init --recursive --depth 1 ) \
  || { warn "Android IREE: submodule init failed; skipping (non-gating)"; exit 0; }

HOST_CC="$(resolve_host_compiler c)"
HOST_CXX="$(resolve_host_compiler cxx)"
PARALLEL_JOBS="$(media_jobs)"

_iree_runtime_cmake_args=(
  -DIREE_BUILD_COMPILER=OFF
  -DIREE_BUILD_PYTHON_BINDINGS=OFF
  -DIREE_BUILD_SAMPLES=OFF
  -DIREE_BUILD_TESTS=OFF
)

# Stage 1 — LLVM-free host tools for IREE_HOST_BIN_DIR.
HOST_BUILD=/opt/iree-android/build-host
HOST_INSTALL="${HOST_BUILD}/install"
cmake -GNinja -S /opt/iree-android -B "${HOST_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    "${_iree_runtime_cmake_args[@]}" \
    -DCMAKE_C_COMPILER="${HOST_CC}" \
    -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
    -DCMAKE_INSTALL_PREFIX="${HOST_INSTALL}" \
  || { warn "Android IREE: host-tools configure failed; skipping (non-gating)"; exit 0; }
cmake --build "${HOST_BUILD}" --target install -- -j"${PARALLEL_JOBS}" \
  || { warn "Android IREE: host-tools build failed; skipping (non-gating)"; exit 0; }

# Stage 2 — cross the runtime for Android against the host tools.
ANDROID_CMAKE_TARGET_ARGS=()
android_cmake_target_args ANDROID_CMAKE_TARGET_ARGS
TARGET_BUILD=/opt/iree-android/build-android
cmake -GNinja -S /opt/iree-android -B "${TARGET_BUILD}" \
    "${ANDROID_CMAKE_TARGET_ARGS[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM} \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DIREE_HOST_BIN_DIR="${HOST_INSTALL}/bin" \
    "${_iree_runtime_cmake_args[@]}" \
    -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
    -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  || { warn "Android IREE: target configure failed; skipping (non-gating)"; exit 0; }
ninja -C "${TARGET_BUILD}" -j"${PARALLEL_JOBS}" install \
  || cmake --build "${TARGET_BUILD}" --target install -j1 \
  || { warn "Android IREE: target build/install failed; skipping (non-gating)"; exit 0; }

echo "Android IREE runtime installed into ${INSTALL_DIR} (ABI ${ANDROID_ABI}, API ${ANDROID_API_LEVEL}; compiler intentionally not built)"

cd /opt
rm -rf iree-android
