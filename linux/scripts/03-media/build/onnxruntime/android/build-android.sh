#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"
android_build_preamble_init "Android ONNX Runtime build" "${ANDROID_API_LEVEL:-34}"

case "${TARGET_ARCH}" in
  riscv64|riscv|rv64*)
    echo "Skipping Android ONNX Runtime build for riscv64 because upstream build.sh does not support that Android ABI"
    exit 0
    ;;
esac

ORT_VERSION="${1:-${ONNXRUNTIME_VERSION:-v1.27.0}}"
INSTALL_DIR="${ONNXRUNTIME_ROOT_ANDROID:-/opt/android/onnxruntime}"

apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 python3-pip openjdk-21-jdk curl

PARALLEL_JOBS="$(nproc)"
if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    PARALLEL_JOBS="$(compute_jobs_with_mem_cap "" 2000)"
  fi
fi

cd /opt
rm -rf onnxruntime-android
git clone --depth 1 -b ${ORT_VERSION} https://github.com/microsoft/onnxruntime.git onnxruntime-android
cd onnxruntime-android

# Patch Android Gradle Plugin version to support JDK 21
sed -i "s/classpath 'com.android.tools.build:gradle:7.4.2'/classpath 'com.android.tools.build:gradle:8.3.1'/g" java/build-android.gradle java/src/test/android/build.gradle
# AGP 8.0+ disables buildConfig by default, but ORT test app needs it
sed -i '/android {/a \    buildFeatures {\n        buildConfig = true\n    }' java/src/test/android/app/build.gradle

: "${ANDROID_HOME:?ANDROID_HOME must be set}"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

./build.sh \
  --allow_running_as_root \
  --android \
  --android_sdk_path "${ANDROID_HOME}" \
  --android_ndk_path "${ANDROID_NDK_HOME}" \
  --android_abi "${ANDROID_ABI}" \
  --android_api "${ANDROID_API_LEVEL}" \
  --build_java \
  --build_shared_lib \
  --config Release \
  --parallel "$PARALLEL_JOBS" \
  --skip_tests \
  --use_nnapi \
  --use_xnnpack \
  --update \
  --build

mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/include" "${INSTALL_DIR}/java"
cp -r include/* "${INSTALL_DIR}/include/" || true
find build/Android/Release -name "libonnxruntime*.so" -print0 | xargs -0 cp -t "${INSTALL_DIR}/lib/" 2>/dev/null || true
find build/Android/Release -name "*.aar" -print0 | xargs -0 cp -t "${INSTALL_DIR}/java/" 2>/dev/null || true

cd /opt
rm -rf onnxruntime-android
