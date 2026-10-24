#!/usr/bin/env bash
# Offline receipts preserve selected capture scopes and publication without building Rust or invoking a compiler.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/target_cargo_pipeline_tests.py" "${1:-${TESTS_DIR}/..}"
