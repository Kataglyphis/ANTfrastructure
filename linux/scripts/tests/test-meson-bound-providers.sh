#!/usr/bin/env bash
# Source-phase alias controls retain provider overrides without running Meson or a build.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/meson_bound_provider_tests.py" "${1:-${TESTS_DIR}/..}"
