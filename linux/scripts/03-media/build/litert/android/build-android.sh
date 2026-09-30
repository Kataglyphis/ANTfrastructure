#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"

# Shared with build-litert.sh so neither lane loses eigen's fallback mirror.
# shellcheck source=litert-eigen-fetch.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/litert-eigen-fetch.sh"

# No android-ABI QAIRT is ever staged; see docs/qnn-linux.md#no-staged-sdk-upstreams-unhashed-15-gb-download
# shellcheck source=litert-qairt-guard.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/litert-qairt-guard.sh"

android_build_preamble_init "Android LiteRT build" "${ANDROID_API_LEVEL:-34}"

# No inline default: a literal would hide an ARG that Dockerfile.android failed to forward.
LITERT_VERSION="${LITERT_VERSION:-${1:?LITERT_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${LITERT_ROOT_ANDROID:-/opt/android/litert}"
: "${CMAKE_POLICY_VERSION_MINIMUM:=3.5}"

apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip

android_clone_shallow "https://github.com/google-ai-edge/LiteRT.git" "${LITERT_VERSION}" litert-android

# cwd is the clone root after android_clone_shallow.
_litert_disable_qairt_header_download "${PWD}"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

HOST_CC="$(resolve_host_compiler c)"
HOST_CXX="$(resolve_host_compiler cxx)"

mkdir -p litert/build-android && cd litert/build-android

# FetchContent downloads can truncate mid-transfer, so a failed configure retries from wiped state.
configure_litert_android() {
  cmake -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
    "${LITERT_EIGEN_FETCH_FLAGS[@]}" \
    -DANDROID_ABI="${ANDROID_ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM} \
    -DTFLITE_ENABLE_XNNPACK=ON \
    -DTFLITE_ENABLE_RUY=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DRUY_PROFILER=0 \
    -DRUY_ENABLE_INSTRUMENTATION=OFF \
    -DRUY_PROFILER_INSTRUMENTATION=OFF \
    -DRUY_BUILD_TOOLS=OFF \
    -DRUY_BUILD_TESTING=OFF \
    -DLITERT_HOST_C_COMPILER="${HOST_CC}" \
    -DLITERT_HOST_CXX_COMPILER="${HOST_CXX}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    ..
}

_cfg_max="${LITERT_ANDROID_CONFIGURE_RETRIES:-3}"
for _cfg_try in $(seq 1 "${_cfg_max}"); do
  if configure_litert_android; then
    break
  fi
  if [ "${_cfg_try}" -eq "${_cfg_max}" ]; then
    echo "FATAL: LiteRT Android cmake configure failed after ${_cfg_max} attempts (repeated vendored-download failure, e.g. a truncated qnn_headers.zip)" >&2
    exit 1
  fi
  echo "WARNING: LiteRT Android cmake configure failed (attempt ${_cfg_try}/${_cfg_max}); wiping partial FetchContent downloads and retrying..." >&2
  rm -rf _deps CMakeCache.txt CMakeFiles 2>/dev/null || true
  sleep 5
done

PARALLEL_JOBS="$(media_jobs)"
ninja -j"${PARALLEL_JOBS}" install || cmake --build . --target install -j1

cd /opt
rm -rf litert-android
