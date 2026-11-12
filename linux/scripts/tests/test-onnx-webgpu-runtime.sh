#!/usr/bin/env bash
# Stub bindings prove runtime verdicts and byte/phase checks, not real ORT factories, native-core registration or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
fixture="$(t_mktemp)"
t_fake_elf "${fixture}" 62
common="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
suite=ort_webgpu_runtime_tests.py
if [ "${1:-}" = --media ]; then suite=ort_webgpu_media_tests.py; shift; fi
output='' status=0
t_capture_command output status python3 "${TESTS_DIR}/${suite}" \
  "${common%/*}/ort-webgpu-build-proof.py" "${fixture}" "${common}" \
  "${1:-${TESTS_DIR}/../03-media/runtime/ort_webgpu_runtime.py}"
printf '%s\n' "${output}"
t_assert_eq 0 "${status}" 'runtime bindings and negative controls must all pass'
t_summary
