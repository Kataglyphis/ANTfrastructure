#!/usr/bin/env bash
# Header and loader fixtures cover lookup order and absence; no Vulkan API or GPU is exercised.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_source_functions "${TESTS_DIR}/../06-packaging/smoke-vulkan.sh" _vulkan_sdk_paths check_vulkan_headers check_vulkan_loader || exit 1
D="$(mktemp -d)"
trap 'rm -rf "${D}"' EXIT
export VULKAN_SDK_ROOT="${D}/sdk with spaces" ACTIVE_LINK="${D}/active sdk"
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; }
for suffix in include lib; do
  t_case "${suffix} uses active SDK then x86_64, aarch64 and riscv64"
  t_assert_eq "${ACTIVE_LINK}/${suffix}
${VULKAN_SDK_ROOT}/x86_64/${suffix}
${VULKAN_SDK_ROOT}/aarch64/${suffix}
${VULKAN_SDK_ROOT}/riscv64/${suffix}" "$(_vulkan_sdk_paths "${suffix}")"
done
for root in "${ACTIVE_LINK}" "${VULKAN_SDK_ROOT}/x86_64" "${VULKAN_SDK_ROOT}/aarch64" "${VULKAN_SDK_ROOT}/riscv64"; do
  mkdir -p "${root}/include/vulkan" "${root}/lib"
  : > "${root}/include/vulkan/vulkan.h"
  : > "${root}/lib/libvulkan.so.1"
done
for root in "${ACTIVE_LINK}" "${VULKAN_SDK_ROOT}/x86_64" "${VULKAN_SDK_ROOT}/aarch64" "${VULKAN_SDK_ROOT}/riscv64"; do
  t_case "${root}: first remaining SDK provides headers and loader"
  t_assert_contains "$(check_vulkan_headers)" "PASS vulkan/vulkan.h found in ${root}/include"
  t_assert_contains "$(check_vulkan_loader)" "PASS Vulkan loader found: ${root}/lib/libvulkan.so.1"
  rm -rf "${root}"
done
t_case "absence produces a failure for each payload"
t_assert_contains "$(check_vulkan_headers)" 'FAIL vulkan/vulkan.h not found'
t_assert_contains "$(check_vulkan_loader)" 'FAIL libvulkan.so not found'
t_summary
