#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

if ! android_require_amd64_build_host "Android ONNX Runtime build"; then
  exit 0
fi

TARGET_ARCH="$(android_target_arch)"
ANDROID_ABI="$(android_target_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

case "${TARGET_ARCH}" in
  riscv64|riscv|rv64*)
    echo "Skipping Android ONNX Runtime build for riscv64 because upstream build.sh does not support that Android ABI"
    exit 0
    ;;
esac

ORT_VERSION="${1:-v1.26.0}"
ANDROID_API_LEVEL="$(android_raise_api_level_if_needed "${TARGET_ARCH}" "${ANDROID_API_LEVEL:-34}" "Android ONNX Runtime build")"
INSTALL_DIR="${ONNXRUNTIME_ROOT_ANDROID:-/opt/android/onnxruntime}"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 python3-pip openjdk-21-jdk curl

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
  --parallel "$(nproc)" \
  --skip_tests \
  --use_nnapi \
  --use_xnnpack \
  --update \
  --build

mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/include" "${INSTALL_DIR}/java"
cp -r include/* "${INSTALL_DIR}/include/" || true
find build/Android/Release -name "libonnxruntime*.so" -exec cp {} "${INSTALL_DIR}/lib/" \;
find build/Android/Release -name "*.aar" -exec cp {} "${INSTALL_DIR}/java/" \; 2>/dev/null || true

cd /opt
rm -rf onnxruntime-android
