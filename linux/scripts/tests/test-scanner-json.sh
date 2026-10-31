#!/usr/bin/env bash
# The four scanners' --json totals equal their text verdicts; arguments select test classes (-k SizeJson).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/scanner_json_tests.py" "$@"
