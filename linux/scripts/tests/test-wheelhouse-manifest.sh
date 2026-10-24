#!/usr/bin/env bash
# Byte receipts exercise isolated wheelhouse manifests and imports, not wheel validity or image builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "wheelhouse manifest bytes, failure contexts and copied closures"
t_assert_ok python3 "${TESTS_DIR}/wheelhouse_manifest_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
