#!/usr/bin/env bash
# Verify the wheel-proven provider set in each finished GPU package format.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless 'dpkg-deb' command -v dpkg-deb
t_case 'wheel-proven providers survive every finished package format'
t_assert_ok python3 "${TESTS_DIR}/test-python-gpu-package.py"
t_summary
