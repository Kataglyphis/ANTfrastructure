#!/usr/bin/env bash
# TensorRT: staged local repo deb, then NVIDIA apt pinned to TENSORRT_VERSION, then unpinned, then skip.
set -euo pipefail

_trt_ok=0
if [ -f /tmp/tensorrt-local-repo.deb ]; then
    echo "TensorRT: installing local repo deb..."
    dpkg -i /tmp/tensorrt-local-repo.deb 2>/dev/null || true
    _trt_key="$(find /var -name 'nv-tensorrt-local-*-keyring.gpg' 2>/dev/null | head -1 || true)"
    if [ -n "${_trt_key}" ]; then
        cp "${_trt_key}" /usr/share/keyrings/ 2>/dev/null || true
    fi
    apt-get update -qq 2>/dev/null || true
    if apt-get install -y --no-install-recommends tensorrt tensorrt-dev tensorrt-libs 2>/dev/null; then
        echo "TensorRT: installed from local repo"
        _trt_ok=1
    else
        echo "TensorRT: local repo install failed; trying NVIDIA repo..."
    fi
fi
if [ "${_trt_ok}" -eq 0 ]; then
    # Refresh first: empty indices in the shared apt cache mount would make the chain below skip silently.
    apt-get update -qq || echo "TensorRT: apt-get update failed; install may find no candidates" >&2
    if apt-get install -y --no-install-recommends "tensorrt-dev=${TENSORRT_VERSION}*" "tensorrt-libs=${TENSORRT_VERSION}*" 2>/dev/null; then
        echo "TensorRT: installed ${TENSORRT_VERSION} from NVIDIA apt repo"
        _trt_ok=1
    elif apt-get install -y --no-install-recommends tensorrt-dev tensorrt-libs 2>/dev/null; then
        # Loud on purpose: the pin tracks the Windows zip, possibly an Enterprise build apt does not serve.
        _trt_actual="$(dpkg-query -W -f='${Version}' tensorrt-dev 2>/dev/null || echo 'unknown')"
        echo "=============================================================" >&2
        echo "WARNING: TensorRT is UNPINNED on this build." >&2
        echo "  requested (versions.env TENSORRT_VERSION): ${TENSORRT_VERSION}" >&2
        echo "  installed (newest in NVIDIA apt repo):     ${_trt_actual}" >&2
        echo "  The pinned version is not served by apt — expected when the pin" >&2
        echo "  tracks an Enterprise zip staged for the Windows lane." >&2
        echo "=============================================================" >&2
        echo "TensorRT: installed ${_trt_actual} from NVIDIA apt repo (UNPINNED — see warning above)"
        _trt_ok=1
    else
        echo "TensorRT: not available in any repo; skipping"
    fi
fi
if [ ! -f /usr/local/tensorrt/include/NvInfer.h ]; then
    TRT_INC=$(find /usr/include /usr/local -name "NvInfer.h" -print -quit 2>/dev/null || true)
    if [ -n "$TRT_INC" ]; then
        mkdir -p /usr/local/tensorrt
        ln -snf "$(dirname "$TRT_INC")" /usr/local/tensorrt/include
        ARCH="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || echo amd64)"
        ln -snf "/usr/lib/${ARCH}" /usr/local/tensorrt/lib 2>/dev/null || true
    fi
fi
