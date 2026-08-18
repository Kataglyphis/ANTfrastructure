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
    # GPU1 fix (2026-08-17): refresh the indices FIRST. install-cuda-stack.sh's
    # RUN used to wipe /var/lib/apt/lists inside the SHARED apt-lib cache mount,
    # so this RUN saw empty indices, found no tensorrt candidates, and the
    # 2>/dev/null fallback chain swallowed it — TensorRT silently missing from
    # the shipped :*-nvidia image. An explicit update makes this path
    # self-sufficient regardless of what earlier RUNs did to the shared mount.
    apt-get update -qq || echo "TensorRT: apt-get update failed; install may find no candidates" >&2
    if apt-get install -y --no-install-recommends "tensorrt-dev=${TENSORRT_VERSION}*" "tensorrt-libs=${TENSORRT_VERSION}*" 2>/dev/null; then
        echo "TensorRT: installed ${TENSORRT_VERSION} from NVIDIA apt repo"
        _trt_ok=1
    elif apt-get install -y --no-install-recommends tensorrt-dev tensorrt-libs 2>/dev/null; then
        # LOUD on purpose (2026-08-08). TENSORRT_VERSION is ONE pin for both
        # lanes, and it tracks the zip staged for Windows — which may be an
        # NVIDIA *Enterprise* build that the public apt repo does not carry. The
        # fallback is deliberate and fine, but it silently UNPINS TensorRT on
        # this lane, and the previous single `echo` was one line among thousands
        # in a multi-hour log: nobody would ever see it.
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
