#!/usr/bin/env bash
# Run in an admitted producer; the complete source stack still needs binary licence review and ordinary consumer/image acceptance.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK SOURCE_CACHE ROCM_ROOT' 3 "$@"
cache="$2" rocm="$3"
source "${SCRIPT_DIR}/entry-common.sh"
source "${SCRIPT_DIR}/source-stack.sh"
: "${MIGRAPHX_SOURCE_PREFIX:=/opt/rocm/migraphx}"
python3 "${SCRIPT_DIR}/stage-backend-install.py" check-prefix --prefix "${MIGRAPHX_SOURCE_PREFIX}"
migraphx_new_work "${work}" work
mkdir -p "${cache}"
cache="$(cd "${cache}" && pwd)"
declare -a sources=()
declare -A archives=()
migraphx_stack_plan sources "${cache}" "${SCRIPT_DIR}/source-archives.txt"
printf '%s\n' "${sources[@]}" > "${work}/source-archive-plan.txt"
bash "${SCRIPT_DIR}/check-hip-compiler.sh" "${work}/hip-compiler-check" "${rocm}"
migraphx_stack_fetch sources archives
bash "${SCRIPT_DIR}/build-source-deps.sh" "${work}/parsers" "${archives[abseil]}" "${archives[protobuf]}"
bash "${SCRIPT_DIR}/build-source-ck.sh" "${work}/ck" "${archives[ck]}" "${archives[rocm-cmake]}"
bash "${SCRIPT_DIR}/verify-source-ck.sh" "${work}/ck-api" "${work}/ck/host-deps" "${work}/ck/ck-source/include/ck/utility/type.hpp"
bash "${SCRIPT_DIR}/build-source-rocmlir.sh" "${work}/rocmlir" "${archives[rocmlir]}" "${archives[rocm-cmake]}" "${rocm}"
export MIGRAPHX_DEPS_PREFIX="${work}/parsers/host-deps;${work}/ck/host-deps;${work}/rocmlir/host-deps"
bash "${SCRIPT_DIR}/check-source-sdk.sh" "${work}/sdk-check" "${rocm}"
bash "${SCRIPT_DIR}/build-source-backend.sh" "${work}/backend" "${archives[migraphx]}" "${archives[rocm-cmake]}" "${archives[msgpack]}" "${rocm}"
printf 'MIGRAPHX COMPLETE SOURCE STACK BUILT: %s; binary licence review and ordinary consumer/image acceptance remain required\n' "${MIGRAPHX_SOURCE_PREFIX}"
