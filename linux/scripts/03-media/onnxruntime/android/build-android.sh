#!/usr/bin/env bash
set -euxo pipefail

is_x86_64() {
  local arch="${TARGETARCH:-$(uname -m)}"
  case "${arch}" in amd64|x86_64) return 0 ;; *) return 1 ;; esac
}

if ! is_x86_64; then
  echo "Skipping Android ONNX Runtime build on non-x86_64 architecture"
  exit 0
fi

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
  --android_abi arm64-v8a \
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
