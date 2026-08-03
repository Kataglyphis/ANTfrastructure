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

ORT_VERSION="${1:-${ONNXRUNTIME_VERSION:-v1.28.0}}"
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
# The headers always exist in the source tree — a failed copy here is a real
# error, not an optional step.
cp -r include/* "${INSTALL_DIR}/include/"
# The build tree contains MULTIPLE copies of each .so/.aar (top level, java
# build dirs, native-libs). A single `xargs cp -t` fails on the duplicate
# basenames ("will not overwrite just-created", exit 123) — historically masked
# by 2>/dev/null || true with first-copy-wins semantics. Keep that outcome
# explicitly: copy the first occurrence of each basename, skip the rest, and
# rely on the verification below for the real guarantee.
while IFS= read -r -d '' _artifact; do
  _base="$(basename "${_artifact}")"
  [ -e "${INSTALL_DIR}/lib/${_base}" ] || cp "${_artifact}" "${INSTALL_DIR}/lib/"
done < <(find build/Android/Release -name "libonnxruntime*.so" -print0)
while IFS= read -r -d '' _artifact; do
  _base="$(basename "${_artifact}")"
  [ -e "${INSTALL_DIR}/java/${_base}" ] || cp "${_artifact}" "${INSTALL_DIR}/java/"
done < <(find build/Android/Release -name "*.aar" -print0)

# Verify the install actually landed before deleting the build tree — these
# copies failing silently used to produce an "installed" stage with no library.
ls "${INSTALL_DIR}/lib/"libonnxruntime*.so >/dev/null 2>&1 \
  || { echo "ERROR: no libonnxruntime*.so under ${INSTALL_DIR}/lib after build (--build_shared_lib output missing)" >&2; exit 1; }
ls "${INSTALL_DIR}/java/"*.aar >/dev/null 2>&1 \
  || { echo "ERROR: no .aar under ${INSTALL_DIR}/java after build (--build_java output missing)" >&2; exit 1; }

cd /opt
rm -rf onnxruntime-android
