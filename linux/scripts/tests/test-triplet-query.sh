#!/usr/bin/env bash
# Mapping, linker path and API failure policies use offline fixtures without changing host libraries.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/triplet_query_tests.py" \
  "${1:-${TESTS_DIR}/../01-core/platform.sh}" \
  "${2:-${TESTS_DIR}/../01-core/compiler-resolution.sh}" \
  "${3:-${TESTS_DIR}/../03-media/build/gstreamer/common/build-gst-plugins-rs.sh}"
