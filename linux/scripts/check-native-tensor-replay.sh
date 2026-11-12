#!/usr/bin/env bash
# Real SDK controls cover CPU inference and refusal paths; a missing plugin test is not GPU acceptance.
set -euo pipefail
shopt -s nullglob
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/cli-value-options.sh"
cli_require_positionals 'BUILT_DIRECTORY CORE RELU_MODEL' 3 3 "$@"
build="$1" core="$2" model="$3"
hub="$(cd "${scripts}/../.." && pwd)"
source "${scripts}/01-core/python-probe.sh"
ci_image_python_require native-tensor-sdk-controls docs/gpu-artifact-receipts.md /usr/local/bin/python3
source "${scripts}/tests/test-harness.sh"
work="${build}/sdk-controls"
mkdir "${work}"
binary="${build}/ort-tensor-replay"
"${PREFLIGHT_PYTHON}" -I - "${work}" <<'PY'
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
(root / 'input.f32le').write_bytes(struct.pack('<f', -1.0))
(root / 'short.f32le').write_bytes(b'x')
PY
"${binary}" "${core}" "${model}" 1 "${work}/input.f32le" cpu "${work}/cpu" > "${work}/cpu.log" 2>&1
"${PREFLIGHT_PYTHON}" -I - "${work}/cpu/tensors" <<'PY'
import json
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
for run in (1, 2):
    data = json.loads((root / f'run-{run}.json').read_text())
    if data['run'] != run or data['output']['shape'] != [1]:
        raise SystemExit('Unexpected real Relu output shape/run')
    if struct.unpack('<f', (root / f'run-{run}-output.f32le').read_bytes()) != (0.0,):
        raise SystemExit('Wrong real Relu result')
PY
profile=("${work}"/cpu/profile*.json)
t_assert_eq 1 "${#profile[@]}" 'one completed CPU profile is required'
"${PREFLIGHT_PYTHON}" -I "${hub}/shared/python/verify_ort_profile.py" "${profile[0]}" --device cpu --min-runs 2
_sdk_refusal() {
  local name="$1" marker="$2" report='' raw=125
  shift 2
  t_capture_command report raw "$@"
  printf '%s\n' "${report}" > "${work}/${name}.log"
  t_assert_eq 1 "${raw}" "${name} must fail"
  t_assert_contains "${report}" "${marker}"
}
_sdk_refusal existing 'Output already exists' "${binary}" "${core}" "${model}" 1 "${work}/input.f32le" cpu "${work}/cpu"
_sdk_refusal device 'Unknown replay device' "${binary}" "${core}" "${model}" 1 "${work}/input.f32le" cuda "${work}/bad-device"
_sdk_refusal bytes 'exact regular float32 payload' "${binary}" "${core}" "${model}" 1 "${work}/short.f32le" cpu "${work}/bad-input"
_sdk_refusal nonort 'Core lacks OrtGetApiBase' "${binary}" libc.so.6 "${model}" 1 "${work}/input.f32le" cpu "${work}/bad-core"
_sdk_refusal plugin 'is not a directory' env ORT_AMDGPU_EP_ROOT="${work}/absent-plugin" "${binary}" "${core}" "${model}" 1 "${work}/input.f32le" migraphx "${work}/bad-plugin"
t_summary
