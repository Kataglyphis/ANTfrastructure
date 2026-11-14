#!/usr/bin/env bash
# A complete private source build does not establish binary licence closure, production wiring or GPU acceptance.
set -euo pipefail

# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK MIGRAPHX_ARCHIVE ROCM_CMAKE_ARCHIVE MSGPACK_ARCHIVE ROCM_ROOT' 5 "$@"
: "${MIGRAPHX_SOURCE_PREFIX:=/opt/rocm/migraphx}"
python3 "${SCRIPT_DIR}/stage-backend-install.py" check-prefix --prefix "${MIGRAPHX_SOURCE_PREFIX}"
# Preparation retains the selected compiler, Python and all ten GPU feature bindings in this shell.
# shellcheck source=linux/scripts/03-media/build/migraphx/prepare-source-build.sh
source "${SCRIPT_DIR}/prepare-source-build.sh" "$@"
[[ -n "${CMAKE_COMPILER_CACHE_PIN:-}" ]] || { printf 'Missing MIGraphX build compiler-cache pin\n' >&2; exit 1; }
sha256sum "${work}/source/LICENSE" >> "${work}/source-inputs.sha256"
jobs="$(compute_cpp_heavy_jobs "${JOBS:-}")"
cmake --build "${work}/build" --parallel "${jobs}"
cmake --install "${work}/build"
sha256sum --check "${work}/source-inputs.sha256"
"${HOST_PYTHON_BIN}" "${SCRIPT_DIR}/stage-backend-install.py" stage \
  --prefix "${MIGRAPHX_SOURCE_PREFIX}" --work "${work}" --deps-prefix "${MIGRAPHX_DEPS_PREFIX}" \
  --pybind-version "${PY_PYBIND11_VERSION:?missing selected pybind11 pin}" \
  --version "${MIGRAPHX_VERSION}" --source-commit "${MIGRAPHX_WINDOWS_COMMIT}" \
  --source-sha256 "${MIGRAPHX_WINDOWS_SOURCE_SHA256}" --patch "${patch_file}" --python-patch "${python_patch_file}"
printf 'MIGRAPHX SOURCE BUILT: %s; ordinary SDK/GPU, binary licence review and image acceptance remain required\n' "${MIGRAPHX_SOURCE_PREFIX}"
