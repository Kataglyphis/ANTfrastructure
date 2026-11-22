#!/usr/bin/env bash
# Synthetic caches and minimal modules prove refusal/accounting, not compilation, loader behavior or EP registration.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_python_fixture_suite "${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/ort-webgpu-wasm-proof.py" "${TESTS_DIR}/ort_webgpu_wasm_tests.py"
t_summary
