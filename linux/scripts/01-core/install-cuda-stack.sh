#!/usr/bin/env bash
# install-cuda-stack.sh - install the CUDA toolkit/libraries + cuDNN for the
# configured CUDA version, then refresh ldconfig. Assumes the CUDA apt repo has
# already been added (setup-cuda-repo.sh). Extracted verbatim from the CUDA
# components RUN in linux/Dockerfile.nvidia so it can be shellcheck'd, matching
# the setup-cuda-repo.sh / install-tensorrt.sh extractions.
#
# Environment (declared as ARGs in Dockerfile.nvidia, exposed as env to the RUN):
#   CUDA_VERSION_MAJOR_MINOR   e.g. "12-6"
#   CUDNN_MAJOR                e.g. "9"
#   CUDNN_VERSION              e.g. "9.5.1" (optional; enables the pinned path)
set -euo pipefail

CUDA_MAJOR="$(echo "${CUDA_VERSION_MAJOR_MINOR}" | cut -d'-' -f1)"
apt-get install -y --no-install-recommends \
    cuda-toolkit-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-libraries-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-libraries-dev-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-nvtx-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-command-line-tools-${CUDA_VERSION_MAJOR_MINOR} \
    libnccl2 \
    libnccl-dev \
    libcublas-${CUDA_VERSION_MAJOR_MINOR} \
    libcublas-dev-${CUDA_VERSION_MAJOR_MINOR} \
    libcusparse-${CUDA_VERSION_MAJOR_MINOR} \
    libcusparse-dev-${CUDA_VERSION_MAJOR_MINOR} \
    libcufft-${CUDA_VERSION_MAJOR_MINOR} \
    libcufft-dev-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-cudart-dev-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-compat-${CUDA_VERSION_MAJOR_MINOR}
CUDA_VER_DOT="$(echo "${CUDA_VERSION_MAJOR_MINOR}" | tr '-' '.')"
apt-get install -y --no-install-recommends \
    "libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" \
    "libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_VER_DOT} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_VER_DOT} || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR} || \
echo "WARNING: cuDNN packages not found; continuing without cuDNN"
# NOTE: the CUDA repo (/etc/apt/sources.list.d/cuda*.list) is intentionally NOT
# removed here — the TensorRT RUN still installs tensorrt-dev / tensorrt-libs
# from the NVIDIA apt repo. Repo removal happens at the end of that RUN (the last
# apt install against NVIDIA repos in Dockerfile.nvidia).
rm -rf /var/lib/apt/lists/*
ldconfig
