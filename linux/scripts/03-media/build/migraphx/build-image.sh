#!/usr/bin/env bash
# The normal producer keeps the distro SDK while selecting the complete corrected source backend.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK SOURCE_CACHE ROCM_ROOT' 3 "$@"
: "${MIGRAPHX_SOURCE_PREFIX:=/opt/rocm/migraphx}"
[[ "${MIGRAPHX_SOURCE_PREFIX}" == /opt/rocm/migraphx ]] || {
  printf 'The AMD image requires the canonical MIGraphX source prefix\n' >&2; exit 2;
}
export MIGRAPHX_SOURCE_PREFIX
source "${SCRIPT_DIR}/entry-common.sh"
setup_host_python_environment
uv pip install --python "${HOST_PYTHON_BIN}" --no-deps "pybind11==${PY_PYBIND11_VERSION:?missing selected pybind11 pin}"
bash "${SCRIPT_DIR}/build-source-stack.sh" "$@"
# shellcheck source=linux/scripts/06-packaging/media-payloads.sh
source "${SCRIPT_DIR}/../../../06-packaging/media-payloads.sh"
publish_rocm_ld_path
ldconfig
