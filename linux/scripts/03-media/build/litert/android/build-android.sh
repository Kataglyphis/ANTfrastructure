#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"

# EIGEN-NET (2026-08-21): LITERT_EIGEN_FETCH_FLAGS -- LiteRT's eigen fetch with a
# fallback mirror. Defined ONCE in litert-eigen-fetch.sh next to this script and
# shared with the cross build (03-media/build/litert/build-litert.sh); the flags
# used to be duplicated verbatim in both, which is exactly how one lane quietly
# loses the mirror. See that file's header for why it lives in this directory.
# Hard source: a missing helper fails the stage instead of silently configuring
# a single-homed fetch.
# shellcheck source=litert-eigen-fetch.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/litert-eigen-fetch.sh"

if [ -f /opt/scripts/core/compiler-resolution.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/compiler-resolution.sh
  resolve_host_compiler() { resolve_host_compiler_for_lang "$1"; }
else
  resolve_host_compiler() {
    case "$1" in
      c)
        for candidate in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v gcc 2>/dev/null || command -v cc 2>/dev/null || command -v clang 2>/dev/null || true
        ;;
      cxx)
        for candidate in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || true
        ;;
    esac
  }
fi

android_build_preamble_init "Android LiteRT build" "${ANDROID_API_LEVEL:-34}"

# C3 (2026-08-24): NO silent version fallback. The literal that used to sit
# here masked a broken ARG-forward and was actively wrong -- Dockerfile.android
# never declared this build-arg, so BuildKit dropped it and this script built
# v2.1.6 while versions.env pinned v2.2.0. An explicit `$1` still wins (manual
# invocation), otherwise the forwarded value is REQUIRED and a missing one is a
# loud failure instead of last release.
LITERT_VERSION="${LITERT_VERSION:-${1:?LITERT_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${LITERT_ROOT_ANDROID:-/opt/android/litert}"

apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip

android_clone_shallow "https://github.com/google-ai-edge/LiteRT.git" "${LITERT_VERSION}" litert-android

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

HOST_CC="$(resolve_host_compiler c)"
HOST_CXX="$(resolve_host_compiler cxx)"

mkdir -p litert/build-android && cd litert/build-android

# LiteRT's cmake configure pulls several vendored archives via FetchContent
# (e.g. qnn_headers.zip). Those downloads occasionally truncate mid-transfer and
# cmake then aborts at configure time with "ZIP decompression failed (-5) / file
# failed to extract" -- a transient flake, not a real error. Retry the configure,
# wiping the partial FetchContent state between attempts so it re-downloads from
# scratch. Same transient-download hardening used for the pinned tarballs
# elsewhere in the tree.
configure_litert_android() {
  cmake -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
    "${LITERT_EIGEN_FETCH_FLAGS[@]}" \
    -DANDROID_ABI="${ANDROID_ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
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
