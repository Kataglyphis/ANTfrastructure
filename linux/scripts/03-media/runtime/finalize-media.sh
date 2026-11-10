#!/usr/bin/env bash
# Keep wheel collection, both Python modes and final validation in the same fail-closed shell context.
set -euo pipefail
    source /opt/scripts/03-media/runtime/media-env.sh
    bash /opt/scripts/03-media/runtime/collect-artifacts.sh && \
    bash /opt/scripts/03-media/runtime/install-deps.sh && \
    bash /opt/scripts/03-media/runtime/configure-runtime.sh && \
    bash /opt/scripts/03-media/runtime/repair-wheels.sh && \
    bash /opt/scripts/03-media/runtime/verify-wheels.sh && \
    bash /opt/scripts/03-media/runtime/repair-wheels.sh --free-threaded && \
    bash /opt/scripts/03-media/runtime/verify-wheels.sh --free-threaded && \
    bash /opt/scripts/03-media/runtime/free-threaded-store.sh && \
    { uv pip install --no-deps /opt/wheels/*.whl || { [ "${TARGET_ARCH:-amd64}" != "amd64" ] || { echo "ERROR: uv pip install of collected wheels failed on amd64 — native wheels must install" >&2; exit 1; }; echo "WARNING: uv pip install of collected wheels failed (tolerated for cross-arch ${TARGET_ARCH} wheels)" >&2; }; } && \
    bash /opt/scripts/03-media/runtime/validate-media-runtime.sh && \
    PYTHONPATH="$(echo /opt/opencv5/lib/python*/site-packages 2>/dev/null):${PYTHONPATH:-}" \
    bash /opt/scripts/packaging/smoke-media.sh
