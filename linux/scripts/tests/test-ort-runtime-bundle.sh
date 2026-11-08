#!/usr/bin/env bash
# Provider staging checks filenames and bytes, not wheel provenance, licenses or GPU execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=linux/scripts/06-packaging/ort-runtime-bundle.sh
source "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/ort with spaces" "${work}/ep root/lib"
for file in libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
  printf '%s\n' "${file}" > "${work}/ort with spaces/${file}"
done
ln -s libonnxruntime.so.1 "${work}/ort with spaces/libonnxruntime.so"
printf 'plugin\n' > "${work}/ep root/lib/libmigraphx-ep.so"
export ORT_AMDGPU_EP_ROOT="${work}/ep root"

t_case "each variant stages only its engine and preserves the source bytes"
for variant in cpu nvidia amd; do
  t_assert_ok stage_ort_runtime "${work}/${variant} output" "${work}/ort with spaces" "${variant}"
  t_assert_ok cmp "${work}/ort with spaces/libonnxruntime.so.1" "${work}/${variant} output/libonnxruntime.so"
  t_assert_fails test -L "${work}/${variant} output/libonnxruntime.so"
done
t_assert_fails test -e "${work}/cpu output/libonnxruntime_providers_shared.so"
t_assert_ok cmp "${work}/ort with spaces/libonnxruntime_providers_cuda.so" "${work}/nvidia output/libonnxruntime_providers_cuda.so"
t_assert_fails test -e "${work}/nvidia output/libmigraphx-ep.so"
t_assert_ok cmp "${work}/ep root/lib/libmigraphx-ep.so" "${work}/amd output/libmigraphx-ep.so"
t_assert_fails test -e "${work}/amd output/libonnxruntime_providers_cuda.so"
t_assert_fails compgen -G "${work}/amd output/libonnxruntime_providers_*"

t_case "the AMD module comes from ORT_AMDGPU_EP_ROOT, the image's plugin prefix by default"
t_assert_eq "${work}/ep root/lib" "$(ort_amdgpu_ep_dir)"
t_assert_eq "/usr/local/lib/onnxruntime-ep-amdgpu/lib" "$(ORT_AMDGPU_EP_ROOT='' ort_amdgpu_ep_dir)"
t_assert_eq "/x/capi/libmigraphx-ep.so" "$(ort_python_provider_file /x/capi migraphx)"
t_assert_eq "/x/capi/libonnxruntime_providers_cuda.so" "$(ort_python_provider_file /x/capi cuda)"
t_assert_fails ort_python_provider_file /x/capi tensorrt

t_case "missing engines and invalid variants fail before modifying the destination"
mkdir "${work}/existing"
printf 'keep\n' > "${work}/existing/libonnxruntime.so"
rm "${work}/ort with spaces/libonnxruntime_providers_cuda.so"
t_assert_fails stage_ort_runtime "${work}/existing" "${work}/ort with spaces" nvidia
t_assert_eq "keep" "$(cat "${work}/existing/libonnxruntime.so")" "preflight does not overwrite existing output"
t_assert_fails stage_ort_runtime "${work}/unknown" "${work}/ort with spaces" invalid
t_assert_fails test -e "${work}/unknown"
t_assert_contains "$(ORT_AMDGPU_EP_ROOT="${work}/nowhere" stage_ort_runtime "${work}/no plugin" "${work}/ort with spaces" amd 2>&1)" "ORT amd variant requires ${work}/nowhere/lib/libmigraphx-ep.so"
t_assert_fails test -e "${work}/no plugin"

t_case "the helper is also callable as a script"
t_assert_ok bash "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh" "${work}/script" "${work}/ort with spaces" amd
t_assert_ok cmp "${work}/ep root/lib/libmigraphx-ep.so" "${work}/script/libmigraphx-ep.so"
t_summary
