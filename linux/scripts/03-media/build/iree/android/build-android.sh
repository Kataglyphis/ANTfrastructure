#!/usr/bin/env bash
set -euo pipefail

# build-android.sh — IREE (iree.dev) Android/NDK runtime build.
#
# Mirrors the litert/onnxruntime Android builds: cross-compiles the IREE RUNTIME
# for Android (NDK) into /opt/android/iree so an on-device Android consumer gets
# libiree + iree-run-module for the target ABI. IREE cross-builds in two stages
# (https://iree.dev/building-from-source/riscv/ — same host/target model for the
# NDK): an LLVM-free HOST-tools build feeds IREE_HOST_BIN_DIR, then the Android
# target build cross-compiles the runtime against it. BUILD_COMPILER stays OFF
# (the compiler embeds LLVM and is a host-only artifact), matching the riscv64
# lane and how litert ships only its runtime for Android.
#
# BEST-EFFORT / NON-GATING: this is a new, UNVALIDATED cross-build. Every fallible
# step WARNs and exits 0, leaving /opt/android/iree (pre-created in the android-sdk
# stage) empty rather than failing the whole android image. Expect a round of
# iteration the first time it runs under the real NDK toolchain.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"

if [ -f /opt/scripts/core/compiler-resolution.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/compiler-resolution.sh
  resolve_host_compiler() { resolve_host_compiler_for_lang "$1"; }
else
  # Prefer EXPLICIT /usr/bin host compilers (aligned with the litert copy):
  # the android stages inherit PATH=/opt/gcc-<ver>/bin:... from the toolchain,
  # so a bare `command -v gcc` resolved the custom CROSS GCC as the host
  # compiler. (Normally dead code — Dockerfile.android ships the canonical
  # compiler-resolution.sh since 2026-08-08 and the branch above wins.)
  resolve_host_compiler() {
    local candidate
    case "$1" in
      c)
        for candidate in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v gcc 2>/dev/null || command -v cc 2>/dev/null || command -v clang 2>/dev/null || true ;;
      cxx)
        for candidate in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || true ;;
    esac
  }
fi

warn() { printf 'WARNING: %s\n' "$*" >&2; }

android_build_preamble_init "Android IREE build" "${ANDROID_API_LEVEL:-34}"

# Inline default mirrors versions.env IREE_VERSION (the android stage does not
# source versions.env; same pattern as LITERT_VERSION in the litert build).
# C3 (2026-08-24): NO silent version fallback. The literal that used to sit
# here masked a broken ARG-forward and was actively wrong -- Dockerfile.android
# never declared this build-arg, so BuildKit dropped it and this script built
# v3.11.0 (matched the pin only by coincidence) while versions.env pinned v3.11.0. An explicit `$1` still wins (manual
# invocation), otherwise the forwarded value is REQUIRED and a missing one is a
# loud failure instead of last release.
IREE_VERSION="${IREE_VERSION:-${1:?IREE_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${IREE_ROOT_ANDROID:-/opt/android/iree}"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip \
  || { warn "Android IREE: apt deps install failed; skipping (non-gating)"; exit 0; }

# Clone at the pinned tag, EXCLUDING the compiler-only heavyweights: llvm-project
# plus torch-mlir + stablehlo (MLIR-dialect compiler inputs the runtime never
# needs; torch-mlir also drags a full nested externals/llvm-project via --recursive).
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

# Stage 1 — LLVM-free host tools for IREE_HOST_BIN_DIR.
HOST_BUILD=/opt/iree-android/build-host
HOST_INSTALL="${HOST_BUILD}/install"
cmake -GNinja -S /opt/iree-android -B "${HOST_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DIREE_BUILD_COMPILER=OFF \
    -DIREE_BUILD_PYTHON_BINDINGS=OFF \
    -DIREE_BUILD_SAMPLES=OFF \
    -DIREE_BUILD_TESTS=OFF \
    -DCMAKE_C_COMPILER="${HOST_CC}" \
    -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
    -DCMAKE_INSTALL_PREFIX="${HOST_INSTALL}" \
  || { warn "Android IREE: host-tools configure failed; skipping (non-gating)"; exit 0; }
cmake --build "${HOST_BUILD}" --target install -- -j"${PARALLEL_JOBS}" \
  || { warn "Android IREE: host-tools build failed; skipping (non-gating)"; exit 0; }

# Stage 2 — cross the runtime for Android against the host tools.
TARGET_BUILD=/opt/iree-android/build-android
cmake -GNinja -S /opt/iree-android -B "${TARGET_BUILD}" \
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${ANDROID_ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DIREE_HOST_BIN_DIR="${HOST_INSTALL}/bin" \
    -DIREE_BUILD_COMPILER=OFF \
    -DIREE_BUILD_PYTHON_BINDINGS=OFF \
    -DIREE_BUILD_SAMPLES=OFF \
    -DIREE_BUILD_TESTS=OFF \
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
