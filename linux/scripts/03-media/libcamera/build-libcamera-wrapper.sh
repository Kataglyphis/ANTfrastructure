#!/usr/bin/env bash
set -euo pipefail

# Wrapper for build-libcamera.sh to ensure TensorFlow Lite headers
# are resolvable by libcamera's build system.

if [ -d /usr/local/include/tflite ]; then
  echo "Setting up TensorFlow Lite header symlinks..."
  
  # If tflite directory already has a 'lite' subdirectory inside it
  if [ -d /usr/local/include/tflite/lite ]; then
    # Then tflite is acting as the 'tensorflow' root directory
    ln -snf /usr/local/include/tflite /usr/local/include/tensorflow
  else
    # Otherwise, tflite IS the 'lite' directory. We must wrap it in a tensorflow/ dir
    mkdir -p /usr/local/include/tensorflow
    ln -snf /usr/local/include/tflite /usr/local/include/tensorflow/lite
  fi
fi

# Force compiler to look in /usr/local/include to bypass Meson/pkg-config stripping
export CXXFLAGS="${CXXFLAGS:-} -I/usr/local/include"
export CFLAGS="${CFLAGS:-} -I/usr/local/include"

# Ensure pkg-config checks our custom installation path first
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "--- Debug: check interpreter.h existence ---"
if [ -f /usr/local/include/tensorflow/lite/interpreter.h ]; then
  echo "OK: /usr/local/include/tensorflow/lite/interpreter.h is correctly mapped."
else
  echo "MISSING: /usr/local/include/tensorflow/lite/interpreter.h"
  echo "Contents of /usr/local/include:"
  ls -la /usr/local/include || true
fi

exec bash /opt/scripts/media/libcamera/build-libcamera.sh "$@"
