#!/usr/bin/env bash
# Real host C/Node transports with fake APIs/loaders test verdicts, not Emscripten, real ORT or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_private_tmpdir
t_python_fixture_suite "${1:-${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/ort-webgpu-wasm-runtime.py}" "${TESTS_DIR}/ort_webgpu_wasm_runtime_tests.py"
t_summary
