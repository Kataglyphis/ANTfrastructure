#!/usr/bin/env bash
# NVIDIA CUDA apt keyring and repo for the build arch, plus the cross repo for a foreign TARGET_ARCH.
set -euo pipefail

# Mirror rewrite before any apt access (no-op unless USE_FAST_UBUNTU_MIRROR).
_SETUP_CUDA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${_SETUP_CUDA_DIR}/use-fast-ubuntu-mirror.sh"

# The build host's component carries tools that run here; a foreign target's libs come from the cross repo.
cuda_repo_component() {
  case "${1:-}" in
    amd64)   printf '%s' 'x86_64' ;;
    arm64)   printf '%s' 'sbsa' ;;
    '')      printf '%s' '' ;;
    *)       printf '%s' "$1" ;;
  esac
}

# Flat cross repo (no dists/, hence " /" below) whose Architecture: all debs need no dpkg --add-architecture.
cuda_cross_repo_component() {
  local build="${1:-}" target="${2:-}"
  [ -n "${target}" ] && [ "${target}" != "${build}" ] || return 0
  case "${target}" in
    arm64) printf '%s' 'cross-linux-sbsa' ;;
    *)     return 0 ;;
  esac
}

ARCH="$(dpkg --print-architecture)"
CUDA_ARCH="$(cuda_repo_component "${ARCH}")"
[ -n "${CUDA_ARCH}" ] || { echo "WARNING: CUDA packages may not be available for arch ${ARCH}" >&2; CUDA_ARCH="${ARCH}"; }
CUDA_CROSS_COMPONENT="$(cuda_cross_repo_component "${ARCH}" "${TARGET_ARCH:-${ARCH}}")"
KEYRING_PKG="cuda-keyring_1.1-1_all.deb"
# NVIDIA paths use the version digits (ubuntu2604); the codename form 404s.
: "${UBUNTU_VERSION:?UBUNTU_VERSION must be set (e.g. 26.04) to build the NVIDIA repo path}"
NV_DISTRO="ubuntu${UBUNTU_VERSION//./}"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${NV_DISTRO}/${CUDA_ARCH}/${KEYRING_PKG}"
# Verified fetch: this deb is the apt trust anchor for every NVIDIA package.
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

# The cross repo is signed-by the keyring just installed, never the weaker global keyring.
if [ -n "${CUDA_CROSS_COMPONENT}" ]; then
  printf 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/%s/%s/ /\n' \
    "${NV_DISTRO}" "${CUDA_CROSS_COMPONENT}" > /etc/apt/sources.list.d/cuda-cross.list
  echo "CUDA cross repo enabled for TARGET_ARCH=${TARGET_ARCH:-?}: ${NV_DISTRO}/${CUDA_CROSS_COMPONENT}"
fi

apt-get update -qq
