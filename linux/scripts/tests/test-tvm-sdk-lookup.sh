#!/usr/bin/env bash
# SDK selection order is covered with empty libraries; no ELF ABI or real Vulkan driver is exercised.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SDK_ROOT="${WORK}/SDK root"
LIB="${TESTS_DIR}/../05-frameworks/tvm-detect.sh"
: "${TVM_DETECT_SOURCE:=}"
if [ -n "${TVM_DETECT_SOURCE}" ]; then
  sed 's|/opt/vulkan|"${SDK_ROOT}"|g' "${TVM_DETECT_SOURCE}" > "${WORK}/legacy.sh"
  LIB="${WORK}/legacy.sh"
fi
# shellcheck source=../05-frameworks/tvm-detect.sh
source "${LIB}"
export TARGET_ARCH=arm64
mkdir -p "${SDK_ROOT}/1/aarch64/lib" "${SDK_ROOT}/2/aarch64/lib" "${SDK_ROOT}/1/x86_64/lib" "${WORK}/override/lib"
touch "${SDK_ROOT}/1/aarch64/lib/libSPIRV-Tools-shared.so" \
      "${SDK_ROOT}/2/aarch64/lib/libSPIRV-Tools.a" \
      "${SDK_ROOT}/1/x86_64/lib/libSPIRV-Tools.a" \
      "${WORK}/override/lib/libSPIRV-Tools.a" \
      "${SDK_ROOT}/1/aarch64/lib/libvulkan.so.1" \
      "${SDK_ROOT}/2/aarch64/lib/libvulkan.so"
t_case "target static SPIRV outranks an earlier shared library and all host libraries"
t_assert_eq "${SDK_ROOT}/2/aarch64/lib/libSPIRV-Tools.a" "$(VULKAN_SDK="${WORK}/override" detect_spirv_tools_library "${SDK_ROOT}")"
t_case "the unversioned target loader outranks an earlier versioned loader"
t_assert_eq "${SDK_ROOT}/2/aarch64/lib/libvulkan.so" "$(detect_vulkan_library "${SDK_ROOT}")"
rm "${SDK_ROOT}/2/aarch64/lib/libSPIRV-Tools.a"
t_case "a target shared SPIRV library outranks a generic static host library"
t_assert_eq "${SDK_ROOT}/1/aarch64/lib/libSPIRV-Tools-shared.so" "$(detect_spirv_tools_library "${SDK_ROOT}")"
rm "${SDK_ROOT}/1/aarch64/lib/libSPIRV-Tools-shared.so"
t_case "SPIRV retains its generic SDK fallback before the explicit override"
t_assert_eq "${SDK_ROOT}/1/x86_64/lib/libSPIRV-Tools.a" "$(VULKAN_SDK="${WORK}/override" detect_spirv_tools_library "${SDK_ROOT}")"
rm "${SDK_ROOT}/1/x86_64/lib/libSPIRV-Tools.a"
t_case "the explicit override is used after SDK candidates are exhausted"
t_assert_eq "${WORK}/override/lib/libSPIRV-Tools.a" "$(VULKAN_SDK="${WORK}/override" detect_spirv_tools_library "${SDK_ROOT}")"
t_case "a missing SPIRV library returns an empty answer and failure"
t_assert_eq '' "$(VULKAN_SDK='' detect_spirv_tools_library "${SDK_ROOT}")"
t_assert_eq 1 "$(VULKAN_SDK='' t_rc detect_spirv_tools_library "${SDK_ROOT}")"
t_case "a foreign loader is never selected for an unknown target"
t_assert_eq '' "$(TARGET_ARCH=unknown detect_vulkan_library "${SDK_ROOT}")"
t_assert_eq 1 "$(TARGET_ARCH=unknown t_rc detect_vulkan_library "${SDK_ROOT}")"
t_summary
