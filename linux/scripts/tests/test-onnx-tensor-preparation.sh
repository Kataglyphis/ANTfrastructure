#!/usr/bin/env bash
# Schema doubles prove planning and refusal accounting, not real ONNX parsing or model execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_python_fixture_suite "${TESTS_DIR}/../../../shared/python/prepare_onnx_tensor_replay.py" "${TESTS_DIR}/onnx_tensor_preparation_tests.py"
t_summary
