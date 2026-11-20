#!/usr/bin/env bash
# Native SDK and HIP checks retain the same argument parsing and caller-visible compiler bindings.
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK ROCM_ROOT' 2 "$@" || return
rocm="$2"
source "${SCRIPT_DIR}/entry-common.sh" || return
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root || return
: "${rocm:?ROCm root required}" "${clang_root:?source Clang root required}" "${gcc_root:?source GCC root required}"
