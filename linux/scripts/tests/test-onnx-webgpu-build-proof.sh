#!/usr/bin/env bash
# These byte/configuration fixtures do not build ORT, prove repaired-wheel delivery or exercise runtime factories.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
t_fake_elf "${work}/fixture.so" 62
common="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
t_case 'native, GIL and free-threaded build-mode receipts and fail-closed publication'
status=0
python3 "${TESTS_DIR}/ort_webgpu_build_proof_tests.py" "${1:-${common%/*}/ort-webgpu-build-proof.py}" "${work}/fixture.so" "${common}" \
  > "${work}/proof.log" 2>&1 || status=$?
cat "${work}/proof.log"
t_assert_eq 0 "${status}" 'the complete receipt fixture must pass'
t_summary
