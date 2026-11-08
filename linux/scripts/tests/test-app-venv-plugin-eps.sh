#!/usr/bin/env bash
# Real fixture DSOs and stub Python packages exercise build-only plugin checks, not ORT registration or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "a native ELF C compiler" command -v cc
t_skip_unless "an ELF host compiler" t_is_elf "$(command -v cc)"
SUBJECT="${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh"
_T="$(t_mktemp -d)" || exit 1
FIXTURE_PYTHON="$(command -v "${PREFLIGHT_PYTHON:-python3}")" || exit 1
export FIXTURE_PYTHON
export PYTHONPATH="${_T}/modules"
export ORT_AMDGPU_EP_ROOT="${_T}/plugin root"
export ORT_TENSORRT_EP_ROOT="${ORT_AMDGPU_EP_ROOT}"
mkdir -p "${PYTHONPATH}" "${ORT_AMDGPU_EP_ROOT}/lib" || exit 1

cat > "${_T}/plugin.c" <<'C'
#ifndef OMIT_CREATE
void CreateEpFactories(void) {}
#endif
#ifndef OMIT_RELEASE
void ReleaseEpFactory(void) {}
#endif
C
cc -shared -fPIC "${_T}/plugin.c" -o "${ORT_AMDGPU_EP_ROOT}/lib/libmigraphx-ep.so" || exit 1
cc -shared -fPIC -DOMIT_RELEASE "${_T}/plugin.c" -o "${ORT_AMDGPU_EP_ROOT}/lib/no-release.so" || exit 1
cc -shared -fPIC -DOMIT_CREATE "${_T}/plugin.c" -o "${ORT_AMDGPU_EP_ROOT}/lib/no-create.so" || exit 1
cp "${ORT_AMDGPU_EP_ROOT}/lib/libmigraphx-ep.so" "${ORT_AMDGPU_EP_ROOT}/lib/libonnxruntime_ep_tensorrt.so" || exit 1
printf 'not a shared library\n' > "${ORT_AMDGPU_EP_ROOT}/lib/invalid.so"
for module in gi numpy contourpy cv2; do
  printf '__version__ = "fixture"\n' > "${PYTHONPATH}/${module}.py"
done
cat > "${PYTHONPATH}/torch.py" <<'PY'
import os
from types import SimpleNamespace
version = SimpleNamespace(hip=None if os.environ.get("CPU_TORCH") else "10.1", cuda="13.4")
PY
cat > "${PYTHONPATH}/onnxruntime.py" <<'PY'
import os
def get_available_providers():
    return ([] if os.environ.get("NO_CPU_ORT") else ["CPUExecutionProvider"]) + ["CUDAExecutionProvider"]
PY

cat > "${_T}/runner.sh" <<'SH'
uv() {
  if [ "$1" = pip ]; then return 0; fi
  shift 3
  [ "$1" = python ] || return 2
  shift
  "${FIXTURE_PYTHON}" "$@"
}
activate_project_environment() { :; }
staged_opencv_python_available() { return 1; }
find() { :; }
rm() { :; }
SH
for function in verify_ort_plugin_library verify_project_environment; do
  t_fn_src "${SUBJECT}" "${function}" >> "${_T}/runner.sh" || exit 1
done
cat >> "${_T}/runner.sh" <<'SH'
mode=$1
shift
if [ "${mode}" = probe ]; then verify_ort_plugin_library "$@"; else verify_project_environment; fi
SH

_probe() { bash -e "${_T}/runner.sh" probe ORT_AMDGPU_EP_ROOT "$1"; }
_verify() { env ENABLE_AMD="$1" ENABLE_NVIDIA="$2" ENABLE_TENSORRT="$3" bash -e "${_T}/runner.sh" verify; }

t_case "native loading and both factory exports pass without GPU enumeration"
t_assert_contains "$(t_out _probe libmigraphx-ep.so)" 'ORT-PLUGIN PASS libmigraphx-ep.so'
t_assert_contains "$(t_out _probe libmigraphx-ep.so)" 'registration/inference not tested'
t_assert_ok _probe libonnxruntime_ep_tensorrt.so

t_case "a missing or invalid module and a missing factory export fail"
t_assert_fails _probe missing.so
t_assert_fails _probe invalid.so
t_assert_fails _probe no-release.so
t_assert_contains "$(t_out _probe no-release.so)" 'ReleaseEpFactory'
t_assert_fails _probe no-create.so
t_assert_contains "$(t_out _probe no-create.so)" 'CreateEpFactories'

t_case "unset, empty and relative plugin roots fail"
t_assert_fails env -u ORT_AMDGPU_EP_ROOT bash -e "${_T}/runner.sh" probe ORT_AMDGPU_EP_ROOT libmigraphx-ep.so
t_assert_fails env ORT_AMDGPU_EP_ROOT= bash -e "${_T}/runner.sh" probe ORT_AMDGPU_EP_ROOT libmigraphx-ep.so
t_assert_fails env ORT_AMDGPU_EP_ROOT=relative bash -e "${_T}/runner.sh" probe ORT_AMDGPU_EP_ROOT libmigraphx-ep.so

t_case "CPU builds need no plugin, AMD accepts CPU ORT, NVIDIA needs no in-tree TensorRT provider"
t_assert_ok env -u ORT_AMDGPU_EP_ROOT -u ORT_TENSORRT_EP_ROOT bash -e "${_T}/runner.sh" verify
t_assert_ok _verify true false false
t_assert_ok _verify false true true
t_assert_ok env -u ORT_TENSORRT_EP_ROOT ENABLE_NVIDIA=true ENABLE_TENSORRT=false bash -e "${_T}/runner.sh" verify

t_case "each selected plugin is required, and CPU torch cannot satisfy the ROCm build check"
t_assert_fails env ORT_AMDGPU_EP_ROOT="${_T}/missing" ENABLE_AMD=true bash -e "${_T}/runner.sh" verify
t_assert_fails env ORT_TENSORRT_EP_ROOT="${_T}/missing" ENABLE_NVIDIA=true ENABLE_TENSORRT=true bash -e "${_T}/runner.sh" verify
t_assert_fails env CPU_TORCH=1 ENABLE_AMD=true bash -e "${_T}/runner.sh" verify
t_assert_fails env NO_CPU_ORT=1 ENABLE_AMD=true bash -e "${_T}/runner.sh" verify

t_summary
