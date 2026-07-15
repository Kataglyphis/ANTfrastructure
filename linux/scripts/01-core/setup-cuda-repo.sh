#!/usr/bin/env bash
# setup-cuda-repo.sh - install the NVIDIA CUDA apt keyring/repo for the current
# architecture, then refresh the apt cache.
#
# Extracted verbatim from the CUDA-repo RUN in linux/Dockerfile.nvidia. Invoked
# via a BuildKit bind-mount of linux/scripts/01-core, exactly like the other
# core scripts. Reads UBUNTU_CODENAME from the build environment (declared as an
# ARG in Dockerfile.nvidia, which Docker exposes as an env var to the RUN).
set -euo pipefail

# Apply the fast Ubuntu mirror rewrite (if enabled) before any apt access, so the
# apt-get update below uses the configured mirror. No-op unless
# USE_FAST_UBUNTU_MIRROR is truthy. Folded in here so callers invoke a single
# script (was a separate use-fast-ubuntu-mirror.sh line in Dockerfile.nvidia).
_SETUP_CUDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${_SETUP_CUDA_DIR}/use-fast-ubuntu-mirror.sh"

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64)   CUDA_ARCH="x86_64" ;;
  arm64)   CUDA_ARCH="sbsa" ;;
  *)       echo "WARNING: CUDA packages may not be available for arch ${ARCH}" >&2; CUDA_ARCH="${ARCH}" ;;
esac
KEYRING_PKG="cuda-keyring_1.1-1_all.deb"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_CODENAME}/${CUDA_ARCH}/${KEYRING_PKG}"
curl -fSsL "${KEYRING_URL}" -o "/tmp/${KEYRING_PKG}"
dpkg -i "/tmp/${KEYRING_PKG}"
rm "/tmp/${KEYRING_PKG}"
apt-get update -qq
