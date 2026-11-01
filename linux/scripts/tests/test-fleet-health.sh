#!/usr/bin/env bash
# fleet-health.py over local Git fixtures and recorded GitHub answers; not covered: live GitHub, --clone, real quality-report runs.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/fleet_health_tests.py"
