#!/usr/bin/env bash
# Temporary filesystem payloads check copy inventory and advisory smoke coverage; GPU payloads and real image contents are outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COPY="${1:-${TESTS_DIR}/../06-packaging/copy-media-payloads.sh}"
VALIDATOR="${2:-${TESTS_DIR}/../06-packaging/validate-compilers.sh}"
INVENTORY="${3:-${TESTS_DIR}/../06-packaging/media-payloads.sh}"
# shellcheck source=../06-packaging/media-payloads.sh
source "${INVENTORY}"
t_source_functions "${COPY}" _dest copy_path copy_media_payloads || exit 1
t_source_functions "${VALIDATOR}" _smoke_optional_payloads || exit 1
WORK="$(mktemp -d '/tmp/ant-payload fixture.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
expected=(/usr/local/lib/onnxruntime-genai /usr/local/lib/onnxruntime-gpu /usr/local/include/tflite /usr/local/include/absl
  /usr/local/include/tensorflow /usr/local/include/flatbuffers /usr/local/include/c /usr/local/lib/pkgconfig/litert.pc
  /usr/local/lib/pkgconfig/tensorflow-lite.pc /usr/local/lib/pkgconfig/tensorflowlite_c.pc /usr/local/lib/pkgconfig/libvvdec.pc
  /usr/local/lib/litert-web /usr/local/lib/litert-lm-web /usr/local/lib/onnxruntime-web)
observed=(/usr/local/lib/onnxruntime-genai /usr/local/lib/onnxruntime-gpu /usr/local/include/tflite /usr/local/include/tensorflow /usr/local/lib/pkgconfig/litert.pc)
copy_glob() { :; }
copy_cuda_payload() { printf 'CUDA\n' >> "${WORK}/order"; }
copy_tensorrt_payload() { printf 'TENSORRT\n' >> "${WORK}/order"; }
copy_rocm_payload() { printf 'ROCM\n' >> "${WORK}/order"; }
copy_deepstream_payload() { printf 'DEEPSTREAM\n' >> "${WORK}/order"; }
warn() { printf 'WARN:%s\n' "$*"; }
for prefix in first second; do
  t_case "${prefix}: source and destination are selected at copy time with spaces preserved"
  export SRCPREFIX="${WORK}/${prefix} source"
  destination="${WORK}/${prefix} destination"
  for path in "${expected[@]}"; do
    case "${path}" in
      *.pc) mkdir -p "${SRCPREFIX}${path%/*}"; printf '%s' "${prefix}:${path}" > "${SRCPREFIX}${path}" ;;
      *) mkdir -p "${SRCPREFIX}${path}"; printf '%s' "${prefix}:${path}" > "${SRCPREFIX}${path}/marker" ;;
    esac
  done
  mkdir -p "${destination}/usr/local/include/tflite"
  : > "${WORK}/order"
  copy_media_payloads "${destination}"
  for path in "${expected[@]}"; do
    actual="${destination}${path}"; case "${path}" in *.pc) ;; *) actual+=/marker ;; esac
    t_assert_eq "${prefix}:${path}" "$(cat "${actual}")"
  done
  t_assert_eq $'CUDA\nTENSORRT\nROCM\nDEEPSTREAM' "$(cat "${WORK}/order")" 'accelerator copying follows media paths in its original order'
  t_assert_eq unset "${COPY_TARGET_DIR-unset}"
done
t_case 'the inventory preserves all fourteen copy paths in order'
t_assert_eq "$(printf '%s\n' "${expected[@]}")" "$(media_optional_payloads | cut -d'|' -f1)"
t_case 'missing optional payloads warn without preventing later copies'
rm -rf "${SRCPREFIX}/usr/local/include/absl"
output="$(copy_media_payloads "${WORK}/missing destination")"; status=$?
t_assert_eq 0 "${status}"
t_assert_contains "${output}" "optional payload missing: ${SRCPREFIX}/usr/local/include/absl"
t_assert_ok test -f "${WORK}/missing destination/usr/local/lib/onnxruntime-web/marker"
function [ {
  if builtin [ "${1:-}" = -e ]; then builtin [ -e "${WORK}/smoke$2" ]; else builtin [ "$@"; fi
}
for mode in present absent; do
  t_case "${mode}: exactly the original five optional payloads are observed in order"
  rm -rf "${WORK}/smoke"
  if builtin [ "${mode}" = present ]; then
    for path in "${observed[@]}"; do mkdir -p "${WORK}/smoke${path}"; done
  fi
  output="$(_smoke_optional_payloads)"; status=$?
  expected_output=''
  for path in "${observed[@]}"; do
    prefix='SMOKE OK: payload'
    if builtin [ "${mode}" = absent ]; then prefix='SMOKE NOTE: optional payload missing:'; fi
    expected_output+="${prefix} ${path}"$'\n'
  done
  t_assert_eq "${expected_output%$'\n'}" "${output}"
  t_assert_eq 0 "${status}" 'missing optional payloads never add a compiler failure'
done
unset -f '['
t_case 'every isolated package entry point carries its inventory companion'
t_assert_ok python3 - "${TESTS_DIR}/../../Dockerfile.package" <<'PY_CLOSURE'
from pathlib import Path
import shlex, sys
text = Path(sys.argv[1]).read_text().replace(chr(92) + chr(10), ' ')
copies = [shlex.split(line) for line in text.splitlines() if line.startswith('COPY ')]
for source, destination in [('copy-media-payloads.sh', '/tmp/'), ('validate-compilers.sh', '/opt/scripts/packaging/')]:
    companions = {'linux/scripts/06-packaging/' + source, 'linux/scripts/06-packaging/media-payloads.sh'}
    if source == 'copy-media-payloads.sh':
        companions.add('linux/scripts/lib/log-bootstrap.sh')
    assert any(row[-1] == destination and companions <= set(row) for row in copies), source
assert any('target=/tmp/validate-compilers.sh' in line and 'target=/tmp/media-payloads.sh' in line for line in text.splitlines() if line.startswith('RUN ')), 'artifact-source validator bind mount'
PY_CLOSURE
t_summary
