#!/usr/bin/env bash
# vulkan_env_default_cpu_driver (CON284): lavapipe only where no GPU node exists and the caller named no driver; not what the loader then loads.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ENVMOD="${TESTS_DIR}/../01-core/vulkan-env.sh"

ROOT="$(t_mktemp -d)"
DEV="${ROOT}/dev"
ICD_A="${ROOT}/usr-share"
ICD_B="${ROOT}/etc"
mkdir -p "${DEV}/dri" "${ICD_A}" "${ICD_B}"
touch "${DEV}/dri/card0" "${ICD_A}/powervr_mesa_icd.x86_64.json"

# _select [VAR=value ...]: the selection a clean bash ends with, then the log line it printed.
_select() {
  env -i HOME=/nonexistent PATH=/usr/bin:/bin "$@" bash -c 'set -eu; source "$1"
    vulkan_env_default_cpu_driver "$2" "$3:$4"
    printf "select=%s\n" "${VK_LOADER_DRIVERS_SELECT-<unset>}"' _ "${ENVMOD}" "${DEV}" "${ICD_A}" "${ICD_B}" 2>&1
}

t_case "no GPU node and no lavapipe ICD: the loader keeps its own choice"
t_assert_eq "select=<unset>" "$(_select)"

t_case "no GPU node and a lavapipe ICD in any listed directory: lavapipe only, and the log says so"
touch "${ICD_B}/lvp_icd.x86_64.json"
out="$(_select)"
t_assert_contains "${out}" "select=*lvp*"
t_assert_contains "${out}" "No GPU device node: the Vulkan loader takes lavapipe only"

t_case "a driver the caller names wins over the default"
t_assert_eq "select=*nvidia*" "$(_select VK_LOADER_DRIVERS_SELECT='*nvidia*')"
t_assert_eq "select=<unset>" "$(_select VK_DRIVER_FILES=/x/radeon_icd.json)" "VK_DRIVER_FILES names the driver"
t_assert_eq "select=<unset>" "$(_select VK_ICD_FILENAMES=/x/intel_icd.json)" "the older VK_ICD_FILENAMES too"

t_case "a render node, an NVIDIA device or WSL's dxg means a GPU driver can work: no default"
touch "${DEV}/dri/renderD128"
t_assert_eq "select=<unset>" "$(_select)" "render node"
rm "${DEV}/dri/renderD128"
touch "${DEV}/nvidia0"
t_assert_eq "select=<unset>" "$(_select)" "nvidia0"
rm "${DEV}/nvidia0"
touch "${DEV}/dxg"
t_assert_eq "select=<unset>" "$(_select)" "dxg"
rm "${DEV}/dxg"
t_assert_contains "$(_select)" "select=*lvp*" "card0 alone is no render node"

t_summary
