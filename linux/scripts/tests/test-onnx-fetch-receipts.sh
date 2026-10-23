#!/usr/bin/env bash
# Frozen fetch receipts cover argv, ordering and failures through fake tools, not network or package operations.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "ORT and GenAI fetch preserve all twelve offline command receipts"
t_assert_ok python3 "${TESTS_DIR}/onnx_fetch_receipt_tests.py" "${1:-${TESTS_DIR}/../03-media/build/onnxruntime/build/20-fetch.sh}"
t_summary
