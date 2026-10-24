#!/usr/bin/env bash
# Provider failures, array changes and cross-file callbacks run offline without invoking Meson or a compiler.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/meson_dispatch_tests.py" \
  "${1:-${TESTS_DIR}/../01-core/common.sh}" \
  "${2:-${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh}" \
  "${3:-${TESTS_DIR}/../03-media/build/libcamera/build-libcamera.sh}"
