#!/usr/bin/env bash
# Real ELF rewrites prove code/data continuity, not ONNX Runtime registration, GPU inference or loader metadata safety.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
for tool in cc strip objcopy patchelf; do t_skip_unless "${tool}" command -v "${tool}"; done
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '%s\n' 'extern int puts(const char *); const char banner[]="webgpu fixture"; int value=7; int answer(void) { puts(banner); return value + 42; }' > "${work}/fixture.c"
cc -shared -fPIC -g -Wl,--build-id=sha1 -Wl,-rpath,/fixture/original -o "${work}/fixture.so" "${work}/fixture.c" || exit $?
common="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
t_case 'actual strip/patchelf delivery with retained native/GIL/FT product bindings'
status=0
python3 "${TESTS_DIR}/ort_webgpu_delivery_tests.py" "${common%/*}/ort-webgpu-build-proof.py" "${work}/fixture.so" "${common}" \
  "${1:-${TESTS_DIR}/../03-media/runtime/ort_webgpu_delivery.py}" > "${work}/delivery.log" 2>&1 || status=$?
cat "${work}/delivery.log"
t_assert_eq 0 "${status}" 'the complete delivery fixture must pass'
t_summary
