#!/usr/bin/env bash
set -euo pipefail

# Points /opt/python-target at the target arch's Python so Meson (gst-python) links the target libpython.

if [ "${BUILD_MODE:-native}" != "cross" ] || [ "${TARGET_ARCH:-amd64}" = "amd64" ]; then
  exit 0
fi

python_cross_stage="/opt/python-cross/${TARGET_ARCH}"
if [ -d "${python_cross_stage}/usr/local" ]; then
  rm -rf /opt/python-target
  ln -sfn "${python_cross_stage}" /opt/python-target
  echo "Activated cross Python staging: /opt/python-target -> ${python_cross_stage}"
fi
