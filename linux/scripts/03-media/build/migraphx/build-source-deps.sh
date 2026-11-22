#!/usr/bin/env bash
# Run only in an admitted producer; building these parser dependencies is not image or hardware acceptance.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK ABSEIL_ARCHIVE PROTOBUF_ARCHIVE' 3 "$@"
abseil_archive="$2" protobuf_archive="$3"
source "${SCRIPT_DIR}/entry-common.sh"
source "${SCRIPT_DIR}/source-deps.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
migraphx_build_static_dep abseil "${abseil_archive}" "${MIGRAPHX_WINDOWS_ABSEIL_SHA256}" "${work}" "${clang_root}" "${gcc_root}"
migraphx_build_static_dep protobuf "${protobuf_archive}" "${MIGRAPHX_WINDOWS_PROTOBUF_SHA256}" "${work}" "${clang_root}" "${gcc_root}"
printf 'MIGRAPHX STATIC PARSER DEPS BUILT: %s/host-deps; backend build and acceptance remain required\n' "${work}"
