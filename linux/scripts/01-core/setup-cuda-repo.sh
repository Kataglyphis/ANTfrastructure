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
# VERIFIED fetch (supply-chain audit #1): this .deb installs the apt TRUST
# ANCHOR for every CUDA/cuDNN/TensorRT package — with an attacker-supplied
# key, apt's own signature checking is defeated for the whole NVIDIA lane.
# shellcheck disable=SC1091
source "${_SETUP_CUDA_DIR}/downloads.sh"
case "${CUDA_ARCH}" in
  x86_64) _cuda_keyring_sha="${CUDA_KEYRING_DEB_SHA256_X86_64:-}" ;;
  sbsa)   _cuda_keyring_sha="${CUDA_KEYRING_DEB_SHA256_SBSA:-}" ;;
  *)      _cuda_keyring_sha="" ;;
esac
if [ -z "${_cuda_keyring_sha}" ] && [ -f "${_SETUP_CUDA_DIR}/versions.env" ]; then
  _cuda_keyring_sha="$(sed -n "s/^CUDA_KEYRING_DEB_SHA256_$(echo "${CUDA_ARCH}" | tr '[:lower:]' '[:upper:]')=//p" "${_SETUP_CUDA_DIR}/versions.env")"
fi
if [ -n "${_cuda_keyring_sha}" ]; then
  download_verified_file "${KEYRING_URL}" "${_cuda_keyring_sha}" "/tmp/${KEYRING_PKG}"
else
  echo "WARNING: no CUDA keyring sha pin for ${CUDA_ARCH} — fetching the apt trust anchor UNVERIFIED" >&2
  download_file "${KEYRING_URL}" "/tmp/${KEYRING_PKG}" 3
fi
dpkg -i "/tmp/${KEYRING_PKG}"
rm "/tmp/${KEYRING_PKG}"
apt-get update -qq
