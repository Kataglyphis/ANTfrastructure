#!/usr/bin/env bash
# Frozen original graphs retain separate expected cycles and closure checks; no real repositories or network run.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/fleet_dependency_tests.py" "${1:-${TESTS_DIR}/../renovate-fleet.sh}"
