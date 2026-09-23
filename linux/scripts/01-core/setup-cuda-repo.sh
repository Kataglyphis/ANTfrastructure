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

# NVIDIA's repo component for a Debian arch. The BUILD host's component carries
# the tools that must EXECUTE here (nvcc, ptxas, cicc); a foreign TARGET_ARCH
# gets its libraries from the cross repo below, never from this one.
cuda_repo_component() {
  case "${1:-}" in
    amd64)   printf '%s' 'x86_64' ;;
    arm64)   printf '%s' 'sbsa' ;;
    '')      printf '%s' '' ;;
    *)       printf '%s' "$1" ;;
  esac
}

# The flat cross repo for a target that is not the build arch (empty when the
# target IS the build arch, or when NVIDIA publishes no cross repo for it).
# Layout probed 2026-09-23: .../ubuntu2604/cross-linux-sbsa/Packages.gz, a FLAT
# repo (no dists/), hence the trailing " /" in the sources line, and its debs
# are Architecture: all — they install on an amd64 host without dpkg
# --add-architecture and land in /usr/local/cuda-<ver>/targets/sbsa-linux.
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
# NVIDIA's repo path component is the Ubuntu VERSION DIGITS (ubuntu2604), NOT the
# codename. This used to interpolate UBUNTU_CODENAME, which produced
# .../repos/ubunturesolute/ -- a 404 on every arch, so the FIRST RUN of
# Dockerfile.nvidia died under `set -euo pipefail` and the whole GPU lane was
# unbuildable on the pinned 26.04. Probed 2026-09-16: ubunturesolute/sbsa 404,
# ubuntu2604/sbsa 200. UBUNTU_CODENAME stays correct for the UBUNTU archive
# sources elsewhere; only NVIDIA's paths are numeric.
: "${UBUNTU_VERSION:?UBUNTU_VERSION must be set (e.g. 26.04) to build the NVIDIA repo path}"
NV_DISTRO="ubuntu${UBUNTU_VERSION//./}"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${NV_DISTRO}/${CUDA_ARCH}/${KEYRING_PKG}"
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

# The cross repo rides the SAME trust anchor the keyring deb just installed (one
# host, one key), so it is added after it and before the update below. Without
# signed-by apt would accept it on the global keyring, which is the weaker
# check the rest of this lane refuses.
if [ -n "${CUDA_CROSS_COMPONENT}" ]; then
  printf 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/%s/%s/ /\n' \
    "${NV_DISTRO}" "${CUDA_CROSS_COMPONENT}" > /etc/apt/sources.list.d/cuda-cross.list
  echo "CUDA cross repo enabled for TARGET_ARCH=${TARGET_ARCH:-?}: ${NV_DISTRO}/${CUDA_CROSS_COMPONENT}"
fi

apt-get update -qq
