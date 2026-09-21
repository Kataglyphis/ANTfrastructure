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

# cuda-compat is the DATACENTER forward-compatibility driver ("Used for TESLA
# cards only" in its own Description): ~438 MB that drops a REAL libcuda.so.1
# for a discrete-GPU driver into /usr/local/cuda-*/compat. On a Jetson the CUDA
# driver is welded to the L4T BSP and injected from the host by
# nvidia-container-toolkit, so this package is at best dead weight and at worst
# shadows the real Tegra libcuda. NVIDIA ships a SEPARATE cuda-compat-orin-*
# for Orin in the same sbsa repo; this is not it.
# Default keeps the historical behaviour for the datacenter lanes.
_cuda_compat_pkgs=()
if [ "${CUDA_INSTALL_COMPAT:-1}" = "1" ]; then
  _cuda_compat_pkgs+=("cuda-compat-${CUDA_VERSION_MAJOR_MINOR}")
else
  echo "CUDA_INSTALL_COMPAT=0 — skipping cuda-compat-${CUDA_VERSION_MAJOR_MINOR} (Tegra/Jetson: the driver comes from the L4T BSP)"
fi

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
    "${_cuda_compat_pkgs[@]}"
CUDA_VER_DOT="$(echo "${CUDA_VERSION_MAJOR_MINOR}" | tr '-' '.')"
# CUDNN_VERSION is optional (see header): when unset/empty, skip the pinned
# tier and fall through to the unpinned fallbacks below.
{ [ -n "${CUDNN_VERSION:-}" ] && \
apt-get install -y --no-install-recommends \
    "libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" \
    "libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*"; } || \
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
# GPU4 (2026-08-17): the former `rm -rf /var/lib/apt/lists/*` here was USELESS
# for image size (/var/lib/apt is a cache MOUNT — not in the layer; the real
# unmounted cleanup happens later in Dockerfile.nvidia) and HARMFUL: it wiped
# the shared per-arch apt-lib cache so the next RUN (install-tensorrt.sh) saw
# empty indices → the TensorRT silent-skip (GPU1). Dropped.
ldconfig
