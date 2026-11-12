#!/usr/bin/env bash
# RISC-V compiles the pinned source once; native published wheels need no compiler server.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core="${1:-/opt/scripts/core}"
source "${core}/load-versions-env.sh"
load_versions_env "${core}/versions.env"
arch="${TARGETARCH:?missing target architecture}"
if [ "${arch}" = riscv64 ]; then
  source "${core}/common.sh"
  compiler_cache_launcher_env 2>/dev/null || true
  launcher="$(compiler_cache_launcher)"
  export CC="${launcher} ${CC:-gcc}" CXX="${launcher} ${CXX:-g++}"
  finish() {
    local status=$?
    trap - EXIT
    compiler_cache_stats_for_launcher "${launcher}" 'Compile requests|Cache hits|Cache misses|Cache errors|Cache timeouts|Cache read errors|Cache write errors' >&2
    if ! bash "${core}/sccache-s3-level.sh" drain; then
      [ "${status}" -ne 0 ] || status=1
    fi
    exit "${status}"
  }
  trap finish EXIT
fi
"/usr/local/bin/python${PYTHON_VERSION%.*}t" -I "${here}/free-threaded-probe-deps.py" build \
  --numpy-version "${PY_NUMPY_VERSION:?missing NumPy pin}" --arch "${arch}" --core "${core}"
