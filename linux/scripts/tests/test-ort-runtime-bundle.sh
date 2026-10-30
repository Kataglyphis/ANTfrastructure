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
mkdir -p "${work}/ort with spaces"
for file in libonnxruntime.so.1 libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so libonnxruntime_providers_migraphx.so; do
  printf '%s\n' "${file}" > "${work}/ort with spaces/${file}"
done
ln -s libonnxruntime.so.1 "${work}/ort with spaces/libonnxruntime.so"

t_case "each variant stages only its provider and preserves the source bytes"
for variant in cpu nvidia amd; do
  t_assert_ok stage_ort_runtime "${work}/${variant} output" "${work}/ort with spaces" "${variant}"
  t_assert_ok cmp "${work}/ort with spaces/libonnxruntime.so.1" "${work}/${variant} output/libonnxruntime.so"
  t_assert_fails test -L "${work}/${variant} output/libonnxruntime.so"
done
t_assert_fails test -e "${work}/cpu output/libonnxruntime_providers_shared.so"
t_assert_ok cmp "${work}/ort with spaces/libonnxruntime_providers_cuda.so" "${work}/nvidia output/libonnxruntime_providers_cuda.so"
t_assert_fails test -e "${work}/nvidia output/libonnxruntime_providers_migraphx.so"
t_assert_ok cmp "${work}/ort with spaces/libonnxruntime_providers_migraphx.so" "${work}/amd output/libonnxruntime_providers_migraphx.so"
t_assert_fails test -e "${work}/amd output/libonnxruntime_providers_cuda.so"

t_case "missing providers and invalid variants fail before modifying the destination"
mkdir "${work}/existing"
printf 'keep\n' > "${work}/existing/libonnxruntime.so"
rm "${work}/ort with spaces/libonnxruntime_providers_cuda.so"
t_assert_fails stage_ort_runtime "${work}/existing" "${work}/ort with spaces" nvidia
t_assert_eq "keep" "$(cat "${work}/existing/libonnxruntime.so")" "preflight does not overwrite existing output"
t_assert_fails stage_ort_runtime "${work}/unknown" "${work}/ort with spaces" invalid
t_assert_fails test -e "${work}/unknown"

t_case "the helper is also callable as a script"
t_assert_ok bash "${TESTS_DIR}/../06-packaging/ort-runtime-bundle.sh" "${work}/script" "${work}/ort with spaces" amd
t_assert_ok cmp "${work}/ort with spaces/libonnxruntime_providers_migraphx.so" "${work}/script/libonnxruntime_providers_migraphx.so"
t_summary
