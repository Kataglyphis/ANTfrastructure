#!/usr/bin/env bash
set -euo pipefail

# Wrapper for build-libcamera.sh that ensures TensorFlow Lite headers are
# available under /usr/local/include/tensorflow -> /usr/local/include/tflite
# so includes like <tensorflow/lite/interpreter.h> resolve correctly.

if [ -d /usr/local/include/tflite ] && [ ! -e /usr/local/include/tensorflow ]; then
  echo "Creating compat symlink /usr/local/include/tensorflow -> /usr/local/include/tflite"
  ln -s /usr/local/include/tflite /usr/local/include/tensorflow || true
fi

exec bash /opt/scripts/media/libcamera/build-libcamera.sh "$@"
