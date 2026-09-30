#!/usr/bin/env bash
# Maps ANDROID_LIB to its build script so every Dockerfile.android stage's RUN stays identical.
set -euo pipefail

LIB="${1:?usage: android-dispatch.sh <gstreamer|onnxruntime|litert|opencv|iree>}"

case "${LIB}" in
  gstreamer)   SCRIPT=/opt/scripts/03-media/gstreamer/android/build-gstreamer.sh ;;
  onnxruntime) SCRIPT=/opt/scripts/03-media/onnxruntime/android/build-android.sh ;;
  litert)      SCRIPT=/opt/scripts/03-media/litert/android/build-android.sh ;;
  opencv)      SCRIPT=/opt/scripts/03-media/opencv/android/build-android.sh ;;
  iree)        SCRIPT=/opt/scripts/03-media/iree/android/build-android.sh ;;
  *)
    echo "android-dispatch.sh: unknown Android library '${LIB}' (expected gstreamer|onnxruntime|litert|opencv|iree)" >&2
    exit 1
    ;;
esac

if [ ! -x "${SCRIPT}" ]; then
  echo "android-dispatch.sh: build script '${SCRIPT}' for library '${LIB}' is missing or not executable" >&2
  exit 1
fi

exec "${SCRIPT}"
