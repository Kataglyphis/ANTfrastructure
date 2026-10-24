#!/usr/bin/env bash
# Offline typed-state receipts expose handler failures without starting builds or engines.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/log_dir_consumer_tests.py" "${1:-${TESTS_DIR}/..}"
