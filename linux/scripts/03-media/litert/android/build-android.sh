#!/usr/bin/env bash
set -euxo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

resolve_host_compiler() {
  case "$1" in
    c)
      for candidate in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do
        [ -x "${candidate}" ] && {
          printf '%s' "${candidate}"
          return 0
        }
      done
      command -v gcc 2>/dev/null || command -v cc 2>/dev/null || command -v clang 2>/dev/null || true
      ;;
    cxx)
      for candidate in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do
        [ -x "${candidate}" ] && {
          printf '%s' "${candidate}"
          return 0
        }
      done
      command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || true
      ;;
    *)
      return 1
      ;;
  esac
}

if ! android_require_amd64_build_host "Android LiteRT build"; then
  exit 0
fi

TARGET_ARCH="$(android_target_arch)"
ANDROID_ABI="$(android_target_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

LITERT_VERSION="${1:-v2.1.4}"
ANDROID_API_LEVEL="$(android_raise_api_level_if_needed "${TARGET_ARCH}" "${ANDROID_API_LEVEL:-34}" "Android LiteRT build")"
INSTALL_DIR="${LITERT_ROOT_ANDROID:-/opt/android/litert}"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip

cd /opt
rm -rf litert-android
git clone --depth 1 -b ${LITERT_VERSION} https://github.com/google-ai-edge/LiteRT.git litert-android
cd litert-android

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

HOST_CC="$(resolve_host_compiler c)"
HOST_CXX="$(resolve_host_compiler cxx)"

mkdir -p litert/build-android && cd litert/build-android
cmake -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
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

ninja -j"$(nproc)" install || cmake --build . --target install -j1

cd /opt
rm -rf litert-android
