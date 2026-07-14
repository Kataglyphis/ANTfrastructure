#!/usr/bin/env bash
# android-dispatch.sh — single entrypoint for the per-library Android build
# stages in linux/Dockerfile.android.
#
# Maps a library name (the per-stage ANDROID_LIB build arg) to that library's
# build script under the flattened container layout
# /opt/scripts/03-media/<lib>/android/, so the Dockerfile COPY/RUN
# instructions stay byte-identical across the android-gstreamer, android-onnx,
# android-litert and android-opencv stages.
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
