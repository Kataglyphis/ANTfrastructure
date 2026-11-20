#!/usr/bin/env bash
# Build the pinned host code generator; this component is not a full backend or GPU acceptance.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK CK_ARCHIVE ROCM_CMAKE_ARCHIVE' 3 "$@"
ck_archive="$2" rocm_cmake_archive="$3"
source "${SCRIPT_DIR}/entry-common.sh"
source "${SCRIPT_DIR}/source-deps.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
migraphx_prepare_rocm_cmake "${work}" "${rocm_cmake_archive}"
migraphx_build_static_dep ck "${ck_archive}" "${MIGRAPHX_CK_SOURCE_SHA256}" "${work}" "${clang_root}" "${gcc_root}"
printf 'MIGRAPHX CK HOST BUILT: %s/host-deps; full backend and acceptance remain required\n' "${work}"
