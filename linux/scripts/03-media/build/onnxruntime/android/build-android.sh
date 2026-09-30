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

# No default version: a dropped build-arg must fail loudly, not build a stale release.
ORT_VERSION="${1:-${ONNXRUNTIME_VERSION:?ONNXRUNTIME_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${ONNXRUNTIME_ROOT_ANDROID:-/opt/android/onnxruntime}"

apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 python3-pip openjdk-21-jdk curl

PARALLEL_JOBS="$(media_jobs)"

android_clone_shallow "https://github.com/microsoft/onnxruntime.git" "${ORT_VERSION}" onnxruntime-android

# Patch Android Gradle Plugin 7.4.2 -> 8.3.1 (JDK 21) and re-enable buildConfig
android_apply_patch \
  "onnxruntime/001-android-gradle-agp8-compat.patch" \
  "$(pwd)" \
  "ONNX Runtime Android Gradle AGP 8 compat"

: "${ANDROID_HOME:?ANDROID_HOME must be set}"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

# --no_telemetry keeps Microsoft's 1DS SDK out; a comment between the `\` lines would cut the arguments off.
./build.sh \
  --no_telemetry \
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
cp -r include/* "${INSTALL_DIR}/include/"
# The build tree holds several copies of each .so/.aar, so keep the first of each basename.
while IFS= read -r -d '' _artifact; do
  _base="$(basename "${_artifact}")"
  [ -e "${INSTALL_DIR}/lib/${_base}" ] || cp "${_artifact}" "${INSTALL_DIR}/lib/"
done < <(find build/Android/Release -name "libonnxruntime*.so" -print0)
while IFS= read -r -d '' _artifact; do
  _base="$(basename "${_artifact}")"
  [ -e "${INSTALL_DIR}/java/${_base}" ] || cp "${_artifact}" "${INSTALL_DIR}/java/"
done < <(find build/Android/Release -name "*.aar" -print0)

# The copy loops succeed on zero matches, so prove the install landed before the tree goes.
ls "${INSTALL_DIR}/lib/"libonnxruntime*.so >/dev/null 2>&1 \
  || { echo "ERROR: no libonnxruntime*.so under ${INSTALL_DIR}/lib after build (--build_shared_lib output missing)" >&2; exit 1; }
ls "${INSTALL_DIR}/java/"*.aar >/dev/null 2>&1 \
  || { echo "ERROR: no .aar under ${INSTALL_DIR}/java after build (--build_java output missing)" >&2; exit 1; }

cd /opt
rm -rf onnxruntime-android
