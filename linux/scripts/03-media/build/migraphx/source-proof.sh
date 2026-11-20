#!/usr/bin/env bash
# Source quality checks do not build vendor libraries or establish final image acceptance.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/proof-cleanup.sh"
trap 'migraphx_proof_finish "$?" /proof /hub/linux/scripts/01-core /workspace /proof /cache /quality-cache' EXIT
export UV_OFFLINE=1 UV_NO_INDEX=1 UV_FIND_LINKS=/quality-wheels UV_CACHE_DIR=/quality-cache
export LC_ALL=C PATH="/quality-tools:/sdk/flutter/bin/cache/dart-sdk/bin:${PATH}" SCCACHE_DIR=/cache SCCACHE_BUCKET=""
uv venv --python /workspace/quality/.venv/bin/python /workspace/logs/tools/cmake-format-linux
bash /workspace/linux/scripts/03-media/build/migraphx/source-check.sh /proof
