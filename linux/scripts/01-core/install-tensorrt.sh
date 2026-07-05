#!/usr/bin/env bash
# install-tensorrt.sh - 3-tier TensorRT install: local repo deb, then NVIDIA
# apt repo (pinned then unpinned), then skip. Also normalizes the install
# layout under /usr/local/tensorrt.
#
# Extracted verbatim from the TensorRT RUN in linux/Dockerfile.nvidia. Invoked
# via a BuildKit bind-mount of linux/scripts/01-core, exactly like the other
# core scripts. Reads TENSORRT_VERSION from the build environment (declared as
# an ARG in Dockerfile.nvidia, which Docker exposes as an env var to the RUN).
# Consumes /tmp/tensorrt-local-repo.deb if the preceding stage staged one.
set -euo pipefail

_trt_ok=0
if [ -f /tmp/tensorrt-local-repo.deb ]; then
    echo "TensorRT: installing local repo deb..."
    dpkg -i /tmp/tensorrt-local-repo.deb 2>/dev/null || true
    _trt_key="$(find /var -name 'nv-tensorrt-local-*-keyring.gpg' 2>/dev/null | head -1)"
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
    if apt-get install -y --no-install-recommends "tensorrt-dev=${TENSORRT_VERSION}*" "tensorrt-libs=${TENSORRT_VERSION}*" 2>/dev/null; then
        echo "TensorRT: installed ${TENSORRT_VERSION} from NVIDIA apt repo"
        _trt_ok=1
    elif apt-get install -y --no-install-recommends tensorrt-dev tensorrt-libs 2>/dev/null; then
        echo "TensorRT: installed from NVIDIA apt repo (unpinned; ${TENSORRT_VERSION} not available)"
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
