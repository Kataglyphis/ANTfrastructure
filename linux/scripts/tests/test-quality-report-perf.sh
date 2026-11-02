#!/usr/bin/env bash
# quality-report --perf-host's guards, baseline and grading on fixture checkouts; arguments select tests (-k Grading).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/quality_report_perf_tests.py" "$@"
