#!/usr/bin/env bash
set -euo pipefail

# Wrapper for build-libcamera.sh that ensures TensorFlow Lite headers are
# available under /usr/local/include/tensorflow -> /usr/local/include/tflite
# so includes like <tensorflow/lite/interpreter.h> resolve correctly.

if [ -d /usr/local/include/tflite ] && [ ! -e /usr/local/include/tensorflow ]; then
  echo "Creating compat symlink /usr/local/include/tensorflow -> /usr/local/include/tflite"
  ln -s /usr/local/include/tflite /usr/local/include/tensorflow || true
fi

echo "--- Debug: /usr/local/include contents ---"
ls -la /usr/local/include || true
echo "--- Debug: /usr/local/include/tflite contents (first 200 lines) ---"
ls -la /usr/local/include/tflite 2>/dev/null || true
echo "--- Debug: check interpreter.h existence ---"
if [ -f /usr/local/include/tensorflow/lite/interpreter.h ]; then
  echo "OK: /usr/local/include/tensorflow/lite/interpreter.h present"
else
  echo "MISSING: /usr/local/include/tensorflow/lite/interpreter.h"
fi

exec bash /opt/scripts/media/libcamera/build-libcamera.sh "$@"
