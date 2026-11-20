#!/usr/bin/env bash
# The shared detector parity comparator and the three-process run consumers call from their Windows GPU lanes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
"${PREFLIGHT_PYTHON:-python3}" -I "${root}/shared/python/tests/test_compare_detector_parity.py"
"${PREFLIGHT_PYTHON:-python3}" -I "${root}/shared/python/tests/test_check_detector_parity.py"
