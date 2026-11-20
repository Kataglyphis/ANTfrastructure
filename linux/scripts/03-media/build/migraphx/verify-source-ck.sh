#!/usr/bin/env bash
# Prove an external installed CK host target and one exact original header; this is not GPU inference.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK CK_PREFIX ORIGINAL_HEADER' 3 "$@"
ck_prefix="$(cd "$2" && pwd)" original_header="$3"
source "${SCRIPT_DIR}/entry-common.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
cmake_args=(
  "-DCK_PREFIX=${ck_prefix}" "-DCK_REQUIRED_VERSION=${MIGRAPHX_CK_HOST_VERSION}"
)
cmake_args+=(
  "-Dcomposable_kernel_host_DIR=${ck_prefix}/lib/cmake/composable_kernel_host"
)
migraphx_configure_native_consumer cmake_args "${work}" "${SCRIPT_DIR}/ck-host-consumer" "${clang_root}" "${gcc_root}" \
  20 "composable_kernel_host_DIR=${ck_prefix}/lib/cmake/composable_kernel_host"
ck_library=''
migraphx_build_native_consumer "${work}" "${ck_prefix}/lib/libck_host.a" "${JOBS:-2}" ck_library
"${work}/build/ck-host-consumer" "${work}/embedded-header.hpp"
cmp -- "${original_header}" "${work}/embedded-header.hpp"
sha256sum "${ck_library}" "${original_header}" "${work}/embedded-header.hpp" > "${work}/consumer-inputs.sha256"
printf 'CK HOST EXTERNAL CONSUMER PASSED: installed target and exact embedded header; GPU acceptance remains required\n'
