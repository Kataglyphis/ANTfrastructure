#!/usr/bin/env bash
# Actual wheel caller failure and cleanup paths use offline tools, without installing wheel or stripping real libraries.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/wheel_archive_transport_tests.py" \
  "${1:-${TESTS_DIR}/../03-media/build/litert/litert-wheel.sh}" \
  "${2:-${TESTS_DIR}/../03-media/runtime/repair-wheels.sh}" \
  "${3:-${TESTS_DIR}/../01-core/common.sh}"
