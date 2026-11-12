#!/usr/bin/env bash
# Synthetic raw tensors prove evidence accounting, not model correctness or GPU/package acceptance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_python_fixture_suite "${TESTS_DIR}/../../../shared/python/summarize_detector_tensors.py" "${TESTS_DIR}/detector_tensor_summary_tests.py"
t_summary
