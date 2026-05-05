#!/usr/bin/env bash
set -euxo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

build_arch() {
  if command -v build_arch_oci >/dev/null 2>&1; then
    build_arch_oci
    return 0
  fi
  if [ -n "${BUILDARCH:-}" ]; then
    printf '%s' "${BUILDARCH}"
    return 0
  fi
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture 2>/dev/null && return 0
  fi
  uname -m || true
}

android_abi() {
  if command -v android_abi_for_target >/dev/null 2>&1; then
    android_abi_for_target
    return 0
  fi
  case "${TARGET_ARCH:-${TARGETARCH:-arm64}}" in
    amd64|x86_64) printf '%s' "x86_64" ;;
    arm64|aarch64) printf '%s' "arm64-v8a" ;;
    386|i386|i686|x86) printf '%s' "x86" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) printf '%s' "" ;;
  esac
}

if [ "$(build_arch)" != "amd64" ]; then
  echo "Skipping Android ONNX Runtime build on non-amd64 build host"
  exit 0
fi

ANDROID_ABI="$(android_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

ORT_VERSION="${1:-v1.24.4}"
INSTALL_DIR="/opt/android/onnxruntime"

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
  --android_api 34 \
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
