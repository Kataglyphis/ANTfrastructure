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

t_case 'the plugin MIGraphX EP links the bundled chain ORT, which is no host import'
cp "${work}/provider.so" "${work}/plugin.so"
patchelf --add-needed libonnxruntime.so.1 --add-needed libmigraphx_c.so.3 --add-needed libamdhip64.so.7 "${work}/plugin.so"
out="$(ort_host_runtime_needed "${work}/plugin.so" migraphx)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" 'libmigraphx_c.so.3'
t_assert_contains "${out}" 'libamdhip64.so.7'
t_assert_eq 2 "$(printf '%s\n' "${out}" | grep -c .)" "libonnxruntime.so.1 travels in the bundle and is not listed"
cp "${work}/provider.so" "${work}/plugin-cuda.so"
patchelf --add-needed libonnxruntime.so.1 --add-needed libcuda.so.1 "${work}/plugin-cuda.so"
t_assert_fails ort_host_runtime_needed "${work}/plugin-cuda.so" cuda "the CUDA plugin EP links no chain ORT by SONAME; an unexpected import fails closed"

t_case 'unknown imports, wrong providers and malformed files fail'
patchelf --add-needed libunreviewed.so.1 "${work}/cuda.so"
t_assert_fails ort_host_runtime_needed "${work}/cuda.so" cuda
t_assert_fails ort_host_runtime_needed "${work}/amd.so" cuda
t_assert_fails ort_host_runtime_needed "${work}/provider.so" migraphx
t_assert_fails ort_host_runtime_needed "${work}/provider.so" invalid
cp "${work}/provider.so" "${work}/zlib-cuda.so"
patchelf --add-needed libcuda.so.1 --add-needed libz.so.1 "${work}/zlib-cuda.so"
t_assert_fails ort_host_runtime_needed "${work}/zlib-cuda.so" cuda
t_assert_fails ort_host_runtime_needed "${work}/amd.so" tensorrt "TensorRT is no venv provider kind any more: its EP is the image's plugin"
# shellcheck disable=SC2329
readelf() { command readelf "$@" | sed '$d'; }
t_assert_fails ort_host_runtime_needed "${work}/amd.so" migraphx
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

t_case 'Python CUDA requirements come from one exact wheel: core, shared bridge and the CUDA plugin EP'
site="${work}/python-capi"
wheels="${work}/wheels"
mkdir -p "${site}" "${wheels}"
cp "${work}/provider.so" "${site}/libonnxruntime.so.1.31.0"
cp "${work}/provider.so" "${site}/libonnxruntime_providers_shared.so"
cp "${work}/provider.so" "${site}/libonnxruntime_providers_cuda.so"
patchelf --add-needed libcudart.so.13 --add-needed libcublas.so.13 "${site}/libonnxruntime_providers_cuda.so"
# write_wheel <wheel> <capi dir> [glob]: a wheel holding the capi libraries the glob selects and both notice texts.
write_wheel() {
  python3 - "$1" "$2" "${3:-libonnxruntime*.so*}" <<'PY'
import sys
import zipfile
from pathlib import Path

with zipfile.ZipFile(sys.argv[1], 'w') as wheel:
    for library in sorted(Path(sys.argv[2]).glob(sys.argv[3])):
        wheel.write(library, f'onnxruntime/capi/{library.name}')
    wheel.writestr('onnxruntime/LICENSE', 'license')
    wheel.writestr('onnxruntime/ThirdPartyNotices.txt', 'notices')
PY
}
# needed_lines <site> <kind> <proof> <soname>...: the host imports come back as exactly these required lines, in NEEDED order.
needed_lines() {
  local site="$1" kind="$2" proof="$3" soname out rc
  shift 3
  out="$(ort_python_host_runtime_needed "${site}" "${kind}" "${wheels}" "${proof}")"; rc=$?
  t_assert_eq 0 "${rc}"
  for soname in "$@"; do t_assert_contains "${out}" "$(printf 'required\t%s' "${soname}")"; done
  t_assert_eq "$#" "$(printf '%s\n' "${out}" | grep -c .)" "exactly the required lines for ${kind}"
}
write_wheel "${wheels}/onnxruntime_gpu-1.31.0-py3-none-any.whl" "${site}"
needed_lines "${site}" cuda "${work}/proof" libcudart.so.13 libcublas.so.13
patchelf --add-needed libunknown-sdk.so.1 "${site}/libonnxruntime_providers_cuda.so"
t_assert_fails ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof" 'an unreviewed import fails even though the wheel matches'
write_wheel "${wheels}/onnxruntime_gpu-1.31.0-py3-none-any.whl" "${site}"
t_assert_fails ort_python_host_runtime_needed "${site}" cuda "${wheels}" "${work}/proof"

t_case 'Python MIGraphX requirements come from the plugin module, which must be the image'"'"'s copy beside a wheel-proven core'
amdsite="${work}/python-amd-capi"
mkdir -p "${amdsite}" "${work}/ep root/lib"
cp "${work}/provider.so" "${amdsite}/libonnxruntime.so.1.31.0"
cp "${work}/provider.so" "${amdsite}/libmigraphx-ep.so"
patchelf --add-needed libonnxruntime.so.1 --add-needed libmigraphx_c.so.3 --add-needed libamdhip64.so.7 "${amdsite}/libmigraphx-ep.so"
write_wheel "${wheels}/onnxruntime-1.31.0-py3-none-any.whl" "${amdsite}" 'libonnxruntime.so.*'
rm -f "${wheels}/onnxruntime_gpu-1.31.0-py3-none-any.whl"
t_assert_fails ort_python_host_runtime_needed "${amdsite}" migraphx "${wheels}" "${work}/proof-amd" 'no image copy under the default root'
cp "${amdsite}/libmigraphx-ep.so" "${work}/ep root/lib/libmigraphx-ep.so"
export ORT_AMDGPU_EP_ROOT="${work}/ep root"
needed_lines "${amdsite}" migraphx "${work}/proof-amd" libmigraphx_c.so.3 libamdhip64.so.7
unset ORT_AMDGPU_EP_ROOT
printf 'sdk\n' > "${work}/bundle/lib/libmigraphx-ep.so"
t_assert_ok ort_assert_no_bundled_host_runtime "${work}/bundle" migraphx 'the plugin module is the bundle'"'"'s own EP, not a host SDK library'
printf 'sdk\n' > "${work}/bundle/lib/libmigraphx_c.so.3"
t_assert_fails ort_assert_no_bundled_host_runtime "${work}/bundle" migraphx
rm "${work}/bundle/lib/libmigraphx-ep.so" "${work}/bundle/lib/libmigraphx_c.so.3"
printf 'x' >> "${work}/ep root/lib/libmigraphx-ep.so"
t_assert_fails env ORT_AMDGPU_EP_ROOT="${work}/ep root" bash -c 'source "$1"; ort_python_host_runtime_needed "$2" migraphx "$3" "$4"' _ "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh" "${amdsite}" "${wheels}" "${work}/proof-amd" 'a module that differs from the image copy fails'
t_assert_fails env ORT_AMDGPU_EP_ROOT="${work}/nowhere" bash -c 'source "$1"; ort_python_host_runtime_needed "$2" migraphx "$3" "$4"' _ "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh" "${amdsite}" "${wheels}" "${work}/proof-amd" 'no image copy, no proof'
t_summary
