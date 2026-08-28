#!/usr/bin/env bash
# setup-rocm-repo.sh - add the AMD ROCm TheRock apt repos, install the
# MIGraphX/ROCm stack, then remove the repos again so shipped images do not
# fetch from them.
#
# ROCm 10.0 migrated to AMD's "TheRock" distribution (stable.repo.amd.com),
# which uses deb822 .sources format with suite "stable" and splits MIGraphX
# into a separate repo path. Package names are prefixed amdrocm-*.
#
# Invoked via a BuildKit bind-mount of linux/scripts/01-core. ROCM_VERSION and
# MIGRAPHX_VERSION are declared as ARGs in Dockerfile.amd (for version-tracking
# and sync_versions.py consistency); the TheRock repo URL is not version-
# parameterized — the version is baked into the repo's package metadata.
set -euo pipefail

# GPU5 (2026-08-17): the amd64-only promise below used to be a COMMENT only —
# an arm64 build died later with a generic apt "package not found" instead of
# the promised loud failure. Enforce it up front.
if [ "$(dpkg --print-architecture 2>/dev/null || uname -m)" != "amd64" ] \
   && [ "$(uname -m)" != "x86_64" ]; then
  echo "ERROR: the ROCm/MIGraphX lane is amd64-only (AMD publishes no arm64 ROCm apt packages for this repo layout)." >&2
  exit 1
fi

# Apply the fast Ubuntu mirror rewrite (if enabled) before any apt access, so the
# repo setup + package installs below use the configured mirror. No-op unless
# USE_FAST_UBUNTU_MIRROR is truthy. Folded in here so callers invoke a single
# script (was a separate use-fast-ubuntu-mirror.sh line in Dockerfile.amd).
_SETUP_ROCM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${_SETUP_ROCM_DIR}/use-fast-ubuntu-mirror.sh"

apt-get update && apt-get install -y --no-install-recommends wget gpg curl ca-certificates
mkdir -p /etc/apt/keyrings
# VERIFIED fetch (supply-chain audit #2): this key signs every ROCm/MIGraphX
# package — the old wget|gpg pipe installed it TOFU with no integrity check.
# Same pattern repos.sh already uses for the Kitware and apt.llvm.org keys.
# shellcheck disable=SC1091
source "${_SETUP_ROCM_DIR}/downloads.sh"
_rocm_key_sha="${ROCM_GPG_KEY_SHA256:-}"
if [ -z "${_rocm_key_sha}" ] && [ -f "${_SETUP_ROCM_DIR}/versions.env" ]; then
  _rocm_key_sha="$(sed -n 's/^ROCM_GPG_KEY_SHA256=//p' "${_SETUP_ROCM_DIR}/versions.env")"
fi
_rocm_key_tmp="$(mktemp)"
if [ -n "${_rocm_key_sha}" ]; then
  download_verified_file "https://stable.repo.amd.com/rocm/gpg/packages.gpg" "${_rocm_key_sha}" "${_rocm_key_tmp}"
else
  echo "WARNING: ROCM_GPG_KEY_SHA256 unset — fetching the ROCm apt key UNVERIFIED" >&2
  download_file "https://stable.repo.amd.com/rocm/gpg/packages.gpg" "${_rocm_key_tmp}" 3
fi
gpg --dearmor < "${_rocm_key_tmp}" > /etc/apt/keyrings/rocm.gpg
rm -f "${_rocm_key_tmp}"

# ==========================================================================
# HARDCODED amd64-ONLY: both repo stanzas pin Architectures: amd64, so this
# AMD/MIGraphX layer can ONLY be built for linux/amd64.  AMD publishes no
# arm64 ROCm apt packages; do NOT "fix" this by substituting ${TARGETARCH} —
# an arm64 build must fail loudly here rather than silently produce an image
# without the ROCm stack.
# ==========================================================================
# deb822 .sources format — TheRock distribution (stable.repo.amd.com).
# Core ROCm and MIGraphX are separate repos sharing the same GPG key and
# Origin ("AMD ROCm").
cat > /etc/apt/sources.list.d/rocm.sources <<'SOURCES'
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg

Types: deb
URIs: https://stable.repo.amd.com/rocm/migraphx/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg
SOURCES

# Pin: give the AMD repo priority over Ubuntu for its packages.
echo 'Package: *' > /etc/apt/preferences.d/rocm-pin
# shellcheck disable=SC2129
echo 'Pin: release o=AMD ROCm' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 600' >> /etc/apt/preferences.d/rocm-pin
echo '' >> /etc/apt/preferences.d/rocm-pin
echo '# Allow only amdrocm-related packages from the AMD repo' >> /etc/apt/preferences.d/rocm-pin
echo 'Package: amdrocm*' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin: release o=AMD ROCm' >> /etc/apt/preferences.d/rocm-pin
echo 'Pin-Priority: 1001' >> /etc/apt/preferences.d/rocm-pin
apt-get update
# TheRock package names (amdrocm-* prefix). Versionless metapackages resolve
# to the version in the repo (10.0). MIGraphX comes from the separate repo
# stanza above.
apt-get install -y --no-install-recommends \
    amdrocm-core-dev \
    amdrocm-runtime-dev \
    amdrocm-blas-dev \
    amdrocm-dnn-dev \
    amdrocm-hipblas-common-dev \
    amdrocm-fft-dev \
    amdrocm-rccl-dev \
    amdrocm-sparse-dev \
    amdrocm-solver-dev \
    amdrocm-migraphx \
    amdrocm-migraphx-dev
# GPU4 (2026-08-17): dropped the former `rm -rf /var/lib/apt/lists/*` — the
# lists live in a shared cache MOUNT (not in the layer), so the rm only wiped
# the cache for sibling RUNs (the GPU1 failure class). The repo-source removal
# below is the real in-layer hygiene and stays.
rm -f /etc/apt/sources.list.d/rocm.sources /etc/apt/preferences.d/rocm-pin
echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
ldconfig
test -x /opt/rocm/bin/hipcc || { echo "hipcc not found"; exit 1; }
test -f /opt/rocm/include/migraphx/migraphx.hpp || { echo "migraphx.hpp not found"; exit 1; }
ldconfig -p | grep -E 'librocblas|librccl|librocfft|librocsparse|libmiopen' >/dev/null || { echo "ROCm libs not in ldconfig"; exit 1; }
