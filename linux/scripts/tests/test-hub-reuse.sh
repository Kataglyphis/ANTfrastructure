#!/usr/bin/env bash
# A copied function must fail while a verified shared bootstrap remains exempt.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/hub_reuse_tests.py"
