#!/usr/bin/env bash
# Tests the provider's direct host imports; it cannot prove GPU execution or dynamic assets.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=linux/scripts/06-packaging/ort-runtime-bundle.sh
source "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh"
for tool in cc patchelf readelf; do t_skip_unless "${tool}" command -v "${tool}"; done
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'int answer(void) { return 42; }\n' > "${work}/provider.c"
cc -shared -fPIC -o "${work}/provider.so" "${work}/provider.c"

t_case 'CUDA and MIGraphX return only their exact host SONAMEs'
cp "${work}/provider.so" "${work}/cuda.so"
patchelf --add-needed libcuda.so.1 --add-needed libcudart.so.13 --add-needed libcublas.so.13 "${work}/cuda.so"
out="$(ort_host_runtime_needed "${work}/cuda.so" cuda)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" 'libcuda.so.1'
t_assert_contains "${out}" 'libcudart.so.13'
t_assert_contains "${out}" 'libcublas.so.13'
cp "${work}/provider.so" "${work}/amd.so"
patchelf --add-needed libmigraphx_c.so.3 --add-needed libamdhip64.so.7 "${work}/amd.so"
out="$(ort_host_runtime_needed "${work}/amd.so" migraphx)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" 'libmigraphx_c.so.3'
t_assert_contains "${out}" 'libamdhip64.so.7'

t_case 'TensorRT returns only its exact optional CUDA and TensorRT imports'
cp "${work}/provider.so" "${work}/tensorrt.so"
patchelf --add-needed libnvinfer.so.11 --add-needed libnvonnxparser.so.11 --add-needed libcudnn.so.9 --add-needed libcublas.so.13 "${work}/tensorrt.so"
out="$(ort_host_runtime_needed "${work}/tensorrt.so" tensorrt)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" 'libnvinfer.so.11'
t_assert_contains "${out}" 'libnvonnxparser.so.11'
t_assert_contains "${out}" 'libcudnn.so.9'
t_assert_contains "${out}" 'libcublas.so.13'

t_case 'unknown imports, wrong providers and malformed files fail'
patchelf --add-needed libunreviewed.so.1 "${work}/cuda.so"
t_assert_fails ort_host_runtime_needed "${work}/cuda.so" cuda
t_assert_fails ort_host_runtime_needed "${work}/amd.so" cuda
t_assert_fails ort_host_runtime_needed "${work}/provider.so" migraphx
t_assert_fails ort_host_runtime_needed "${work}/provider.so" invalid
cp "${work}/provider.so" "${work}/incomplete-tensorrt.so"
patchelf --add-needed libnvinfer.so.11 --add-needed libcudnn.so.9 "${work}/incomplete-tensorrt.so"
t_assert_fails ort_host_runtime_needed "${work}/incomplete-tensorrt.so" tensorrt
cp "${work}/tensorrt.so" "${work}/unknown-tensorrt.so"
patchelf --add-needed libunknown-sdk.so.1 "${work}/unknown-tensorrt.so"
t_assert_fails ort_host_runtime_needed "${work}/unknown-tensorrt.so" tensorrt
cp "${work}/tensorrt.so" "${work}/unreviewed-cudnn.so"
patchelf --add-needed libcudnn_extra.so.9 "${work}/unreviewed-cudnn.so"
t_assert_fails ort_host_runtime_needed "${work}/unreviewed-cudnn.so" tensorrt
# shellcheck disable=SC2329
readelf() { command readelf "$@" | sed '$d'; }
t_assert_fails ort_host_runtime_needed "${work}/tensorrt.so" tensorrt
unset -f readelf
cp "${work}/provider.so" "${work}/glob.so"
patchelf --add-needed 'libcuda.so.*' "${work}/glob.so"
t_assert_fails ort_host_runtime_needed "${work}/glob.so" cuda
printf 'not ELF\n' > "${work}/invalid.so"
t_assert_fails ort_host_runtime_needed "${work}/invalid.so" cuda

t_case 'a host-runtime bundle rejects accidentally copied vendor libraries'
mkdir -p "${work}/bundle/lib"
printf 'GPU provider\n' > "${work}/bundle/lib/libonnxruntime_providers_migraphx.so"
t_assert_ok ort_assert_no_bundled_host_runtime "${work}/bundle" migraphx
printf 'host SDK\n' > "${work}/bundle/lib/libhsa-runtime64.so.1"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" migraphx
rm "${work}/bundle/lib/libhsa-runtime64.so.1"
ln -s /unavailable "${work}/bundle/lib/libcublas.so.13"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" cuda
rm "${work}/bundle/lib/libcublas.so.13"
printf 'host TensorRT SDK\n' > "${work}/bundle/lib/libnvinfer.so.11"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" cuda
rm "${work}/bundle/lib/libnvinfer.so.11"
printf 'host TensorRT parser\n' > "${work}/bundle/lib/libnvonnxparser.so.11"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" cuda
ln -s "${work}/bundle" "${work}/bundle-link"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle-link" cuda
rm "${work}/bundle/lib/libnvonnxparser.so.11"
# shellcheck disable=SC2329
find() { return 42; }
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" cuda
# shellcheck disable=SC2329
find() { return 0; }
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" cuda
unset -f find
t_assert_ok ort_assert_no_bundled_host_runtime "${work}/bundle" cuda

t_case 'Python GPU requirements come from one exact wheel and distinguish optional TensorRT'
site="${work}/python-capi"
wheels="${work}/wheels"
mkdir -p "${site}" "${wheels}"
cp "${work}/provider.so" "${site}/libonnxruntime.so.1.31.0"
cp "${work}/provider.so" "${site}/libonnxruntime_providers_shared.so"
cp "${work}/provider.so" "${site}/libonnxruntime_providers_cuda.so"
patchelf --add-needed libcudart.so.13 --add-needed libcublas.so.13 "${site}/libonnxruntime_providers_cuda.so"
cp "${work}/tensorrt.so" "${site}/libonnxruntime_providers_tensorrt.so"
write_wheel() {
  python3 - "${wheels}/onnxruntime_gpu-1.31.0-py3-none-any.whl" "${site}" <<'PY'
import sys
import zipfile
from pathlib import Path

with zipfile.ZipFile(sys.argv[1], 'w') as wheel:
    for library in sorted(Path(sys.argv[2]).glob('libonnxruntime*.so*')):
        wheel.write(library, f'onnxruntime/capi/{library.name}')
    wheel.writestr('onnxruntime/LICENSE', 'license')
    wheel.writestr('onnxruntime/ThirdPartyNotices.txt', 'notices')
PY
}
write_wheel
out="$(ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof")"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" $'required\tlibcudart.so.13'
t_assert_contains "${out}" $'required\tlibcublas.so.13'
t_assert_contains "${out}" $'optional\tlibcudnn.so.9'
t_assert_contains "${out}" $'optional\tlibnvinfer.so.11'
t_assert_contains "${out}" $'optional\tlibnvonnxparser.so.11'
overlap="$(printf '%s\n' "${out}" | grep -xF $'optional\tlibcublas.so.13' || true)"
t_assert_eq '' "${overlap}" 'required CUDA dependency must not be repeated as optional'
patchelf --add-needed libunknown-sdk.so.1 "${site}/libonnxruntime_providers_tensorrt.so"
t_assert_fails ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof"
write_wheel
t_assert_fails ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof"
rm "${site}/libonnxruntime_providers_tensorrt.so"
write_wheel
out="$(ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof")"; rc=$?
t_assert_eq 0 "${rc}"
optional="$(printf '%s\n' "${out}" | grep '^optional' || true)"
t_assert_eq '' "${optional}" 'CUDA-only wheel must not add optional dependencies'
t_summary
