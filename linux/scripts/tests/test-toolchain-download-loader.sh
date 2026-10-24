#!/usr/bin/env bash
# Real downloads declarations and actual loader sections cover source scope and closures without SDK installs or network access.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/toolchain_download_loader_tests.py" \
  "${1:-${TESTS_DIR}/../02-toolchain}" "${2:-${TESTS_DIR}/../01-core/downloads.sh}"
